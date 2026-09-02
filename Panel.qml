import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar face plus popup for Kubernetes contexts.
//
//   left = panel · right = context picker · middle = refresh
//
// Writes are explicit clicks: use-context / set-namespace on the row's file,
// and Kind start/stop. Extra files are listed by parsing them, then bind this
// widget only (--kubeconfig); they are not exported into new shells and are
// not probed until picked. The picker never talks to a cluster.
Panel {
  id: root
  moduleName: "io.github.nepomuk-software.kubecontext"
  ipcTarget: "io.github.nepomuk-software.kubecontext"
  manageIpc: false

  readonly property alias service: kube

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  property bool nsOpen: false
  property int contextIndex: 0
  property bool cursorActive: false
  property int nsIndex: 0
  property bool nsCursorActive: false

  property bool quickOpen: false
  property int quickIndex: 0
  property bool quickCursorActive: false

  readonly property bool quickAvailable: !kube.kubectlMissing && kube.contexts.length > 0
  readonly property var contextGroups: Model.groupContexts(kube.contexts)

  readonly property string barTooltip: {
    if (kube.kubectlMissing) return "kubectl is not installed"
    if (!kube.currentContext) return "No Kubernetes context selected"
    var lines = ["Context " + Model.plain(kube.currentContext)]
    if (kube.extraFile) lines.push("File " + Model.plain(kube.activeFileLabel) + " (this widget only)")
    var e = kube.currentEntry
    if (e && e.namespace) lines.push("Namespace " + Model.plain(e.namespace))
    if (e && e.server) lines.push(Model.plain(Model.shortServer(e.server)))
    if (kube.currentProbe && kube.currentProbe.reachable === false)
      lines.push("Last seen unreachable")
    else if (kube.overviewReady && kube.podsBad > 0)
      lines.push(kube.podsBad + " pod" + (kube.podsBad === 1 ? "" : "s") + " not running")
    if (root.quickAvailable) lines.push("right-click to pick a context")
    return lines.join("\n")
  }

  function handlePress(mouseButton) {
    if (mouseButton === Qt.RightButton) {
      if (root.quickAvailable) root.quickOpen ? quickOwner.close() : root.openQuick()
    } else if (mouseButton === Qt.MiddleButton) {
      if (root.opened) kube.refreshAll()
      else kube.refreshContexts()
    } else {
      if (root.quickOpen) quickOwner.close()
      root.toggle()
    }
  }

  function openQuick() {
    kube.refreshContexts()
    quickIndex = 0
    for (var i = 0; i < kube.contexts.length; i++) {
      if (kube.contexts[i].current) { quickIndex = i; break }
    }
    quickCursorActive = false
    quickOpen = true
  }

  function moveQuickCursor(dy) {
    quickCursorActive = true
    if (kube.contexts.length === 0) return
    quickIndex = Math.max(0, Math.min(kube.contexts.length - 1, quickIndex + dy))
  }

  function moveCursor(dy) {
    cursorActive = true
    if (kube.contexts.length === 0) return
    contextIndex = Math.max(0, Math.min(kube.contexts.length - 1, contextIndex + dy))
  }

  function activateCursor() {
    if (!cursorActive || kube.contexts.length === 0) return
    var c = kube.contexts[contextIndex]
    if (c && !c.current) kube.switchTo(c)
  }

  function moveNsCursor(dy) {
    nsCursorActive = true
    if (kube.namespaces.length === 0) return
    nsIndex = Math.max(0, Math.min(kube.namespaces.length - 1, nsIndex + dy))
  }

  function activateNsCursor() {
    if (!nsCursorActive || kube.namespaces.length === 0) return
    var n = kube.namespaces[nsIndex]
    if (n) kube.setNamespace(n)
  }

  onOpenedChanged: if (!opened) {
    nsOpen = false
    cursorActive = false
    nsCursorActive = false
  }

  Connections {
    target: kube
    function onCurrentKeyChanged() {
      root.nsOpen = false
      root.nsCursorActive = false
    }
  }

  Service {
    id: kube
    settings: root.settings
    detailed: root.opened
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { kube.refreshAll(); return "ok" }
    function current(): string { return kube.currentContext || "none" }
    function kubeconfig(): string { return kube.activeFile || "" }
    function namespace(): string { return kube.currentNamespace }
    function use(context: string): string {
      var before = kube.currentKey
      var r = kube.switchToName(context)
      if (kube.switching !== "") return "switching"
      if (kube.currentKey !== before) return "bound"
      return r === "ok" ? "unchanged" : r
    }
    function useIn(file: string, context: string): string {
      var before = kube.currentKey
      var r = kube.switchToName(context + "@" + file)
      if (kube.switching !== "") return "switching"
      if (kube.currentKey !== before) return "bound"
      return r === "ok" ? "unchanged" : r
    }
    function rows(): string {
      var lines = []
      for (var i = 0; i < kube.contexts.length; i++) {
        var c = kube.contexts[i]
        lines.push((c.current ? "*" : " ") + " " + c.name + "\t" + (c.file || ""))
      }
      return lines.join("\n") || "none"
    }
    function useNamespace(name: string): string {
      kube.setNamespace(name)
      return kube.settingNamespace === name ? "setting" : "unchanged"
    }
    function kindStart(): string {
      kube.startKind()
      return kube.kindBusy === "starting" ? "starting" : "unchanged"
    }
    function kindStop(): string {
      kube.stopKind()
      return kube.kindBusy === "stopping" ? "stopping" : "unchanged"
    }
    function status(): string {
      if (kube.kubectlMissing) return "no kubectl"
      if (!kube.currentContext) return "no context"
      var p = kube.currentProbe
      var tag = kube.currentContext + (kube.extraFile ? "@" + kube.activeFileLabel : "")
      if (!p) return tag + " unprobed"
      if (!p.reachable)
        return tag + (kube.currentKind === "stopped" ? " kind-stopped" : " unreachable")
      var o = kube.overview
      var line = tag + " reachable " + p.version
              + " ns=" + kube.currentNamespace
      if (kube.overviewReady)
        line += " nodes=" + (o.nodesReady || "0") + "/" + (o.nodesTotal || "0")
              + " pods=" + (o.podsRunning || "0") + "/" + (o.podsTotal || "0")
      return line
    }
  }

  // ── Bar face ───────────────────────────────────────────────────────────────
  implicitWidth: face.implicitWidth
  implicitHeight: face.implicitHeight

  Loader {
    id: face
    anchors.fill: parent
    sourceComponent: (kube.showContext && !root.vertical) ? labelFace : iconFace
  }

  Component {
    id: iconFace
    BarIconButton {
      bar: root.bar
      text: "󱃾"
      dimmed: !kube.currentContext
      active: kube.barAttention
      tooltipText: root.barTooltip
      onPressed: function (b) { root.handlePress(b) }
    }
  }

  Component {
    id: labelFace
    WidgetButton {
      bar: root.bar
      text: "󱃾  " + Model.plain(kube.barLabel)
      dimmed: !kube.currentContext
      active: kube.barAttention
      tooltipText: root.barTooltip
      fontSize: Style.font.caption
      onPressed: function (b) { root.handlePress(b) }
    }
  }

  // ── Popup ──────────────────────────────────────────────────────────────────
  KeyboardPanel {
    id: panel
    anchorItem: face
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy === 0) return
        if (root.nsOpen) {
          if (!root.nsCursorActive) { root.nsCursorActive = true; return }
          root.moveNsCursor(dy)
        } else {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        }
      }
      onActivateRequested: {
        if (root.nsOpen) root.activateNsCursor()
        else root.activateCursor()
      }
      onTextKey: function (t) {
        var k = String(t).toLowerCase()
        if (k === "r") kube.refreshAll()
        else if (k === "n" && kube.currentContext) {
          root.nsOpen = !root.nsOpen
          root.nsCursorActive = false
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ── Header ──────────────────────────────────────────────────────
          Item {
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "Kubernetes"
              meta: kube.kubectlMissing ? "kubectl not installed"
                    : kube.currentContext
                      ? (Model.plain(kube.currentContext)
                         + (kube.extraFile ? "  ·  " + Model.plain(kube.activeFileLabel) : ""))
                    : "no context selected"
              detail: kube.overviewReady ? Model.plain(kube.overview.serverVersion || "") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󱃾"
                  color: kube.currentReachable ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: kube.extraFile
            width: parent.width
            text: Model.plain(kube.activeFileLabel) + " — this widget only; new shells still use "
                  + Model.plain(Model.fileLabel(kube.defaultFile) || "config")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: kube.currentEntry !== null
            width: parent.width
            text: kube.currentEntry ? Model.shortServer(kube.currentEntry.server) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Text {
            textFormat: Text.PlainText
            visible: kube.lastError !== ""
            width: parent.width
            text: kube.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ── Cluster ─────────────────────────────────────────────────────
          Column {
            visible: kube.currentContext !== "" && !kube.kubectlMissing
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "CLUSTER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Three distinct states, and none of them may be shown as another:
            // not asked yet, asked and silent, asked and answered.
            Text {
              textFormat: Text.PlainText
              visible: !kube.overviewReady
              width: parent.width
              text: !kube.currentProbed ? "Checking…"
                    : kube.currentKind === "stopped"
                      ? "Kind cluster is not running."
                    : "Not reachable. The context is selected, but the API server did not answer "
                      + "within " + Model.NET_TIMEOUT + " seconds."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              visible: kube.kindCluster !== ""
                       && (kube.currentKind === "running" || kube.currentKind === "stopped")
              text: kube.kindBusy === "starting" ? "Starting…"
                    : kube.kindBusy === "stopping" ? "Stopping…"
                    : kube.currentKind === "running" ? "Stop Kind cluster"
                    : "Start Kind cluster"
              iconText: kube.currentKind === "running" ? "󰓛" : "󰐊"
              bordered: true
              enabled: kube.kindBusy === ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: kube.currentKind === "running" ? kube.stopKind() : kube.startKind()
            }

            InfoPair {
              visible: kube.overviewReady
              label: "Nodes"
              value: (kube.overview.nodesReady || "0") + " / " + (kube.overview.nodesTotal || "0") + " ready"
            }
            InfoPair {
              visible: kube.overviewReady && Model.rolesLabel(kube.overview.roles) !== ""
              label: "Roles"
              value: Model.rolesLabel(kube.overview.roles)
            }
            InfoPair {
              visible: kube.overviewReady
              label: "Pods"
              value: {
                var running = kube.overview.podsRunning || "0"
                var total = kube.overview.podsTotal || "0"
                var bad = Number(kube.overview.podsBad || 0)
                return running + " / " + total + " running" + (bad > 0 ? "  ·  " + bad + " not" : "")
              }
            }
            InfoPair {
              visible: kube.overviewReady
              label: "Namespaces"
              value: kube.overview.namespaces || "0"
            }
            InfoPair {
              visible: kube.overviewReady && (kube.overview.kubelet || "") !== ""
              label: "Kubelet"
              value: kube.overview.kubelet || ""
            }
            InfoPair {
              visible: kube.overviewReady && (kube.overview.cpuPercent || "") !== ""
              label: "Load"
              value: (kube.overview.cpuPercent || "0") + "% CPU  ·  " + (kube.overview.memPercent || "0") + "% memory"
            }

            // Local fact from the kubeconfig — shown even when the cluster
            // did not answer. The list under it is the API's, so it only
            // appears once that call has returned.
            Item {
              width: parent.width
              implicitHeight: nsPair.implicitHeight
              visible: kube.currentEntry !== null

              InfoPair {
                id: nsPair
                width: parent.width
                label: "Namespace"
                value: kube.currentNamespace
                       + ((kube.currentReachable || kube.namespacesReady)
                          ? (root.nsOpen ? "  ▾" : "  ▸") : "")
              }
              MouseArea {
                anchors.fill: parent
                enabled: kube.currentReachable || kube.namespacesReady || !kube.currentProbed
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  root.nsOpen = !root.nsOpen
                  root.nsCursorActive = false
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.nsOpen && !kube.namespacesReady && kube.currentProbed && !kube.currentReachable
              width: parent.width
              text: "Namespaces cannot be listed while the cluster is unreachable."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              textFormat: Text.PlainText
              visible: root.nsOpen && !kube.namespacesReady && !(kube.currentProbed && !kube.currentReachable)
              width: parent.width
              text: "Listing namespaces…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.nsOpen && kube.namespacesReady ? kube.namespaces : []
              NamespaceRow {
                width: column.width
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ── Contexts ────────────────────────────────────────────────────
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "CONTEXTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: kube.kubectlMissing
              width: parent.width
              text: "kubectl was not found on PATH, so the widget cannot switch or probe a cluster."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: kube.contexts.length === 0
              width: parent.width
              text: "No contexts in the kubeconfig."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.contextGroups

              Column {
                required property var modelData
                width: column.width
                spacing: Style.space(2)

                PanelSectionHeader {
                  text: Model.plain(modelData.fileLabel || "config")
                        + (modelData.isDefault ? "" : "  ·  widget only")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: parent.modelData.entries

                  ContextRow {
                    width: column.width
                    hasCursor: root.cursorActive && kube.contexts[root.contextIndex]
                               && Model.rowKey(kube.contexts[root.contextIndex]) === Model.rowKey(modelData)
                    onActivated: kube.switchTo(modelData)
                    onEntered: {
                      root.cursorActive = true
                      for (var i = 0; i < kube.contexts.length; i++) {
                        if (Model.rowKey(kube.contexts[i]) === Model.rowKey(modelData)) {
                          root.contextIndex = i; break
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Button {
            text: "Refresh"
            iconText: "󰑐"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: kube.refreshAll()
          }
        }
      }
    }
  }

  // ── Quick picker ───────────────────────────────────────────────────────────
  // Right-click: every context, no probe. A second popup on the same bar slot,
  // so it carries its own handle — reusing root's would dismiss the panel.
  QtObject {
    id: quickOwner
    property bool popoutSwitchClosing: false
    function close() { root.quickOpen = false }
    function closeForPopoutSwitch() {
      popoutSwitchClosing = true
      root.quickOpen = false
      Qt.callLater(function() { popoutSwitchClosing = false })
    }
  }

  KeyboardPanel {
    id: quickPanel
    anchorItem: face
    owner: quickOwner
    bar: root.bar
    open: root.quickOpen
    focusTarget: quickKeys
    contentWidth: quickPanel.fittedContentWidth(Style.space(300))
    contentHeight: quickPanel.fittedContentHeight(quickColumn.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: quickKeys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.quickCursorActive) { root.quickCursorActive = true; return }
        if (dy !== 0) root.moveQuickCursor(dy)
      }
      onActivateRequested: {
        if (!root.quickCursorActive || kube.contexts.length === 0) return
        var c = kube.contexts[root.quickIndex]
        if (c && !c.current) kube.switchTo(c)
        quickOwner.close()
      }
      onCloseRequested: quickOwner.close()

      Flickable {
        id: quickFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: quickColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: quickColumn
          width: quickFlick.width
          spacing: Style.space(4)

          Repeater {
            model: root.quickOpen ? root.contextGroups : []

            Column {
              required property var modelData
              width: quickColumn.width
              spacing: Style.space(2)

              PanelSectionHeader {
                text: Model.plain(modelData.fileLabel || "config")
                      + (modelData.isDefault ? "" : "  ·  widget only")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: parent.modelData.entries
                QuickRow {
                  width: quickColumn.width
                }
              }
            }
          }
        }
      }
    }
  }

  // ── Building blocks ────────────────────────────────────────────────────────

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      id: pairLabel
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      textFormat: Text.PlainText
      id: pairValue
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }

  component NamespaceRow: Rectangle {
    id: nsRow

    required property var modelData
    required property int index

    readonly property string nsName: String(modelData || "")
    readonly property bool isCurrent: nsName === kube.currentNamespace
    readonly property bool isSetting: kube.settingNamespace === nsName
    readonly property bool hasCursor: root.nsCursorActive && root.nsIndex === index

    implicitHeight: Style.spacing.popupRowHeight
    radius: Style.cornerRadius
    color: (hasCursor || mouse.containsMouse)
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
           : "transparent"

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: if (!nsRow.isCurrent) kube.setNamespace(nsRow.nsName)
      onContainsMouseChanged: if (containsMouse) {
        root.nsCursorActive = true
        root.nsIndex = nsRow.index
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.fill: parent
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(6)
      verticalAlignment: Text.AlignVCenter
      text: Model.plain(nsRow.nsName) + (nsRow.isSetting ? "  ·  setting…" : (nsRow.isCurrent ? "  ·  current" : ""))
      color: nsRow.isCurrent ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  component ContextRow: Rectangle {
    id: row

    required property var modelData
    required property int index
    property bool hasCursor: false

    readonly property var probe: kube.probes[Model.rowKey(modelData)] || null
    readonly property string kind: kube.kindStates[Model.rowKey(modelData)] || ""
    readonly property bool isCurrent: modelData.current === true
    readonly property bool isSwitching: kube.switching === Model.rowKey(modelData)

    signal activated()
    signal entered()

    implicitHeight: Style.spacing.popupRowHeight + Style.space(8)
    radius: Style.cornerRadius
    color: (hasCursor || mouse.containsMouse)
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
           : "transparent"

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: if (!row.isCurrent) row.activated()
      onContainsMouseChanged: if (containsMouse) row.entered()
    }

    // Filled while selected, outline otherwise. Reachability is a separate
    // fact and lives on the right, because a context can be current and dead.
    Rectangle {
      id: dot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: row.isCurrent ? root.foreground : "transparent"
      border.width: 1
      border.color: row.isCurrent ? root.foreground
                                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
    }

    Text {
      textFormat: Text.PlainText
      id: state
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: row.isSwitching ? "switching…"
            : row.kind === "stopped" ? "kind stopped"
            : !row.probe ? ""
            : row.probe.reachable ? Model.latency(row.probe.ms) : "unreachable"
      color: row.probe && row.probe.reachable ? root.foreground : root.dim
      opacity: row.probe && row.probe.reachable ? 0.7 : 1
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Column {
      anchors.left: dot.right
      anchors.leftMargin: Style.space(10)
      anchors.right: state.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: Model.plain(row.modelData.name)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: {
          var bits = [Model.shortServer(row.modelData.server)]
          if (row.modelData.namespace && row.modelData.namespace !== "default")
            bits.push("ns " + row.modelData.namespace)
          if (row.probe && row.probe.reachable && row.probe.version) bits.push(row.probe.version)
          return bits.filter(function (b) { return b !== "" }).join("  ·  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
  }

  component QuickRow: Rectangle {
    id: quickRow

    required property var modelData
    required property int index

    readonly property bool isCurrent: modelData.current === true
    readonly property bool isSwitching: kube.switching === Model.rowKey(modelData)
    readonly property bool hasCursor: root.quickCursorActive && kube.contexts[root.quickIndex]
                                      && Model.rowKey(kube.contexts[root.quickIndex]) === Model.rowKey(modelData)

    implicitHeight: Style.spacing.popupRowHeight + Style.space(4)
    radius: Style.cornerRadius
    color: hasCursor
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
           : "transparent"

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        if (!quickRow.isCurrent) kube.switchTo(quickRow.modelData)
        quickOwner.close()
      }
      onContainsMouseChanged: if (containsMouse) {
        root.quickCursorActive = true
        for (var i = 0; i < kube.contexts.length; i++) {
          if (Model.rowKey(kube.contexts[i]) === Model.rowKey(quickRow.modelData)) {
            root.quickIndex = i; break
          }
        }
      }
    }

    Rectangle {
      id: quickDot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: quickRow.isCurrent ? root.foreground : "transparent"
      border.width: 1
      border.color: quickRow.isCurrent ? root.foreground
                    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
    }

    Column {
      anchors.left: quickDot.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: Model.plain(quickRow.modelData.name)
              + (quickRow.isSwitching ? "  ·  switching…" : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        visible: (quickRow.modelData.namespace || "") !== ""
        width: parent.width
        text: Model.plain(quickRow.modelData.namespace || "default")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }
  }
}
