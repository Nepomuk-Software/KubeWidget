import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the Kubernetes context widget.
//
// The cheap half — which contexts exist and which one is selected — is a
// local parse of kubeconfig files (no kubectl) and runs on a plain timer.
// Extra files in ~/.kube are included there; identity is (file, name).
// Talking to a cluster (probe, overview, namespaces) only happens for the
// bound context, and only while the panel is open. The picker is not
// "looking", so `detailed` stays false for it.
Item {
  id: root

  property var settings: ({})
  property bool detailed: false
  readonly property string listKubeconfigs: Qt.resolvedUrl("list_kubeconfigs.py").toString().replace(/^file:\/\//, "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property bool showContext: setting("showContext", true) === true
  readonly property bool showNamespace: setting("showNamespace", false) === true
  readonly property int maxLabel: Math.max(4, Number(setting("maxLabel", 18)))
  readonly property int contextIntervalSec: Math.max(2, Number(setting("contextIntervalSec", 5)))
  readonly property int probeIntervalSec: Math.max(10, Number(setting("probeIntervalSec", 30)))

  property bool kubectlMissing: false
  property string defaultFile: ""
  property string activeFile: ""
  property string currentContext: ""
  property var contexts: []
  property var probes: ({})
  property var overview: ({})
  property string overviewFor: ""
  property var namespaces: []
  property bool namespacesReady: false
  property string namespacesFor: ""
  property var kindStates: ({})
  property string kindBusy: ""
  property string switching: ""
  property string settingNamespace: ""
  property string lastError: ""
  property bool contextsQueued: false

  readonly property var currentEntry: {
    var key = Model.rowKey({ file: activeFile, name: currentContext })
    for (var i = 0; i < contexts.length; i++)
      if (Model.rowKey(contexts[i]) === key) return contexts[i]
    return null
  }

  readonly property string currentNamespace: currentEntry && currentEntry.namespace
                                             ? currentEntry.namespace : "default"
  readonly property string currentKey: Model.rowKey({ file: activeFile, name: currentContext })
  readonly property bool extraFile: activeFile !== "" && defaultFile !== "" && activeFile !== defaultFile
  readonly property string activeFileLabel: Model.fileLabel(activeFile)

  readonly property var currentProbe: probes[currentKey] || null
  readonly property bool currentReachable: currentProbe ? currentProbe.reachable : false
  readonly property bool currentProbed: currentProbe !== null
  readonly property bool overviewReady: overview.reachable === "1" && overviewFor === currentKey
  readonly property int podsBad: Number(overview.podsBad || 0)
  readonly property string currentKind: kindStates[currentKey] || ""
  readonly property string kindCluster: currentEntry ? Model.kindClusterName(currentEntry) : ""

  readonly property bool barAttention: (currentProbe && currentProbe.reachable === false)
                                    || (overviewReady && podsBad > 0)

  readonly property string barLabel: {
    if (kubectlMissing) return "no kubectl"
    if (!currentContext) return "no context"
    var label = currentContext
    if (showNamespace) label = currentContext + "/" + currentNamespace
    if (extraFile) label = activeFileLabel + ":" + label
    return Model.elide(label, maxLabel)
  }

  signal switched(string name, bool ok, string message)
  signal namespaceSet(string name, bool ok, string message)
  signal kindPowered(string action, bool ok, string message)

  function refreshContexts() {
    if (contextsProc.running) {
      contextsQueued = true
      return
    }
    contextsProc.running = true
  }

  function probeCurrent() {
    if (!detailed || !currentContext || !activeFile || probeProc.running) return
    probeProc.requestedFile = activeFile
    probeProc.requestedName = currentContext
    probeProc.running = true
  }

  function refreshOverview() {
    if (!detailed || !currentContext || !activeFile || overviewProc.running) return
    overviewProc.requestedFile = activeFile
    overviewProc.requestedName = currentContext
    overviewProc.running = true
  }

  function refreshNamespaces() {
    if (!detailed || !currentContext || !activeFile || nsProc.running) return
    nsProc.requestedFile = activeFile
    nsProc.requestedName = currentContext
    nsProc.running = true
  }

  function refreshKind() {
    if (!detailed || kindProc.running) return
    if (!currentEntry || !Model.kindClusterName(currentEntry)) {
      kindStates = ({})
      return
    }
    kindProc.requestedFile = currentEntry.file
    kindProc.requestedName = currentEntry.name
    kindProc.running = true
  }

  function refreshAll() {
    refreshContexts()
    probeCurrent()
    refreshOverview()
    refreshNamespaces()
    refreshKind()
  }

  function switchTo(entry) {
    if (!entry || !entry.file || !entry.name || switching !== "") return
    if (entry.file === activeFile && entry.name === currentContext) return
    lastError = ""
    // Already current-context in that file: bind the widget without writing.
    if (entry.currentInFile && entry.file !== activeFile) {
      activeFile = entry.file
      applyCurrentFlags()
      if (detailed) {
        probeCurrent()
        refreshOverview()
        refreshNamespaces()
        refreshKind()
      }
      switched(entry.name, true, "bound")
      return
    }
    switching = Model.rowKey(entry)
    switchProc.file = entry.file
    switchProc.target = entry.name
    switchProc.running = true
  }

  // Name in the bound file, a unique name across files, or `name@file`
  // (`file` is the basename or a path) when two files share a context name.
  // Exact names win so `admin@lifecycle` is a kubeadm name, not a split.
  function switchToName(spec) {
    var resolved = Model.resolveEntry(contexts, spec, activeFile)
    if (resolved.entry) {
      switchTo(resolved.entry)
      return "ok"
    }
    return resolved.error || "unknown"
  }

  function markSwitched(file, name) {
    activeFile = file
    currentContext = name
    var next = []
    for (var i = 0; i < contexts.length; i++) {
      var c = contexts[i]
      next.push({
        file: c.file, fileLabel: c.fileLabel, name: c.name, cluster: c.cluster,
        namespace: c.namespace, server: c.server, inDefaultFile: c.inDefaultFile,
        currentInFile: c.file === file ? c.name === name : c.currentInFile,
        current: c.file === file && c.name === name
      })
    }
    contexts = next
  }

  function setNamespace(name) {
    if (!name || settingNamespace !== "" || name === currentNamespace) return
    if (!Model.validNamespace(name) || !activeFile) return
    settingNamespace = name
    lastError = ""
    nsSetProc.file = activeFile
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
    next[currentKey] = state
    kindStates = next
  }

  function applyCurrentFlags() {
    var cur = ""
    var i
    for (i = 0; i < contexts.length; i++) {
      if (contexts[i].file === activeFile && contexts[i].currentInFile) {
        cur = contexts[i].name
        break
      }
    }
    currentContext = cur
    var next = []
    for (i = 0; i < contexts.length; i++) {
      var c = contexts[i]
      next.push({
        file: c.file, fileLabel: c.fileLabel, name: c.name, cluster: c.cluster,
        namespace: c.namespace, server: c.server, inDefaultFile: c.inDefaultFile,
        currentInFile: c.currentInFile,
        current: c.file === activeFile && c.name === cur
      })
    }
    contexts = next
  }

  function applyContexts(raw) {
    var parsed = Model.parseContexts(raw)
    kubectlMissing = parsed.missing
    defaultFile = parsed.defaultFile || ""
    var still = false
    var i
    if (activeFile) {
      for (i = 0; i < parsed.contexts.length; i++)
        if (parsed.contexts[i].file === activeFile) { still = true; break }
    }
    if (!still) activeFile = parsed.defaultFile || ""
    var cur = (parsed.currentByFile && parsed.currentByFile[activeFile]) || ""
    currentContext = cur
    var next = []
    for (i = 0; i < parsed.contexts.length; i++) {
      var c = parsed.contexts[i]
      next.push({
        file: c.file, fileLabel: c.fileLabel, name: c.name, cluster: c.cluster,
        namespace: c.namespace, server: c.server, inDefaultFile: c.inDefaultFile,
        currentInFile: c.currentInFile,
        current: c.file === activeFile && c.name === cur
      })
    }
    contexts = next
  }

  function applyNamespaces(raw) {
    var parsed = Model.parseNamespaces(raw)
    if (namespacesFor !== currentKey) {
      namespacesReady = false
      namespaces = []
      return
    }
    namespacesReady = parsed.reachable
    namespaces = parsed.reachable
      ? Model.sortNamespaces(parsed.names, currentNamespace) : []
  }

  Process {
    id: contextsProc
    command: ["python3", root.listKubeconfigs]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyContexts(text) }
    onExited: {
      if (root.contextsQueued) {
        root.contextsQueued = false
        Qt.callLater(function () { root.refreshContexts() })
      }
    }
  }

  Process {
    id: probeProc
    property string requestedFile: ""
    property string requestedName: ""
    command: ["bash", "-lc", Model.probeScript([{ file: requestedFile, name: requestedName }])]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = Model.rowKey({ file: probeProc.requestedFile, name: probeProc.requestedName })
        if (req !== root.currentKey) {
          Qt.callLater(function () { root.probeCurrent() })
          return
        }
        root.probes = Model.parseProbes(text)
      }
    }
  }

  Process {
    id: overviewProc
    property string requestedFile: ""
    property string requestedName: ""
    command: ["bash", "-lc", Model.overviewScript(requestedName, requestedFile)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = Model.rowKey({ file: overviewProc.requestedFile, name: overviewProc.requestedName })
        if (req !== root.currentKey) {
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
    property string requestedFile: ""
    property string requestedName: ""
    command: ["bash", "-lc", Model.namespacesScript(requestedName, requestedFile)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = Model.rowKey({ file: nsProc.requestedFile, name: nsProc.requestedName })
        if (req !== root.currentKey) {
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
    property string requestedFile: ""
    property string requestedName: ""
    command: ["bash", "-lc", Model.kindStatusScript([{ file: requestedFile, name: requestedName }])]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var req = Model.rowKey({ file: kindProc.requestedFile, name: kindProc.requestedName })
        if (req !== root.currentKey) {
          Qt.callLater(function () { root.refreshKind() })
          return
        }
        root.kindStates = Model.parseKindStatus(text)
      }
    }
  }

  Process {
    id: switchProc
    property string file: ""
    property string target: ""
    command: ["kubectl", "--kubeconfig=" + file, "config", "use-context", target]
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (code) {
      var name = target
      var fileUsed = file
      root.switching = ""
      if (code === 0) {
        root.markSwitched(fileUsed, name)
        root.overview = ({})
        root.overviewFor = ""
        root.namespaces = []
        root.namespacesReady = false
        root.namespacesFor = ""
        root.refreshContexts()
        if (root.detailed) {
          root.probeCurrent()
          root.refreshOverview()
          root.refreshNamespaces()
          root.refreshKind()
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
    property string file: ""
    property string target: ""
    command: ["kubectl", "--kubeconfig=" + file, "config", "set-context", "--current", "--namespace=" + target]
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
          next[root.currentKey] = { reachable: false, ms: 0, version: "" }
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

  Timer {
    id: kindSettle
    interval: 8000
    repeat: false
    onTriggered: {
      root.probeCurrent()
      root.refreshOverview()
      root.refreshNamespaces()
      root.refreshKind()
    }
  }

  Timer {
    interval: root.contextIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshContexts()
  }

  Timer {
    interval: root.probeIntervalSec * 1000
    running: root.detailed
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.probeCurrent()
      root.refreshOverview()
      root.refreshNamespaces()
      root.refreshKind()
    }
  }

  onDetailedChanged: if (detailed) {
    probeCurrent()
    refreshOverview()
    refreshNamespaces()
    refreshKind()
  }
  onCurrentKeyChanged: {
    overview = ({})
    overviewFor = ""
    namespaces = []
    namespacesReady = false
    namespacesFor = ""
    if (detailed) {
      probeCurrent()
      refreshKind()
    }
  }
}
