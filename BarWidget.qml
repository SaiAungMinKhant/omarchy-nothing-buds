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

  readonly property color iconColor: panelLoader.item
    ? panelLoader.item.barIconColor
    : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 2.2)

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

    // Only the glyph goes in iconComponent. The bar measures everything
    // painted there and scales it to the shared icon size, so a dot inside
    // would shrink the headphones and shift with them. The dot overlays below.
    iconComponent: Component {
      PhosphorIcon {
        iconSize: Style.bar.iconCanvas
        icon: "headphones"
        color: root.iconColor
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

  // Pinned to the bottom-right of the glyph as the bar painted it, and
  // scaled with the button's press feedback around the same centre.
  StatusDot {
    readonly property real glyphRight: button.width / 2 + button.componentPaintedWidth / 2
    readonly property real glyphBottom: button.height / 2 + button.componentPaintedHeight / 2

    x: glyphRight - width + Style.space(2)
    y: glyphBottom - height + Style.space(3)
    dotSize: Style.space(5)
    transform: Scale {
      origin.x: button.width / 2 - x
      origin.y: button.height / 2 - y
      xScale: button.pressScale
      yScale: button.pressScale
    }
    muted: root.iconColor
    mode: panelLoader.item && panelLoader.item.connected
      ? panelLoader.item.mode
      : "off"
    outline: root.bar ? root.bar.background : Color.background
  }
}
