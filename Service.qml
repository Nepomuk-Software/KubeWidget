import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the Kubernetes context widget.
//
// The cheap half — which contexts exist and which one is selected — is a
// kubeconfig read and runs on a plain timer. The expensive half — is that
// cluster actually reachable, and what is in it — only runs while someone is
// looking at the panel, because every one of those calls can hang.
Item {
  id: root

  property var settings: ({})
  property bool detailed: false        // panel open → probe and fetch the overview

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property bool showContext: setting("showContext", true) === true
  readonly property int maxLabel: Math.max(4, Number(setting("maxLabel", 18)))
  readonly property int contextIntervalSec: Math.max(2, Number(setting("contextIntervalSec", 5)))
  readonly property int probeIntervalSec: Math.max(10, Number(setting("probeIntervalSec", 30)))

  // ── State ────────────────────────────────────────────────────────────────
  property bool kubectlMissing: false
  property string currentContext: ""
  property var contexts: []            // [{name, cluster, namespace, server, current}]
  property var probes: ({})            // name → {reachable, ms, version}
  property var overview: ({})          // key/value from overviewScript
  property string switching: ""        // context being switched to
  property string lastError: ""

  readonly property var currentEntry: {
    for (var i = 0; i < contexts.length; i++)
      if (contexts[i].current) return contexts[i]
    return null
  }

  readonly property var currentProbe: probes[currentContext] || null
  readonly property bool currentReachable: currentProbe ? currentProbe.reachable : false
  // Absence of a probe is not the same as a failed one: before the first probe
  // comes back the panel must say "checking", not "unreachable".
  readonly property bool currentProbed: currentProbe !== null
  readonly property bool overviewReady: overview.reachable === "1"

  readonly property string barLabel: {
    if (kubectlMissing) return "no kubectl"
    if (!currentContext) return "no context"
    return Model.elide(currentContext, maxLabel)
  }

  signal switched(string name, bool ok, string message)

  // ── Actions ──────────────────────────────────────────────────────────────

  function refreshContexts() { if (!contextsProc.running) contextsProc.running = true }

  function probeAll() {
    if (contexts.length === 0 || probeProc.running) return
    probeProc.running = true
  }

  function refreshOverview() {
    if (!currentContext || overviewProc.running) return
    overviewProc.running = true
  }

  function refreshAll() {
    refreshContexts()
    probeAll()
    refreshOverview()
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

  function applyContexts(raw) {
    var parsed = Model.parseContexts(raw)
    kubectlMissing = parsed.missing
    currentContext = parsed.current
    contexts = parsed.contexts
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
    command: ["bash", "-lc", Model.overviewScript(root.currentContext)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.overview = Model.parseKeyValues(text)
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
        root.overview = ({})           // belongs to the old context
        root.refreshContexts()
        root.refreshOverview()
        root.switched(name, true, "switched")
      } else {
        root.lastError = String(stderr.text || "").trim() || "could not switch context"
        root.switched(name, false, root.lastError)
      }
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
    onTriggered: { root.probeAll(); root.refreshOverview() }
  }

  onDetailedChanged: if (detailed) { probeAll(); refreshOverview() }
  onCurrentContextChanged: overview = ({})
}
