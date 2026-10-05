import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + panel for omarchy-remote. Everything comes from
// `omarchy-remote list --json`; the plugin never needs privileges and never
// changes anything — it only copies or opens URLs.
Panel {
  id: root
  moduleName: "io.github.second-state.omarchy-remote"
  ipcTarget: "omarchy-remote"
  manageIpc: false

  property var services: []
  property bool desktopUp: false
  property var providerErrors: []
  property bool loading: false
  property bool loadedOnce: false
  property string lastError: ""
  property string actionStatus: ""
  property int rowIndex: 0
  property bool cursorActive: false

  // ~/.local/bin is often not on the shell's PATH, so call the CLI by path.
  readonly property string cli: Quickshell.env("HOME") + "/.local/bin/omarchy-remote"
  readonly property int refreshMs: Math.max(15, Number(setting("refreshIntervalSec", 60))) * 1000
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: services.length > 0 ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property int publicCount: services.filter(function(s) { return s.provider !== "tailscale" }).length

  function refresh() {
    if (listProc.running) return
    loading = true
    listProc.running = true
  }

  function applyList(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { lastError = "Unexpected output from omarchy-remote"; return }
    services = data.services || []
    desktopUp = !!(data.desktop && data.desktop.vnc && data.desktop.web)
    providerErrors = data.errors || []
    lastError = providerErrors.length > 0 ? "Could not reach: " + providerErrors.join(", ") : ""
    loadedOnce = true
    if (rowIndex >= services.length) rowIndex = Math.max(0, services.length - 1)
  }

  function selected() {
    return services.length > 0 ? services[Math.max(0, Math.min(rowIndex, services.length - 1))] : null
  }

  function copyUrl(svc) {
    if (!svc || !svc.url) return
    Util.execArgv(["wl-copy", svc.url])
    actionStatus = "Copied " + svc.url
    statusTimer.restart()
  }

  function openUrl(svc) {
    if (!svc || !svc.url) return
    Util.execArgv(["xdg-open", svc.url])
  }

  function providerLabel(svc) {
    if (svc.provider === "tailscale") return "Tailscale · private"
    if (svc.provider === "pangolin") return "Pangolin · " + svc.auth
    if (svc.provider === "cloudflare") return "Cloudflare · " + svc.auth
    return svc.provider
  }

  function providerGlyph(svc) {
    if (svc.provider === "tailscale") return "󰌾"   // lock: tailnet only
    if (svc.auth === "none") return "󰖟"            // globe: public, no login
    return "󰒃"                                      // shield: public, behind auth
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    actionStatus = ""
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: listProc
    command: [root.cli, "list", "--json"]
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      var out = String(listStdout.text || "")
      if (exitCode === 0 && out.trim() !== "") root.applyList(out)
      else root.lastError = String(listStderr.text || "").trim().split("\n").pop()
        || "omarchy-remote not found at " + root.cli
    }
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 2500
    onTriggered: root.actionStatus = ""
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    // Read-only snapshot for scripts and tests (works while the screen is locked).
    function state(): string {
      return JSON.stringify({ loaded: root.loadedOnce, loading: root.loading, services: root.services,
                              desktopUp: root.desktopUp, error: root.lastError })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰢹"
    foreground: root.barIconColor
    tooltipText: root.services.length === 0 ? "omarchy-remote: nothing exposed"
      : "omarchy-remote: " + root.services.length + " exposed (" + root.publicCount + " public)"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (root.services.length === 0) return
        root.rowIndex = Math.max(0, Math.min(root.services.length - 1, root.rowIndex + dy))
      }
      onActivateRequested: if (root.cursorActive) root.copyUrl(root.selected())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if ((t === "o" || t === "O") && root.cursorActive) root.openUrl(root.selected())
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

          PanelHero {
            width: parent.width
            title: "Remote"
            meta: !root.loadedOnce ? (root.loading ? "Checking…" : "")
              : root.services.length === 0 ? "Nothing exposed"
              : root.services.length + " exposed · " + root.publicCount + " public"
            detail: "Desktop service " + (root.desktopUp ? "running" : "stopped")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰢹"
                color: root.services.length > 0 ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.actionStatus !== "" || root.lastError !== ""
            width: parent.width
            text: root.actionStatus !== "" ? root.actionStatus : root.lastError
            color: root.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "EXPOSED SERVICES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.loadedOnce && root.services.length === 0
            width: parent.width
            text: "Run  omarchy-remote expose <name> <port>  to add one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Column {
            id: rows
            visible: root.services.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.services
              ServiceRow {
                required property var modelData
                required property int index
                width: rows.width
                svc: modelData
                rowIdx: index
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Click or Enter: copy URL · O: open · R: refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component ServiceRow: CursorSurface {
    id: row
    property var svc: null
    property int rowIdx: 0

    hasCursor: root.cursorActive && root.rowIndex === rowIdx
    foreground: root.foreground
    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.rowIndex = row.rowIdx }
      onClicked: root.copyUrl(row.svc)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.svc ? root.providerGlyph(row.svc) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: content
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.svc ? row.svc.name + "  →  " + (row.svc.target || "?") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.svc ? (row.svc.url || "(no URL yet)") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.svc ? root.providerLabel(row.svc) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰏌"
        tooltipText: "Open in browser"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !!(row.svc && row.svc.url)
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openUrl(row.svc)
      }
    }
  }
}
