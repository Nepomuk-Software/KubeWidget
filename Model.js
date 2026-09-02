// Commands, parsing and formatting for the Kubernetes context widget.
// Plain JS so the QML side stays about presentation.

.pragma library

// Reading a kubeconfig is a local file parse (list_kubeconfigs.py), never
// kubectl: an untrusted file's users.exec plugin must not run just because
// it sits in ~/.kube. Talking to a cluster is the opposite, and clusters
// fail in more ways than they succeed: a credential plugin that errors, a
// private endpoint whose DNS does not resolve, an API server that simply
// never answers. Every call that leaves the machine is wrapped twice —
// kubectl's own --request-timeout and an outer timeout(1) — because a shell
// that hosts the whole desktop cannot afford to wait on any of them. Those
// calls are only made against the context this widget is bound to.
var NET_TIMEOUT = 5      // seconds, passed to kubectl
var HARD_TIMEOUT = 6     // seconds, outer cap
var PROBE_TIMEOUT = 2    // seconds, reachability only
var PROBE_HARD = 3

// A timeout bounds how long an answer may take, not how large it may be, and
// those are different failure modes. An API server that streams for five
// seconds is still five seconds of heap in a process that draws the whole
// desktop. So every capture is bounded twice as well: once in the shell, where
// head(1) stops reading, and once here, in case the shell cap is ever removed.
var MAX_OUTPUT = 262144    // bytes accepted from one command
var LIST_CAPTURE = 1048576 // bytes of list output held in one shell variable
var RAW_CAPTURE = 8192     // bytes of a /version body, which is a small JSON doc
var MAX_FIELD = 512        // characters kept for one displayed value

function clamp(raw, max) {
  var s = String(raw === undefined || raw === null ? "" : raw)
  var cap = max || MAX_OUTPUT
  return s.length > cap ? s.substring(0, cap) : s
}

// Context names, cluster names, versions and error text come from a kubeconfig
// or from an API server, and Qt's Text defaults to AutoText: a value that looks
// like markup is rendered as markup. Several of the sinks these strings reach
// are shared components from qs.Ui whose textFormat this plugin does not own,
// so the string handed to those is made inert first. This runs at the render
// site rather than in the parsers on purpose: a context name is also the
// argument to `kubectl config use-context`, and a value rewritten on the way in
// would be the wrong one on the way out. Angle brackets and ampersands are
// dropped rather than escaped, because the sinks that *are* ours are set to
// PlainText and would otherwise display the entity.
function plain(value, max) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "")
    .replace(/[<>&]/g, "")
    .substring(0, max || MAX_FIELD)
}

// Every script here ends up in a StdioCollector, which buffers whatever it is
// handed. One wrapper so no script can forget its ceiling.
//
// The exit status is carried across the pipe by hand: a pipeline reports head's
// status, not the group's, so a caller that checks it would read every failure
// as a success. 141 is the group being killed by SIGPIPE because head had seen
// enough, which is this wrapper's doing rather than the command's failure, so
// it reads as success.
function capped(script) {
  return "{ " + script + " ; } | head -c " + MAX_OUTPUT
       + "; s=${PIPESTATUS[0]}; [ \"$s\" = 141 ] && s=0; exit \"$s\""
}

function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

function kubeFlag(file) {
  if (!file) return ""
  return "--kubeconfig=" + shellQuote(file) + " "
}

// A context is identified by the file it lives in and its name: two files
// both called "default" are two rows, not one.
function rowKey(entry) {
  if (!entry) return ""
  return String(entry.file || "") + "\t" + String(entry.name || "")
}

function fileLabel(path) {
  var s = String(path || "")
  var i = s.lastIndexOf("/")
  return i >= 0 ? s.substring(i + 1) : s
}

function groupContexts(contexts) {
  var groups = []
  var index = {}
  for (var i = 0; i < (contexts || []).length; i++) {
    var c = contexts[i]
    var f = c.file || ""
    if (index[f] === undefined) {
      index[f] = groups.length
      groups.push({
        file: f,
        fileLabel: c.fileLabel || fileLabel(f),
        isDefault: !!c.inDefaultFile,
        entries: []
      })
    }
    groups[index[f]].entries.push(c)
  }
  return groups
}

function fileHintMatches(entry, hint) {
  if (!entry || !hint) return false
  if (entry.file === hint || entry.fileLabel === hint) return true
  var s = String(entry.file || "")
  return s.length > hint.length
    && s.substring(s.length - hint.length) === hint
    && s.charAt(s.length - hint.length - 1) === "/"
}

// IPC `use` takes a name. Names like `admin@lifecycle` are real, so an exact
// name match wins. `name@file` is only the disambiguator when that exact name
// is missing (last `@`, so `user@cluster@file.yaml` still works).
function resolveEntry(contexts, spec, activeFile) {
  if (!spec) return { error: "unknown" }
  var list = contexts || []
  var i, c, n, match
  if (activeFile) {
    for (i = 0; i < list.length; i++) {
      c = list[i]
      if (c.name === spec && c.file === activeFile) return { entry: c }
    }
  }
  match = null
  n = 0
  for (i = 0; i < list.length; i++) {
    if (list[i].name === spec) { match = list[i]; n++ }
  }
  if (n === 1) return { entry: match }
  if (n > 1) return { error: "ambiguous" }

  var at = spec.lastIndexOf("@")
  if (at <= 0) return { error: "unknown" }
  var name = spec.substring(0, at)
  var hint = spec.substring(at + 1)
  if (!name || !hint) return { error: "unknown" }
  match = null
  n = 0
  for (i = 0; i < list.length; i++) {
    c = list[i]
    if (c.name !== name) continue
    if (!fileHintMatches(c, hint)) continue
    match = c
    n++
  }
  if (n === 1) return { entry: match }
  if (n > 1) return { error: "ambiguous" }
  return { error: "unknown" }
}

// ── Commands ───────────────────────────────────────────────────────────────

// Reachability for the bound context only. Extra files in ~/.kube are listed
// by parsing them; they are not probed until the user picks a row.
function probeScript(entries) {
  if (!entries || entries.length === 0) return "true"
  var jobs = []
  for (var i = 0; i < entries.length; i++) {
    if (!entries[i] || !entries[i].name) continue
    jobs.push("probe " + shellQuote(entries[i].file) + " " + shellQuote(entries[i].name) + " &")
  }
  if (jobs.length === 0) return "true"
  return capped([
    "probe() {",
    "  s=$(date +%s%N);",
    "  out=$(timeout " + PROBE_HARD + " kubectl --kubeconfig=\"$1\" --context \"$2\" --request-timeout=" + PROBE_TIMEOUT + "s get --raw /version 2>/dev/null | head -c " + RAW_CAPTURE + ");",
    "  e=$(date +%s%N);",
    "  ms=$(( (e-s)/1000000 ));",
    "  if printf '%s' \"$out\" | grep -q gitVersion; then",
    "    v=$(printf '%s' \"$out\" | sed -n 's/.*\"gitVersion\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1);",
    "    printf 'up=%s\\t%s\\t1\\t%s\\t%s\\n' \"$1\" \"$2\" \"$ms\" \"$v\";",
    "  else",
    "    printf 'up=%s\\t%s\\t0\\t%s\\t\\n' \"$1\" \"$2\" \"$ms\";",
    "  fi;",
    "};",
    jobs.join(" "),
    "wait"
  ].join(" "))
}

// The overview asks whether anyone is home before counting anything. Otherwise
// every count comes back zero, and "not measured" would render as "an empty
// cluster" — a different claim entirely.
function overviewScript(context, file) {
  var c = shellQuote(context)
  var kf = kubeFlag(file)
  return capped([
    "ctx=" + c + ";",
    "k() { timeout " + HARD_TIMEOUT + " kubectl " + kf + "--context \"$ctx\" --request-timeout=" + NET_TIMEOUT + "s \"$@\" 2>/dev/null; };",
    "ver=$(k get --raw /version | head -c " + RAW_CAPTURE + ");",
    "printf '%s' \"$ver\" | grep -q gitVersion || { printf 'reachable=0\\n'; exit 0; };",
    "printf 'reachable=1\\n';",
    "printf 'serverVersion=%s\\n' \"$(printf '%s' \"$ver\" | sed -n 's/.*\"gitVersion\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1)\";",
    "nodes=$(k get nodes --no-headers | head -c " + LIST_CAPTURE + ");",
    "printf 'nodesTotal=%s\\n' \"$(printf '%s' \"$nodes\" | grep -c .)\";",
    "printf 'nodesReady=%s\\n' \"$(printf '%s' \"$nodes\" | awk '$2==\"Ready\"' | grep -c .)\";",
    "printf 'kubelet=%s\\n' \"$(printf '%s' \"$nodes\" | awk '{print $5}' | sort -u | paste -sd, -)\";",
    "printf 'roles=%s\\n' \"$(printf '%s' \"$nodes\" | awk '{n=split($3,a,\",\"); for(i=1;i<=n;i++) if(a[i]!=\"<none>\") c[a[i]]++} END{s=\"\"; for(r in c) s=s (s?\",\":\"\") r \":\" c[r]; print s}')\";",
    "printf 'namespaces=%s\\n' \"$(k get namespaces --no-headers | head -c " + LIST_CAPTURE + " | grep -c .)\";",
    "pods=$(k get pods --all-namespaces --no-headers | head -c " + LIST_CAPTURE + ");",
    "printf 'podsTotal=%s\\n' \"$(printf '%s' \"$pods\" | grep -c .)\";",
    "printf 'podsRunning=%s\\n' \"$(printf '%s' \"$pods\" | awk '$4==\"Running\"' | grep -c .)\";",
    "printf 'podsBad=%s\\n' \"$(printf '%s' \"$pods\" | awk '$4!=\"Running\" && $4!=\"Completed\" && $4!=\"Succeeded\"' | grep -c .)\";",
    "top=$(k top nodes --no-headers | head -c " + LIST_CAPTURE + ");",
    "[ -n \"$top\" ] && {",
    "  printf 'cpuPercent=%s\\n' \"$(printf '%s' \"$top\" | awk '{gsub(/%/,\"\",$3); s+=$3; n++} END{if(n) printf \"%d\", s/n}')\";",
    "  printf 'memPercent=%s\\n' \"$(printf '%s' \"$top\" | awk '{gsub(/%/,\"\",$5); s+=$5; n++} END{if(n) printf \"%d\", s/n}')\";",
    "};",
    "true"
  ].join(" "))
}

// Namespaces of one context. The API has to answer, so this is the same
// bound as the overview and is only asked for the current context while the
// panel is open — never for every row, never from the picker.
function namespacesScript(context, file) {
  var c = shellQuote(context)
  var kf = kubeFlag(file)
  return capped([
    "ctx=" + c + ";",
    "k() { timeout " + HARD_TIMEOUT + " kubectl " + kf + "--context \"$ctx\" --request-timeout=" + NET_TIMEOUT + "s \"$@\" 2>/dev/null; };",
    "ver=$(k get --raw /version | head -c " + RAW_CAPTURE + ");",
    "printf '%s' \"$ver\" | grep -q gitVersion || { printf 'reachable=0\\n'; exit 0; };",
    "printf 'reachable=1\\n';",
    "k get namespaces --no-headers | head -c " + LIST_CAPTURE + " | awk '{print \"ns=\" $1}'"
  ].join(" "))
}

// ── Parsing ────────────────────────────────────────────────────────────────

function parseKeyValues(raw) {
  var out = {}
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq <= 0) continue
    out[lines[i].substring(0, eq)] = lines[i].substring(eq + 1)
  }
  return out
}

function parseContexts(raw) {
  var text = clamp(raw)
  var lines = text.split("\n")
  var defaultFile = "", file = "", current = "", contexts = []
  var currentByFile = {}
  function flushCurrent() {
    if (file) currentByFile[file] = current
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("defaultfile=") === 0) {
      defaultFile = line.substring(12)
    } else if (line.indexOf("file=") === 0) {
      flushCurrent()
      file = line.substring(5)
      current = ""
    } else if (line.indexOf("current=") === 0) {
      current = line.substring(8)
    } else if (line.indexOf("ctx=") === 0) {
      var f = line.substring(4).split("|")
      if (f[0] && file)
        contexts.push({
          file: file,
          fileLabel: fileLabel(file),
          name: f[0],
          cluster: f[1] || "",
          namespace: f[2] || "default",
          server: "",
          inDefaultFile: file === defaultFile,
          currentInFile: false,
          current: false
        })
    }
  }
  flushCurrent()
  for (var j = 0; j < contexts.length; j++)
    contexts[j].currentInFile = contexts[j].name === (currentByFile[contexts[j].file] || "")
  return {
    defaultFile: defaultFile,
    currentByFile: currentByFile,
    contexts: attachServers(text, defaultFile, contexts),
    missing: text.indexOf("nokubectl=1") >= 0
  }
}

function attachServers(text, defaultFile, contexts) {
  var lines = text.split("\n")
  var file = "", servers = {}, byFile = {}
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("file=") === 0) {
      if (file) byFile[file] = servers
      file = lines[i].substring(5)
      servers = {}
    } else if (lines[i].indexOf("cluster=") === 0) {
      var cf = lines[i].substring(8).split("|")
      if (cf[0]) servers[cf[0]] = cf[1] || ""
    }
  }
  if (file) byFile[file] = servers
  for (var j = 0; j < contexts.length; j++) {
    var map = byFile[contexts[j].file] || {}
    contexts[j].server = map[contexts[j].cluster] || ""
    contexts[j].inDefaultFile = contexts[j].file === defaultFile
  }
  return contexts
}

function parseProbes(raw) {
  var out = {}
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("up=") !== 0) continue
    var f = lines[i].substring(3).split("\t")
    if (f.length < 3 || !f[1]) continue
    out[f[0] + "\t" + f[1]] = { reachable: f[2] === "1", ms: Number(f[3] || 0), version: f[4] || "" }
  }
  return out
}

// RFC 1123 DNS label, which is what a namespace name is. Anything else is
// dropped from the list so it can never become an argument to kubectl.
function validNamespace(name) {
  var s = String(name || "")
  if (s.length < 1 || s.length > 63) return false
  return /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(s)
}

// Kind names the kubeconfig context `kind-<cluster>`. The node container is
// `<cluster>-control-plane`. That is a local docker/kind fact, not an API
// one, so it can tell "the VM is down" from "the API did not answer".
function kindClusterName(entry) {
  var n = String(entry && entry.name != null ? entry.name : entry || "")
  var c = String(entry && entry.cluster ? entry.cluster : "")
  if (n.indexOf("kind-") === 0) return n.substring(5)
  if (c.indexOf("kind-") === 0) return c.substring(5)
  return ""
}

function kindStatusScript(entries) {
  if (!entries || entries.length === 0) return "true"
  var jobs = []
  for (var i = 0; i < entries.length; i++) {
    var cluster = kindClusterName(entries[i])
    if (!cluster) continue
    jobs.push({
      file: shellQuote(entries[i].file || ""),
      ctx: shellQuote(entries[i].name || entries[i]),
      cluster: shellQuote(cluster),
      node: shellQuote(cluster + "-control-plane")
    })
  }
  if (jobs.length === 0) return "true"
  var loop = []
  for (var j = 0; j < jobs.length; j++)
    loop.push("check " + jobs[j].file + " " + jobs[j].ctx + " " + jobs[j].node + " " + jobs[j].cluster + " &")
  return capped([
    "check() {",
    "  file=$1; ctx=$2; node=$3; cl=$4;",
    "  if command -v docker >/dev/null 2>&1; then",
    "    [ -n \"$(timeout 2 docker ps -q --filter label=io.x-k8s.kind.cluster=\"$cl\")\" ]",
    "      && { printf 'kind=%s\\t%s\\trunning\\n' \"$file\" \"$ctx\"; return; };",
    "    [ -n \"$(timeout 2 docker ps -aq --filter label=io.x-k8s.kind.cluster=\"$cl\")\" ]",
    "      && { printf 'kind=%s\\t%s\\tstopped\\n' \"$file\" \"$ctx\"; return; };",
    "    st=$(timeout 2 docker inspect -f '{{.State.Running}}' \"$node\" 2>/dev/null);",
    "    [ \"$st\" = true ] && { printf 'kind=%s\\t%s\\trunning\\n' \"$file\" \"$ctx\"; return; };",
    "    [ \"$st\" = false ] && { printf 'kind=%s\\t%s\\tstopped\\n' \"$file\" \"$ctx\"; return; };",
    "  fi;",
    "  if command -v kind >/dev/null 2>&1; then",
    "    timeout 2 kind get nodes --name \"$cl\" 2>/dev/null | grep -q .",
    "      && { printf 'kind=%s\\t%s\\trunning\\n' \"$file\" \"$ctx\"; return; };",
    "    timeout 2 kind get clusters 2>/dev/null | grep -qx \"$cl\"",
    "      && { printf 'kind=%s\\t%s\\tstopped\\n' \"$file\" \"$ctx\"; return; };",
    "  fi;",
    "  printf 'kind=%s\\t%s\\tunknown\\n' \"$file\" \"$ctx\";",
    "};",
    loop.join(" "),
    "wait"
  ].join(" "))
}

// Kind has no start/stop CLI. The nodes are docker containers labeled
// io.x-k8s.kind.cluster=<name>, so start/stop is docker start/stop of those.
// The cluster name is interpolated only after validKindCluster(), so the
// filter cannot become a docker CLI injection.
function validKindCluster(name) {
  var s = String(name || "")
  if (s.length < 1 || s.length > 63) return false
  return /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(s)
}

function kindPowerScript(cluster, direction) {
  if (!validKindCluster(cluster))
    return "echo invalid kind cluster name >&2; exit 1"
  var action = direction === "start" ? "start" : "stop"
  var limit = action === "stop" ? 40 : 25
  return capped([
    "command -v docker >/dev/null 2>&1 || { echo docker is not available >&2; exit 1; };",
    "ids=$(timeout 3 docker ps -aq --filter label=io.x-k8s.kind.cluster=" + cluster + ");",
    "[ -n \"$ids\" ] || { echo no Kind node containers found >&2; exit 1; };",
    "timeout " + limit + " docker " + action + " $ids >/dev/null || exit 1;",
    "ccm=cloud-provider-kind-" + cluster + ";",
    "if timeout 2 docker inspect \"$ccm\" >/dev/null 2>&1; then",
    "  timeout " + limit + " docker " + action + " \"$ccm\" >/dev/null || true;",
    "fi;",
    "printf done\\n"
  ].join(" "))
}

function parseKindStatus(raw) {
  var out = {}
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("kind=") !== 0) continue
    var f = lines[i].substring(5).split("\t")
    if (f.length >= 3 && f[1]) out[f[0] + "\t" + f[1]] = f[2]
  }
  return out
}

function parseNamespaces(raw) {
  var names = []
  var reachable = false
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("reachable=") === 0) {
      reachable = lines[i].substring(10) === "1"
      continue
    }
    if (lines[i].indexOf("ns=") !== 0) continue
    var n = lines[i].substring(3)
    if (validNamespace(n)) names.push(n)
  }
  return { reachable: reachable, names: names }
}

function sortNamespaces(names, current) {
  var list = (names || []).slice()
  list.sort()
  var i = list.indexOf(current)
  if (i > 0) {
    list.splice(i, 1)
    list.unshift(current)
  }
  return list
}

// ── Formatting ─────────────────────────────────────────────────────────────

// The host is the part that identifies a cluster at a glance; the scheme and
// path are noise in a narrow panel.
function shortServer(url) {
  var s = String(url || "")
  s = s.replace(/^https?:\/\//, "")
  var slash = s.indexOf("/")
  if (slash > 0) s = s.substring(0, slash)
  return s
}

function elide(text, max) {
  var s = String(text || "")
  if (max <= 1 || s.length <= max) return s
  return s.substring(0, max - 1) + "…"
}

function latency(ms) {
  var n = Number(ms)
  if (!isFinite(n) || n <= 0) return ""
  return n < 1000 ? Math.round(n) + " ms" : (n / 1000).toFixed(1) + " s"
}

function rolesLabel(raw) {
  var s = String(raw || "").trim()
  if (!s) return ""
  return s.split(",").map(function (part) {
    var kv = part.split(":")
    return kv[1] + " × " + kv[0]
  }).join("  ·  ")
}
