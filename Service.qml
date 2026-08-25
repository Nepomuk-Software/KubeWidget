import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the Kubernetes context widget.
//
// The cheap half — which contexts exist and which one is selected — is a
// kubeconfig read and runs on a plain timer. The expensive half — is that
// cluster actually reachable, and what is in it — only runs while someone is
// looking at the panel, because every one of those calls can hang. The
// right-click picker is not "looking": it only switches current-context, so
// `detailed` stays false for it.
Item {
  id: root

  property var settings: ({})
  property bool detailed: false        // panel open → probe, overview, namespace list

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property bool showContext: setting("showContext", true) === true
  readonly property bool showNamespace: setting("showNamespace", false) === true
  readonly property int maxLabel: Math.max(4, Number(setting("maxLabel", 18)))
  readonly property int contextIntervalSec: Math.max(2, Number(setting("contextIntervalSec", 5)))
  readonly property int probeIntervalSec: Math.max(10, Number(setting("probeIntervalSec", 30)))

  // ── State ────────────────────────────────────────────────────────────────
  property bool kubectlMissing: false
  property string currentContext: ""
  property var contexts: []            // [{name, cluster, namespace, server, current}]
  property var probes: ({})            // name → {reachable, ms, version}
  property var overview: ({})          // key/value from overviewScript
  property string overviewFor: ""      // context the overview belongs to
  property var namespaces: []          // names for the current context, panel only
  property bool namespacesReady: false
  property string namespacesFor: ""    // context the namespace list belongs to
  property var kindStates: ({})        // context name → running|stopped|unknown
  property string kindBusy: ""         // "" | starting | stopping
  property string switching: ""        // context being switched to
  property string settingNamespace: "" // namespace being written
  property string lastError: ""

  readonly property var currentEntry: {
    for (var i = 0; i < contexts.length; i++)
      if (contexts[i].current) return contexts[i]
    return null
  }

  readonly property string currentNamespace: currentEntry && currentEntry.namespace
                                             ? currentEntry.namespace : "default"

  readonly property var currentProbe: probes[currentContext] || null
  readonly property bool currentReachable: currentProbe ? currentProbe.reachable : false
  // Absence of a probe is not the same as a failed one: before the first probe
  // comes back the panel must say "checking", not "unreachable".
  readonly property bool currentProbed: currentProbe !== null
  readonly property bool overviewReady: overview.reachable === "1" && overviewFor === currentContext
  readonly property int podsBad: Number(overview.podsBad || 0)
  readonly property string currentKind: kindStates[currentContext] || ""
  readonly property string kindCluster: currentEntry ? Model.kindClusterName(currentEntry) : ""

  // Last known facts only. Must not start a probe: a closed bar that tints
  // itself by talking to the cluster is a monitor, which this is not.
  readonly property bool barAttention: (currentProbe && currentProbe.reachable === false)
                                    || (overviewReady && podsBad > 0)

  readonly property string barLabel: {
    if (kubectlMissing) return "no kubectl"
    if (!currentContext) return "no context"
    var label = showNamespace ? currentContext + "/" + currentNamespace : currentContext
    return Model.elide(label, maxLabel)
  }

  signal switched(string name, bool ok, string message)
  signal namespaceSet(string name, bool ok, string message)
  signal kindPowered(string action, bool ok, string message)

  // ── Actions ──────────────────────────────────────────────────────────────

  function refreshContexts() { if (!contextsProc.running) contextsProc.running = true }

  function probeAll() {
    if (!detailed || contexts.length === 0 || probeProc.running) return
    probeProc.running = true
  }

  function refreshOverview() {
    if (!detailed || !currentContext || overviewProc.running) return
    overviewProc.requested = currentContext
    overviewProc.running = true
  }

  function refreshNamespaces() {
    if (!detailed || !currentContext || nsProc.running) return
    nsProc.requested = currentContext
    nsProc.running = true
  }

  function refreshKind() {
    if (!detailed || kindProc.running) return
    var list = []
    for (var i = 0; i < contexts.length; i++) {
      if (Model.kindClusterName(contexts[i])) list.push(contexts[i])
    }
    if (list.length === 0) { kindStates = ({}); return }
    kindProc.running = true
  }

  function refreshAll() {
    refreshContexts()
    probeAll()
    refreshOverview()
    refreshNamespaces()
    refreshKind()
  }

  // Writes current-context into the kubeconfig, which every shell the user
  // opens afterwards will inherit. That is the point of the widget, but it is
  // also why it only ever happens on an explicit click.
  function switchTo(name) {
    if (!name || switching !== "" || name === currentContext) return
    switching = name
    lastError = ""
    switchProc.target = name
    switchProc.running = true
  }

  function setNamespace(name) {
    if (!name || settingNamespace !== "" || name === currentNamespace) return
    if (!Model.validNamespace(name)) return
    settingNamespace = name
    lastError = ""
    nsSetProc.target = name
    nsSetProc.running = true
  }

  function startKind() { kindPower("start") }
  function stopKind() { kindPower("stop") }

  function kindPower(direction) {
    if (kindBusy !== "" || kindPowerProc.running) return
    if (!kindCluster || !Model.validKindCluster(kindCluster)) return
    if (direction === "start" && currentKind === "running") return
    if (direction === "stop" && currentKind === "stopped") return
    kindBusy = direction === "start" ? "starting" : "stopping"
    lastError = ""
    kindPowerProc.action = direction
    kindPowerProc.cluster = kindCluster
    kindPowerProc.running = true
  }

  function markCurrentKind(state) {
    var next = {}
    for (var k in kindStates) next[k] = kindStates[k]
    next[currentContext] = state
    kindStates = next
  }

  function applyContexts(raw) {
    var parsed = Model.parseContexts(raw)
    kubectlMissing = parsed.missing
    currentContext = parsed.current
    contexts = parsed.contexts
  }

  function applyNamespaces(raw) {
    var parsed = Model.parseNamespaces(raw)
    if (namespacesFor !== currentContext) {
      namespacesReady = false
      namespaces = []
      return
    }
    namespacesReady = parsed.reachable
    namespaces = parsed.reachable
      ? Model.sortNamespaces(parsed.names, currentNamespace) : []
  }

  // ── Processes ────────────────────────────────────────────────────────────

  Process {
    id: contextsProc
    command: ["bash", "-lc", Model.contextsScript()]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyContexts(text) }
  }

  Process {
    id: probeProc
    command: ["bash", "-lc", Model.probeScript(root.contexts.map(function (c) { return c.name }))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.probes = Model.parseProbes(text)
    }
  }

  Process {
    id: overviewProc
    property string requested: ""
    command: ["bash", "-lc", Model.overviewScript(requested)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = overviewProc.requested
        if (req !== root.currentContext) {
          Qt.callLater(function () { root.refreshOverview() })
          return
        }
        root.overview = Model.parseKeyValues(text)
        root.overviewFor = req
      }
    }
  }

  Process {
    id: nsProc
    property string requested: ""
    command: ["bash", "-lc", Model.namespacesScript(requested)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = nsProc.requested
        if (req !== root.currentContext) {
          Qt.callLater(function () { root.refreshNamespaces() })
          return
        }
        root.namespacesFor = req
        root.applyNamespaces(text)
      }
    }
  }

  Process {
    id: kindProc
    command: ["bash", "-lc", Model.kindStatusScript(root.contexts)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.kindStates = Model.parseKindStatus(text)
    }
  }

  // No shell here on purpose: kubectl's own exit code decides, and a pipeline
  // would hand back the exit code of whatever came last instead.
  Process {
    id: switchProc
    property string target: ""
    command: ["kubectl", "config", "use-context", target]
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) {
      var name = target
      root.switching = ""
      if (code === 0) {
        root.overview = ({})
        root.overviewFor = ""
        root.namespaces = []
        root.namespacesReady = false
        root.namespacesFor = ""
        root.refreshContexts()
        // Picker switches with the panel closed; that must not start a probe.
        if (root.detailed) {
          root.refreshOverview()
          root.refreshNamespaces()
        }
        root.switched(name, true, "switched")
      } else {
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "could not switch context"
        root.switched(name, false, root.lastError)
      }
    }
  }

  Process {
    id: nsSetProc
    property string target: ""
    command: ["kubectl", "config", "set-context", "--current", "--namespace=" + target]
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) {
      var name = target
      root.settingNamespace = ""
      if (code === 0) {
        root.refreshContexts()
        root.namespaceSet(name, true, "namespace set")
      } else {
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "could not set namespace"
        root.namespaceSet(name, false, root.lastError)
      }
    }
  }

  Process {
    id: kindPowerProc
    property string action: "start"
    property string cluster: ""
    command: ["bash", "-lc", Model.kindPowerScript(cluster, action)]
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) {
      var act = action
      root.kindBusy = ""
      if (code === 0) {
        root.markCurrentKind(act === "start" ? "running" : "stopped")
        if (act === "stop") {
          root.overview = ({})
          root.overviewFor = ""
          root.namespaces = []
          root.namespacesReady = false
          root.namespacesFor = ""
          var next = {}
          for (var k in root.probes) next[k] = root.probes[k]
          next[root.currentContext] = { reachable: false, ms: 0, version: "" }
          root.probes = next
        } else {
          kindSettle.restart()
        }
        root.refreshKind()
        root.kindPowered(act, true, act === "start" ? "started" : "stopped")
      } else {
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim()
          || (act === "start" ? "could not start Kind cluster" : "could not stop Kind cluster")
        root.kindPowered(act, false, root.lastError)
      }
    }
  }

  // Kubelet needs a moment after docker start before /version answers.
  Timer {
    id: kindSettle
    interval: 8000
    repeat: false
    onTriggered: {
      root.probeAll()
      root.refreshOverview()
      root.refreshNamespaces()
      root.refreshKind()
    }
  }

  // ── Cadence ──────────────────────────────────────────────────────────────
  // Reading the kubeconfig costs nothing, so the bar label stays right even
  // when the context is changed from a terminal.
  Timer {
    interval: root.contextIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshContexts()
  }

  // Anything that leaves the machine only runs while the panel is open.
  Timer {
    interval: root.probeIntervalSec * 1000
    running: root.detailed
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.probeAll()
      root.refreshOverview()
      root.refreshNamespaces()
      root.refreshKind()
    }
  }

  onDetailedChanged: if (detailed) {
    probeAll()
    refreshOverview()
    refreshNamespaces()
    refreshKind()
  }
  onCurrentContextChanged: {
    overview = ({})
    overviewFor = ""
    namespaces = []
    namespacesReady = false
    namespacesFor = ""
  }
}
