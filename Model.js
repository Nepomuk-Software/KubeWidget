// Commands, parsing and formatting for the Kubernetes context widget.
// Plain JS so the QML side stays about presentation.

.pragma library

// Reading a kubeconfig is a local file operation. Talking to a cluster is not,
// and clusters fail in more ways than they succeed: a credential plugin that
// errors, a private endpoint whose DNS does not resolve, an API server that
// simply never answers. Every call that leaves the machine is wrapped twice —
// kubectl's own --request-timeout and an outer timeout(1) — because a shell
// that hosts the whole desktop cannot afford to wait on any of them.
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

// ── Commands ───────────────────────────────────────────────────────────────

// Contexts, their clusters and the current selection. No network at all, so
// this can run on a plain timer without costing anything.
function contextsScript() {
  return capped([
    "command -v kubectl >/dev/null 2>&1 || { printf 'nokubectl=1\\n'; exit 0; };",
    "printf 'current=%s\\n' \"$(kubectl config current-context 2>/dev/null)\";",
    "kubectl config view -o jsonpath='{range .contexts[*]}{.name}|{.context.cluster}|{.context.namespace}{\"\\n\"}{end}'",
    "  2>/dev/null | sed '/^$/d; s/^/ctx=/';",
    "kubectl config view -o jsonpath='{range .clusters[*]}{.name}|{.cluster.server}{\"\\n\"}{end}'",
    "  2>/dev/null | sed '/^$/d; s/^/cluster=/'"
  ].join(" "))
}

// Reachability for every context at once. Serially this would take as long as
// the sum of the failures; in parallel it takes as long as the slowest one,
// and the timeouts bound that.
function probeScript(names) {
  if (!names || names.length === 0) return "true"
  var quoted = []
  for (var i = 0; i < names.length; i++) quoted.push(shellQuote(names[i]))
  return capped([
    "probe() {",
    "  s=$(date +%s%N);",
    "  out=$(timeout " + PROBE_HARD + " kubectl --context \"$1\" --request-timeout=" + PROBE_TIMEOUT + "s get --raw /version 2>/dev/null | head -c " + RAW_CAPTURE + ");",
    "  e=$(date +%s%N);",
    "  ms=$(( (e-s)/1000000 ));",
    "  if printf '%s' \"$out\" | grep -q gitVersion; then",
    "    v=$(printf '%s' \"$out\" | sed -n 's/.*\"gitVersion\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1);",
    "    printf 'up=%s|1|%s|%s\\n' \"$1\" \"$ms\" \"$v\";",
    "  else",
    "    printf 'up=%s|0|%s|\\n' \"$1\" \"$ms\";",
    "  fi;",
    "};",
    "for n in " + quoted.join(" ") + "; do probe \"$n\" & done;",
    "wait"
  ].join(" "))
}

// The overview asks whether anyone is home before counting anything. Otherwise
// every count comes back zero, and "not measured" would render as "an empty
// cluster" — a different claim entirely.
function overviewScript(context) {
  var c = shellQuote(context)
  return capped([
    "ctx=" + c + ";",
    "k() { timeout " + HARD_TIMEOUT + " kubectl --context \"$ctx\" --request-timeout=" + NET_TIMEOUT + "s \"$@\" 2>/dev/null; };",
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
  var current = "", servers = {}, contexts = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("current=") === 0) {
      current = line.substring(8)
    } else if (line.indexOf("cluster=") === 0) {
      var cf = line.substring(8).split("|")
      if (cf[0]) servers[cf[0]] = cf[1] || ""
    } else if (line.indexOf("ctx=") === 0) {
      var f = line.substring(4).split("|")
      if (f[0]) contexts.push({ name: f[0], cluster: f[1] || "", namespace: f[2] || "default" })
    }
  }
  for (var j = 0; j < contexts.length; j++) {
    contexts[j].server = servers[contexts[j].cluster] || ""
    contexts[j].current = contexts[j].name === current
  }
  return { current: current, contexts: contexts, missing: text.indexOf("nokubectl=1") >= 0 }
}

function parseProbes(raw) {
  var out = {}
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("up=") !== 0) continue
    var f = lines[i].substring(3).split("|")
    if (!f[0]) continue
    out[f[0]] = { reachable: f[1] === "1", ms: Number(f[2] || 0), version: f[3] || "" }
  }
  return out
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
