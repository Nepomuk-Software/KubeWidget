import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar face plus popup for Kubernetes contexts.
//
//   left = panel · right = refresh · middle = refresh
//
// Everything here is read-only except one action: clicking a context writes
// current-context into the kubeconfig.
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

  readonly property string barTooltip: {
    if (kube.kubectlMissing) return "kubectl is not installed"
    if (!kube.currentContext) return "No Kubernetes context selected"
    var e = kube.currentEntry
    return "Context " + kube.currentContext + (e && e.server ? "\n" + Model.shortServer(e.server) : "")
  }

  function handlePress(mouseButton) {
    if (mouseButton === Qt.LeftButton) root.toggle()
    else kube.refreshAll()
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
    function use(context: string): string {
      kube.switchTo(context)
      return kube.switching === context ? "switching" : "unchanged"
    }
    function status(): string {
      if (kube.kubectlMissing) return "no kubectl"
      if (!kube.currentContext) return "no context"
      var p = kube.probes[kube.currentContext]
      if (!p) return kube.currentContext + " unprobed"
      if (!p.reachable) return kube.currentContext + " unreachable"
      var o = kube.overview
      var line = kube.currentContext + " reachable " + p.version
      if (kube.overviewReady)
        line += " nodes=" + (o.nodesReady || "0") + "/" + (o.nodesTotal || "0")
              + " pods=" + (o.podsRunning || "0") + "/" + (o.podsTotal || "0")
              + " ns=" + (o.namespaces || "0")
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
      tooltipText: root.barTooltip
      onPressed: function (b) { root.handlePress(b) }
    }
  }

  Component {
    id: labelFace
    WidgetButton {
      bar: root.bar
      text: "󱃾  " + kube.barLabel
      dimmed: !kube.currentContext
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
      onTextKey: function (t) { if (String(t).toLowerCase() === "r") kube.refreshAll() }

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
                    : kube.currentContext ? kube.currentContext
                    : "no context selected"
              detail: kube.overviewReady ? (kube.overview.serverVersion || "") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "󱃾"
                  color: kube.currentReachable ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: kube.currentEntry !== null
            width: parent.width
            text: kube.currentEntry ? Model.shortServer(kube.currentEntry.server) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Text {
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
              visible: !kube.overviewReady
              width: parent.width
              text: !kube.currentProbed ? "Checking…"
                    : "Not reachable. The context is selected, but the API server did not answer "
                      + "within " + Model.NET_TIMEOUT + " seconds."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
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
              // Only present when a metrics server answered.
              visible: kube.overviewReady && (kube.overview.cpuPercent || "") !== ""
              label: "Load"
              value: (kube.overview.cpuPercent || "0") + "% CPU  ·  " + (kube.overview.memPercent || "0") + "% memory"
            }
            InfoPair {
              visible: kube.overviewReady && kube.currentEntry !== null
              label: "Namespace"
              value: kube.currentEntry ? kube.currentEntry.namespace : ""
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
              visible: kube.kubectlMissing
              width: parent.width
              text: "kubectl was not found on PATH, so there is nothing to read."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !kube.kubectlMissing && kube.contexts.length === 0
              width: parent.width
              text: "No contexts in the kubeconfig."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: kube.contexts

              ContextRow {
                width: column.width
                onActivated: kube.switchTo(modelData.name)
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

  // ── Building blocks ────────────────────────────────────────────────────────

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
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
      id: pairValue
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }

  component ContextRow: Rectangle {
    id: row

    required property var modelData
    required property int index

    readonly property var probe: kube.probes[modelData.name] || null
    readonly property bool isCurrent: modelData.current === true
    readonly property bool isSwitching: kube.switching === modelData.name

    signal activated()

    implicitHeight: Style.spacing.popupRowHeight + Style.space(8)
    radius: Style.cornerRadius
    color: mouse.containsMouse
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
           : "transparent"

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: if (!row.isCurrent) row.activated()
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
      id: state
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: row.isSwitching ? "switching…"
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
        width: parent.width
        text: row.modelData.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
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
}
