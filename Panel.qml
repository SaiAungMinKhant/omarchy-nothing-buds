import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill plus popout for Nothing/CMF earbuds, driven by the `earbuds`
// wrapper around earctl. The wrapper owns the RFCOMM session and answers with
// one compact JSON object, so nothing here touches Bluetooth directly.
//
// Entry point is this file rather than a separate BarWidget.qml, matching the
// bluetooth / network / monitor plugins: one Panel owns both the bar button
// and the popout.
Panel {
  id: root
  moduleName: "io.github.saiaungminkhant.nothing-buds"
  ipcTarget: "io.github.saiaungminkhant.nothing-buds"

  // Last successful reading. `connected: false` is a valid answer, not a
  // failure, so it is stored like any other state.
  // paired:false up front so a missing wrapper does not read as "buds are
  // paired, just not connected" before the first status lands.
  property var state: ({ connected: false, paired: false })

  // Optional overrides from this widget's shell.json layout entry:
  //   { "id": "...", "address": "AA:BB:...", "channel": 16 }
  // Left unset, the wrapper resolves the address from ~/.config/earbuds or
  // by finding the first paired Nothing/CMF device.
  readonly property string cfgAddress: setting("address", "")
  readonly property int cfgChannel: setting("channel", 0)

  // False until the probe finds the wrapper on PATH. The plugin ships QML
  // only, so a fresh install has no `earbuds` until setup/install.sh is run;
  // the panel says so rather than sitting silently broken.
  property bool setupOk: true

  // Wraps a command with any configured overrides. `env` rather than
  // Process.environment so the plugin does not depend on that API being
  // present in the installed Quickshell.
  function cmd(args) {
    var prefix = []
    if (cfgAddress !== "") prefix.push("EARBUDS_ADDR=" + cfgAddress)
    if (cfgChannel > 0) prefix.push("EARBUDS_CHANNEL=" + cfgChannel)
    return prefix.length > 0 ? ["env"].concat(prefix).concat(args) : args
  }
  property bool busy: false
  property string lastError: ""

  readonly property bool connected: state && state.connected === true
  readonly property string anc: connected && state.anc ? String(state.anc) : ""
  readonly property string mode: Model.modeOf(anc)
  readonly property string strength: Model.strengthOf(anc)
  // Paired but not connected is the buds-in-case state: the widget stays on
  // the bar so its switch can bring them back, rather than vanishing and
  // leaving no way to reconnect from here.
  readonly property bool paired: state && state.paired === true
  property bool linking: false

  readonly property bool lowLatency: connected && state.low_latency === true
  readonly property bool inEar: connected && state.in_ear === true

  // Theme bindings, same shape every first-party panel uses. barForeground
  // comes from the Panel base and already tracks the bar's transparency-aware
  // foreground; dimming by 1.55 is the shared convention for "inactive".
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: connected && mode !== "" && mode !== "off"
    ? barForeground : Qt.darker(barForeground, connected ? 1.55 : 2.2)

  readonly property var strengthOptions: [
    { value: "nc-low",   label: "Low" },
    { value: "nc-mid",   label: "Mid" },
    { value: "nc-high",  label: "High" },
    { value: "adaptive", label: "Adaptive" }
  ]

  // Visible whenever the buds are paired, not only while connected: the
  // hero switch reconnects them, so hiding the pill would strand it.
  // Also visible when setup is incomplete: a plugin that installs and shows
  // nothing looks broken, so the pill stays to explain itself.
  visible: paired || !setupOk
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function apply(raw) {
    root.busy = false
    var text = String(raw || "").trim()
    if (!text) return
    try {
      root.state = JSON.parse(text)
      root.lastError = ""
    } catch (e) {
      // A half-written line or a wrapper error: keep the previous reading
      // rather than blanking the pill.
      root.lastError = "Could not read earbud state"
    }
  }

  function refresh() {
    if (root.busy || !root.setupOk) return
    root.busy = true
    statusProc.running = true
  }

  // Selecting a mode keeps whatever ANC strength was already set, so
  // toggling Transparency and back does not silently drop the user from
  // adaptive to high.
  function setMode(next) {
    if (next === "anc") setLevel(root.strength !== "" ? root.strength : "nc-high")
    else if (next === "trans") setLevel("transparency")
    else setLevel("off")
  }

  function setLevel(level) {
    if (root.busy || level === "") return
    root.busy = true
    setProc.command = root.cmd(["earbuds", "anc", "set", level])
    setProc.running = true
  }

  function ring() {
    if (!root.connected) return
    ringProc.running = true
    ringTimer.restart()
  }

  function stopRing() {
    ringTimer.stop()
    unringProc.running = true
  }

  function setLink(on) {
    if (root.linking) return
    root.linking = true
    linkProc.command = root.cmd(["earbuds", on ? "connect" : "disconnect"])
    linkProc.running = true
  }

  function setLatency(on) {
    if (root.busy) return
    root.busy = true
    latencyProc.command = root.cmd(["earbuds", "set", "latency", on ? "true" : "false"])
    latencyProc.running = true
  }

  function setInEar(on) {
    if (root.busy) return
    root.busy = true
    inEarProc.command = root.cmd(["earbuds", "set", "in-ear", on ? "true" : "false"])
    inEarProc.running = true
  }

  Process {
    id: probeProc
    command: ["bash", "-c", "command -v earbuds >/dev/null 2>&1"]
    onExited: function(exitCode) { root.setupOk = exitCode === 0 }
  }

  Component.onCompleted: probeProc.running = true

  Process {
    id: statusProc
    command: root.cmd(["earbuds", "status"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: root.busy = false
  }

  // `earbuds anc set` prints earctl's own ack, not a status object, so the
  // panel re-reads afterwards to pick up the level the buds actually took.
  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: {
      root.busy = false
      Qt.callLater(root.refresh)
    }
  }

  // `earbuds ring` feeds earctl the y/N confirmation it demands on stdin.
  // Calling earctl directly from here is what left the Find button dead: with
  // no stdin the prompt hit EOF and the command cancelled itself.
  Process {
    id: ringProc
    command: root.cmd(["earbuds", "ring"])
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: unringProc
    command: root.cmd(["earbuds", "unring"])
    stdout: StdioCollector { waitForEnd: true }
  }

  // The tone does not stop on its own, so it is bounded here rather than
  // leaving the user to hunt for an off switch.
  Timer {
    id: ringTimer
    interval: 8000
    repeat: false
    onTriggered: root.stopRing()
  }

  // Both setters echo the full post-change status, so one call acts and
  // refreshes without a follow-up poll.
  // bluetoothctl takes a second or two, so the switch shows busy until the
  // status this returns lands.
  Process {
    id: linkProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: {
      root.linking = false
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: latencyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: root.busy = false
  }

  Process {
    id: inEarProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: root.busy = false
  }

  // Slow while closed: battery moves over tens of minutes and every tick is
  // an RFCOMM round trip on a socket that allows a single client. Faster
  // while the panel is open so the readout is not visibly stale.
  Timer {
    interval: root.opened ? 10000 : 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The nerd-font ear glyphs collapse into an unreadable box at bar size,
    // so a Phosphor glyph is drawn instead, with a state light in the corner.
    iconComponent: Component {
      Item {
        anchors.fill: parent

        PhosphorIcon {
          anchors.centerIn: parent
          iconSize: Style.bar.iconCanvas
          icon: "headphones"
          color: root.barIconColor
        }

        StatusDot {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          // Small, and pushed into the corner: at 6px it sat over the right
          // earcup and read as a red earcup rather than a separate light.
          dotSize: Style.space(5)
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          muted: root.barIconColor
          // Disconnected reads as off: an accent dot on a dead link would
          // advertise an ANC state that is not actually in effect.
          mode: root.connected ? root.mode : "off"
          // Punched out of the bar's own background so the dot reads as a
          // separate light rather than part of the glyph.
          outline: root.bar ? root.bar.background : Color.background
        }
      }
    }
    tooltipText: root.opened ? "" : Model.summary(root.state)

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(320))
    // Raised from 520: the circular mode row is taller than the chips it
    // replaced, and the old cap clipped the action buttons off the bottom.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "f" || t === "F") root.ring()
        else if (t === "1") root.setMode("off")
        else if (t === "2") root.setMode("trans")
        else if (t === "3") root.setMode("anc")
        else if (t === "0") root.setLink(!root.connected)
        else if (t === "l" || t === "L") root.setLatency(!root.lowLatency)
        else if (t === "i" || t === "I") root.setInEar(!root.inEar)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: root.state.name ? String(root.state.name) : "Earbuds"
          meta: Model.summary(root.state)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            PhosphorIcon {
              iconSize: Style.space(34)
              icon: "headphones"
              color: root.foreground
              // No state light here: the meta line beneath already spells the
              // mode out, and the selected mode button repeats it.
              opacity: root.connected ? 1.0 : 0.5
            }
          }

          // Connects and disconnects the buds themselves, in the hero's
          // trailing slot where the dropbox and tailscale panels put theirs.
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch

              checked: root.connected
              busy: root.linking
              interactive: root.setupOk
              foreground: root.foreground
              accent: root.foreground
              onToggled: root.setLink(!root.connected)

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.connected ? "Disconnect earbuds" : "Connect earbuds"
                fontFamily: root.fontFamily
              }
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Text {
          visible: !root.setupOk
          width: parent.width
          text: "Setup is not finished. Run setup/install.sh from the plugin "
              + "folder to install earctl, the earbuds wrapper, and its service."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.setupOk && !root.connected
          width: parent.width
          text: "Earbuds are disconnected. Use the switch above to connect."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          visible: root.connected
          text: "Noise Cancellation"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: modeRow
          visible: root.connected
          width: parent.width
          spacing: Style.space(8)

          readonly property real cellWidth: (width - spacing * 2) / 3

          ModeButton { width: modeRow.cellWidth; value: "anc";   label: "Noise cancellation" }
          ModeButton { width: modeRow.cellWidth; value: "trans"; label: "Transparency" }
          ModeButton { width: modeRow.cellWidth; value: "off";   label: "Off" }
        }

        // Strength only exists inside ANC; showing it while off or in
        // transparency would offer a control that does nothing.
        //
        // Hand-rolled rather than a ButtonGroup so the four options can flex
        // to fill the panel: ButtonGroup sizes each chip to its own label,
        // which left "Adaptive" wide, "Low" narrow, and the row hugging the
        // left edge under a centred mode row.
        Row {
          id: strengthRow
          visible: root.connected && root.mode === "anc"
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth:
            (width - spacing * (root.strengthOptions.length - 1)) / root.strengthOptions.length

          Repeater {
            model: root.strengthOptions

            delegate: Button {
              required property var modelData

              width: strengthRow.cellWidth
              text: modelData.label
              selected: root.strength === modelData.value
              bordered: true
              foreground: root.foreground
              accent: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.setLevel(modelData.value)
            }
          }
        }

        PanelSeparator { visible: root.connected; width: parent.width; foreground: root.foreground }

        PanelSectionHeader {
          visible: root.connected
          text: "Battery"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Tiles rather than label/value rows: the meter turns three numbers
        // into something readable at a glance, which is the only question
        // anyone opens this panel to answer.
        Row {
          id: batteryRow
          visible: root.connected
          width: parent.width
          spacing: Style.space(8)

          // The case only reports while it is connected, which it is not
          // while the buds are out of it. A permanent "—" tile would read as
          // broken hardware, so it earns its space only when it has a value.
          readonly property bool hasCase: typeof root.state.case === "number"
          readonly property int tiles: hasCase ? 3 : 2
          readonly property real tileWidth:
            (width - spacing * (tiles - 1)) / tiles

          BatteryTile { width: batteryRow.tileWidth; label: "LEFT";  value: root.state.left }
          BatteryTile { width: batteryRow.tileWidth; label: "RIGHT"; value: root.state.right }
          BatteryTile {
            width: batteryRow.tileWidth
            label: "CASE"
            value: root.state.case
            visible: batteryRow.hasCase
          }
        }

        PanelSeparator { visible: root.connected; width: parent.width; foreground: root.foreground }

        PanelSectionHeader {
          visible: root.connected
          text: "Playback"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Toggle {
          visible: root.connected
          width: parent.width
          label: "Low lag mode"
          description: "Lower audio delay for games"
          checked: root.lowLatency
          foreground: root.foreground
          accent: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setLatency(!root.lowLatency)
        }

        Toggle {
          visible: root.connected
          width: parent.width
          label: "In-ear detection"
          description: "Pause when a bud is removed"
          checked: root.inEar
          foreground: root.foreground
          accent: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setInEar(!root.inEar)
        }

        PanelSeparator { visible: root.connected; width: parent.width; foreground: root.foreground }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(8)

          readonly property real buttonWidth: (width - spacing) / 2

          Button {
            width: actionRow.buttonWidth
            enabled: root.connected
            opacity: root.connected ? 1.0 : 0.45
            text: ringTimer.running ? "Stop" : "Find"
            iconText: "󰂚"
            tooltipText: ringTimer.running ? "Stop the tone" : "Ring both buds"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: ringTimer.running ? root.stopRing() : root.ring()
          }

          Button {
            width: actionRow.buttonWidth
            enabled: root.setupOk
            opacity: root.setupOk ? 1.0 : 0.45
            text: "Refresh"
            iconText: "󰑐"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.refresh()
          }
        }
      }
    }
  }

  // Circular mode button with its label beneath, matching the Nothing X
  // layout. The selected one inverts -- filled with the foreground, icon
  // knocked out in the panel background -- which is how the app marks it.
  component ModeButton: Item {
    id: modeButton

    property string value: ""
    property string label: ""

    // ear-slash = outside sound blocked, ear = outside sound let in,
    // prohibit = nothing applied, which is also the mark Nothing X uses
    // for Off.
    readonly property string iconName: value === "trans" ? "ear"
      : (value === "off" ? "prohibit" : "ear-slash")

    readonly property bool selected: root.mode === value
    readonly property real diameter: Style.space(44)

    implicitHeight: modeColumn.implicitHeight

    Column {
      id: modeColumn
      width: parent.width
      spacing: Style.space(6)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: modeButton.diameter
        height: modeButton.diameter
        radius: width / 2
        color: modeButton.selected
          ? root.foreground
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

        Behavior on color { ColorAnimation { duration: 180 } }

        PhosphorIcon {
          anchors.centerIn: parent
          iconSize: Style.space(22)
          icon: modeButton.iconName
          color: modeButton.selected ? Color.popups.background : root.foreground
        }
      }

      Text {
        width: parent.width
        text: modeButton.label
        color: modeButton.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setMode(modeButton.value)
    }
  }

  component BatteryTile: Item {
    id: tile

    property string label: ""
    property var value: null

    readonly property bool known: typeof value === "number"
    readonly property real fraction: known ? Math.max(0, Math.min(1, value / 100)) : 0
    // Matches the shell's own battery convention: urgent below 20, dimmed
    // when there is no reading at all.
    readonly property color tone: !known ? root.dim
      : (value <= 20 ? root.urgent : root.foreground)

    implicitHeight: tileColumn.implicitHeight

    Column {
      id: tileColumn
      width: parent.width
      spacing: Style.space(4)

      Text {
        text: tile.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(3)

        Text {
          text: tile.known ? tile.value : "—"
          color: tile.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          visible: tile.known
          text: "%"
          color: tile.tone
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.baseline: parent.children[0].baseline
        }
      }

      Item {
        width: parent.width
        implicitHeight: Style.space(4)

        Rectangle {
          id: meterTrack
          anchors.fill: parent
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        }

        Rectangle {
          anchors.left: meterTrack.left
          anchors.verticalCenter: meterTrack.verticalCenter
          height: meterTrack.height
          radius: meterTrack.radius
          color: tile.tone
          width: tile.known
            ? Math.max(meterTrack.height, meterTrack.width * tile.fraction)
            : 0

          Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 220 } }

          // Same pulse the power panel uses while charging: a moving signal
          // that energy is flowing in, rather than a static bar.
          SequentialAnimation on opacity {
            running: root.state.charging === true && root.opened
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
          }
        }
      }
    }
  }
}
