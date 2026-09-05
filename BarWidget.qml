import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// Bar host for the Nothing Buds details panel. Quattro tracks this object in
// the slot, so it owns the button and forwards the complete panel lifecycle.
Ui.BarWidget {
  id: root
  moduleName: "io.github.saiaungminkhant.nothing-buds"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    if (panelLoader.item) panelLoader.item.refresh()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    iconComponent: Component {
      Item {
        anchors.fill: parent

        PhosphorIcon {
          anchors.centerIn: parent
          iconSize: Style.bar.iconCanvas
          icon: "headphones"
          color: panelLoader.item
            ? panelLoader.item.barIconColor
            : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 2.2)
        }

        StatusDot {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          dotSize: Style.space(5)
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          muted: panelLoader.item
            ? panelLoader.item.barIconColor
            : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 2.2)
          mode: panelLoader.item && panelLoader.item.connected
            ? panelLoader.item.mode
            : "off"
          outline: root.bar ? root.bar.background : Color.background
        }
      }
    }

    tooltipText: root.opened || !panelLoader.item ? ""
      : (!panelLoader.item.setupComplete ? "Setup required"
         : (panelLoader.item.paired
            ? Model.summary(panelLoader.item.state)
            : "No earbuds paired"))

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }
}
