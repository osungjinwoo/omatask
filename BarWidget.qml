import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Same bar-widget/panel split as System Tidy and Stormwatch: this root owns
// the bar icon + pending-count badge, Panel.qml owns the floating content.
BarWidget {
  id: root
  moduleName: "sung.omatask"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property int pendingToday: panelLoader.item ? (panelLoader.item.pendingTodayCount || 0) : 0
  readonly property bool hasOverdue: panelLoader.item ? (panelLoader.item.hasOverdue === true) : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property var service: bar?.shell?.serviceFor("sung.omatask")

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }
  onServiceChanged: injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "sung.omatask"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Debug-only: trigger the dissolve on today's first row without a
    // synthetic click, so it can be screenshotted at a known moment.
    function debugDissolveFirst(): void {
      if (panelLoader.item && panelLoader.item.debugDissolveFirst) panelLoader.item.debugDissolveFirst()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "☑"
    tooltipText: "omatask"

    onPressed: function(b) { root.toggle() }

    // Small pending-count badge, top-right of the glyph. Text/border carry
    // the theme's own accent normally, switching to its "urgent" tone (with
    // a soft pulse) only when something is actually overdue — background
    // stays the theme's own bar background so the pairing is always legible,
    // no matter how light or dark the accent itself is.
    Rectangle {
      id: badge
      visible: root.pendingToday > 0
      width: Math.max(14, badgeLabel.implicitWidth + 7)
      height: 14
      radius: 7
      color: Color.bar.background
      border.width: 1
      border.color: root.hasOverdue ? Color.urgent : Color.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 1
      anchors.topMargin: 2

      SequentialAnimation on opacity {
        running: root.hasOverdue
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.55; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 0.55; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
      }

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: root.pendingToday > 99 ? "99+" : String(root.pendingToday)
        color: root.hasOverdue ? Color.urgent : Color.accent
        font.family: Style.font.family
        font.pixelSize: 9
        font.bold: true
        textFormat: Text.PlainText
      }
    }
  }
}
