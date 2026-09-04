import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill plus popout for Nothing/CMF earbuds, driven by the `earbuds`
// wrapper (one JSON object per call). One Panel owns both the bar button and
// the popout, like the first-party plugins.
//
// Two rules from the marketplace security review: setup never runs without a
// click, and every spawned helper is bounded (timeout on the process group,
// capped output, watchdog so busy/link state cannot wedge).
Panel {
  id: root
  moduleName: "io.github.saiaungminkhant.nothing-buds"
  ipcTarget: "io.github.saiaungminkhant.nothing-buds"

  // Last successful reading; connected:false is a valid state.
  property var state: ({ connected: false, paired: false })

  // ---------------------------------------------------------------- paths
  // Absolute paths, never PATH-resolved.
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || homeDir + "/.local/state")
    + "/io.github.saiaungminkhant.nothing-buds"
  readonly property string earbudsBin: homeDir + "/.local/bin/earbuds"
  readonly property string earctlLocal: homeDir + "/.local/bin/earctl"
  readonly property string earctlUsr: "/usr/bin/earctl"
  // Omarchy's own launcher; /usr/share/omarchy/bin holds a symlink to it.
  readonly property string launchTui: "/usr/bin/omarchy-launch-tui"

  // Resolved from this file so a renamed plugin folder still works.
  readonly property string setupScript: {
    var url = String(Qt.resolvedUrl("setup/install.sh"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  // ------------------------------------------------------------- overrides
  // Per-widget overrides from shell.json ({ "address": "AA:BB:...",
  // "channel": 16 }), validated before they reach the wrapper.
  readonly property string cfgAddress: setting("address", "")
  readonly property int cfgChannel: setting("channel", 0)

  readonly property bool addrValid:
    cfgAddress !== "" && /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(cfgAddress)
  readonly property bool channelValid: cfgChannel >= 1 && cfgChannel <= 63

  readonly property string configNotice: {
    var bad = []
    if (cfgAddress !== "" && !addrValid) bad.push("address")
    if (cfgChannel !== 0 && !channelValid) bad.push("channel")
    return bad.length > 0
      ? "Ignoring invalid " + bad.join(" and ") + " in shell.json"
      : ""
  }

  // The wrapper takes overrides as arguments, never as environment.
  function cmd(args) {
    var out = [earbudsBin]
    if (addrValid) out.push("--address", cfgAddress)
    if (channelValid) out.push("--channel", String(cfgChannel))
    return out.concat(args)
  }

  // ---------------------------------------------------------------- setup
  // Complete only when the wrapper (byte-identical to the shipped one),
  // earctl and the unit all exist; `install.sh --check` answers that and
  // changes nothing.
  property bool setupComplete: false
  // The "Set up" click: the consent that lets later states finish the job.
  property bool setupConsented: false
  // Installer exit 2: everything but earctl, which needs a terminal.
  property bool needsEarctl: false
  // The terminal install is detached, so polling is how we notice.
  property bool earctlPresent: false
  property bool bootstrapping: false

  property bool busy: false
  property string lastError: ""

  function probeCmd() { return [setupScript, "--check"] }

  // earctl alone, as a bare /usr/bin/test: no shell in sight.
  function earctlCmd() {
    return ["/usr/bin/test", "-x", earctlUsr, "-o", "-x", earctlLocal]
  }

  function probe() { probeProc.start(probeCmd()) }

  function bootstrap() {
    if (root.bootstrapping || root.setupComplete) return
    root.bootstrapping = true
    root.lastError = ""
    bootstrapProc.start([setupScript, "--yes"])
  }

  // A real terminal, so the installer can prompt and yay can ask for a
  // password. Detached; the poll below notices when it finishes.
  function installEarctl() {
    Quickshell.execDetached([launchTui, setupScript])
  }

  function firstNote(text) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].replace(/^\s*nothing-buds:\s*/, "").trim()
      if (t !== "") return t.length > 180 ? t.substring(0, 177) + "..." : t
    }
    return ""
  }

  function bootstrapDone(code, err) {
    root.bootstrapping = false
    if (code === 0) {
      root.needsEarctl = false
    } else if (code === 2) {
      // Everything is in place except earctl, which needs a terminal.
      root.needsEarctl = true
    } else if (code === 3) {
      root.lastError = "Setup needs bluetoothctl and jq (bluez-utils and jq)."
    } else if (code === 5) {
      root.lastError = firstNote(err) ||
        "Setup refused: a pre-existing file is in the way (see README)."
    } else if (code === 124) {
      root.lastError = "Setup timed out."
    } else {
      root.lastError = firstNote(err) || ("Setup failed (exit " + code + ").")
    }
    root.probe()
  }

  readonly property bool connected: linkUp && state && state.connected === true
  readonly property string anc: connected && state.anc ? String(state.anc) : ""
  readonly property string mode: Model.modeOf(anc)
  readonly property string strength: Model.strengthOf(anc)
  // Link state comes from BlueZ directly (instant); the wrapper is still the source for ANC and battery.
  readonly property var btDevices: Bluetooth.devices ? Bluetooth.devices.values : []

  readonly property var btDevice: {
    var wanted = String(root.cfgAddress).toUpperCase()
    var fallback = null
    for (var i = 0; i < btDevices.length; i++) {
      var d = btDevices[i]
      if (!d) continue
      if (wanted !== "" && String(d.address || "").toUpperCase() === wanted) return d
      // No pinned address: first paired device the wrapper would also pick.
      if (fallback === null && d.paired && /nothing|(^|\s)cmf\s|ear \(/i.test(String(d.name || "")))
        fallback = d
    }
    return wanted !== "" ? null : fallback
  }

  readonly property bool paired: btDevice !== null && btDevice.paired === true
  readonly property string deviceName: btDevice && btDevice.name ? String(btDevice.name) : "Earbuds"

  // A fresh link still needs its RFCOMM session, so this waits for the wrapper.
  readonly property bool linkUp: btDevice !== null && btDevice.connected === true
  property bool linking: false

  // Connect finished with the link still down: usually the buds are in their case.
  property bool linkFailed: false

  readonly property bool lowLatency: connected && state.low_latency === true
  readonly property bool inEar: connected && state.in_ear === true

  // Theme bindings as in every first-party panel; 1.55 is the shared "inactive" dim.
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

  // Always on the bar once enabled; the pill dims rather than hiding.
  visible: true
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
      // Keep the previous reading rather than blanking the pill.
      root.lastError = "Could not read earbud state"
    }
  }

  function refresh() {
    if (root.busy || !root.setupComplete) return
    root.busy = true
    statusProc.start(root.cmd(["status"]))
  }

  // Keep the ANC strength when switching modes.
  function setMode(next) {
    if (next === "anc") setLevel(root.strength !== "" ? root.strength : "nc-high")
    else if (next === "trans") setLevel("transparency")
    else setLevel("off")
  }

  function setLevel(level) {
    if (root.busy || level === "") return
    root.busy = true
    setProc.start(root.cmd(["set", "anc", level]))
  }

  function ring() {
    if (!root.connected) return
    ringProc.start(root.cmd(["ring"]))
    ringTimer.restart()
  }

  function stopRing() {
    ringTimer.stop()
    unringProc.start(root.cmd(["unring"]))
  }

  function setLink(on) {
    if (root.linking || !root.setupComplete) return
    root.linkFailed = false
    root.linking = true
    linkProc.start(root.cmd([on ? "connect" : "disconnect"]))
  }

  function setLatency(on) {
    if (root.busy) return
    root.busy = true
    latencyProc.start(root.cmd(["set", "latency", on ? "true" : "false"]))
  }

  function setInEar(on) {
    if (root.busy) return
    root.busy = true
    inEarProc.start(root.cmd(["set", "in-ear", on ? "true" : "false"]))
  }

  function stopAll() {
    var ps = [probeProc, earctlProc, bootstrapProc, statusProc, setProc,
              ringProc, unringProc, linkProc, latencyProc, inEarProc]
    for (var i = 0; i < ps.length; i++) ps[i].stop()
  }

  Component.onCompleted: root.probe()
  Component.onDestruction: root.stopAll()

  // BlueZ said so; ask the wrapper for details now rather than next poll.
  onLinkUpChanged: Qt.callLater(root.refresh)

  // ------------------------------------------------------------------ setup
  // processes

  component BoundedProcess: Process {
    id: bp

    // Seconds /usr/bin/timeout enforces, including the KILL grace.
    property string deadline: "30"
    // Ceiling on buffered stdout; more than this is a misbehaving helper.
    property int cap: 8192
    // Called exactly once per start: (exitCode, stdout, stderr, ok)
    property var onDone: null

    property string outBuf: ""
    property string errBuf: ""
    property bool overflowed: false
    property bool live: false
    // A start() that arrived while the old run was still dying; launched from onExited.
    property var pendingArgs: null

    function start(args) {
      if (bp.running) {
        // Supersede: TERM the old run, drop its late answers, queue this one.
        bp.pendingArgs = args
        bp.live = false
        bp.running = false
        return
      }
      bp.launch(args)
    }

    function launch(args) {
      bp.outBuf = ""
      bp.errBuf = ""
      bp.overflowed = false
      bp.live = true
      bp.command = ["/usr/bin/timeout", "--kill-after=5", bp.deadline].concat(args)
      bp.running = true
      watch.interval = (parseInt(bp.deadline, 10) + 8) * 1000
      watch.restart()
    }

    // Abandon in-flight and queued work; used on destruction.
    function stop() {
      bp.pendingArgs = null
      bp.live = false
      watch.stop()
      bp.running = false
    }

    function take(line, isErr) {
      if (!bp.live) return
      if (isErr) {
        if (bp.errBuf.length < 4096) bp.errBuf += line + "\n"
        return
      }
      if (bp.outBuf.length + line.length > bp.cap) {
        bp.overflowed = true
        bp.live = false
        bp.running = false
        if (bp.onDone) bp.onDone(126, "", bp.errBuf, false)
        return
      }
      bp.outBuf += line + "\n"
    }

    stdout: SplitParser { onRead: function(line) { bp.take(line, false) } }
    stderr: SplitParser { onRead: function(line) { bp.take(line, true) } }

    onExited: function(exitCode, exitStatus) {
      watch.stop()
      var wasLive = bp.live
      bp.live = false
      if (bp.pendingArgs !== null) {
        var next = bp.pendingArgs
        bp.pendingArgs = null
        bp.launch(next)
        return
      }
      // Superseded, overflowed or watchdog-timed-out runs were already answered for.
      if (!wasLive) return
      var killed = exitStatus !== 0
      if (bp.onDone)
        bp.onDone(exitCode, bp.overflowed ? "" : bp.outBuf, bp.errBuf, !killed && exitCode === 0)
    }

    Timer {
      id: watch
      interval: 38000
      onTriggered: {
        // The binary timeout should have fired long before this; this exists so
        // a lost onExited can never wedge state.
        bp.live = false
        bp.running = false
        if (bp.onDone) bp.onDone(124, "", bp.errBuf, false)
      }
    }
  }

  // Full setup check: wrapper current, earctl and unit file present.
  BoundedProcess {
    id: probeProc
    deadline: "5"
    onDone: function(code, out, err, ok) {
      root.setupComplete = ok
      if (ok) {
        root.needsEarctl = false
        root.lastError = ""
      }
    }
  }

  // Earctl alone; used to notice the terminal install finishing.
  BoundedProcess {
    id: earctlProc
    deadline: "3"
    onDone: function(code, out, err, ok) { root.earctlPresent = ok }
  }

  BoundedProcess {
    id: bootstrapProc
    deadline: "240"
    cap: 16384
    onDone: function(code, out, err, ok) { root.bootstrapDone(code, err) }
  }

  // Poll until setup is done; a detached terminal sends no signal back.
  Timer {
    interval: 4000
    running: !root.setupComplete
    repeat: true
    onTriggered: {
      root.probe()
      if (root.needsEarctl) earctlProc.start(root.earctlCmd())
    }
  }

  // ----------------------------------------------------------------- status
  // processes

  BoundedProcess {
    id: statusProc
    deadline: "40"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (ok) root.apply(out)
      else if (code === 124) root.lastError = "The earbuds command timed out."
      else root.lastError = "Could not read earbud state."
    }
  }

  // Re-read so the panel shows the level the buds actually took.
  BoundedProcess {
    id: setProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (!ok && code === 124) root.lastError = "The earbuds command timed out."
      Qt.callLater(root.refresh)
    }
  }

  BoundedProcess {
    id: ringProc
    deadline: "20"
  }

  BoundedProcess {
    id: unringProc
    deadline: "20"
  }

  // The tone does not stop on its own.
  Timer {
    id: ringTimer
    interval: 8000
    repeat: false
    onTriggered: root.stopRing()
  }

  // bluetoothctl plus the RFCOMM re-establish take a few seconds.
  BoundedProcess {
    id: linkProc
    deadline: "60"
    onDone: function(code, out, err, ok) {
      root.linking = false
      if (ok) root.apply(out)
      // BlueZ is the authority here, and it has already settled by now.
      root.linkFailed = !root.linkUp
      Qt.callLater(root.refresh)
    }
  }

  // Setters echo the full status, so no follow-up poll.
  BoundedProcess {
    id: latencyProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (ok) root.apply(out)
    }
  }

  BoundedProcess {
    id: inEarProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (ok) root.apply(out)
    }
  }

  // A read costs about 0.2s; poll fast while open, slow while closed.
  Timer {
    interval: root.opened ? 5000 : 45000
    running: root.setupComplete
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd-font ear glyphs are unreadable at bar size.
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
          // Small and cornered so it does not read as a red earcup.
          dotSize: Style.space(5)
          anchors.rightMargin: -Style.space(1)
          anchors.bottomMargin: -Style.space(1)
          muted: root.barIconColor
          // A dead link shows off, not a stale ANC state.
          mode: root.connected ? root.mode : "off"
          // Punched out of the bar background.
          outline: root.bar ? root.bar.background : Color.background
        }
      }
    }
    tooltipText: root.opened ? ""
      : (!root.setupComplete ? "Setup required"
         : (root.paired ? Model.summary(root.state) : "No earbuds paired"))

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
    // 520 clipped the action buttons.
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
          title: root.deviceName
          // "Disconnected" would be a lie before setup.
          meta: !root.setupComplete ? "Setup required"
              : (root.paired ? Model.summary(root.state) : "No earbuds paired")
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            PhosphorIcon {
              iconSize: Style.space(34)
              icon: "headphones"
              color: root.foreground
              // The meta line already spells the mode out.
              opacity: root.connected ? 1.0 : 0.5
            }
          }

          // Connect/disconnect switch in the hero's trailing slot.
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch

              checked: root.connected
              busy: root.linking
              interactive: root.setupComplete && root.paired
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

        // Not set up, nothing clicked: explain and wait for the click.
        Column {
          visible: !root.setupComplete && !root.setupConsented && !root.bootstrapping
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "Setup installs a few things outside this plugin's folder:\n"
                + "the earbuds command in ~/.local/bin, a systemd --user\n"
                + "service that talks to the earbuds, and a small config in\n"
                + "~/.config/earbuds. Nothing runs as root. earctl itself may\n"
                + "need your password; if it is missing, setup stops and offers\n"
                + "a terminal."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: "Set up now"
            iconText: "󰇚"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              root.setupConsented = true
              root.bootstrap()
            }
          }
        }

        // Setup was consented to and is somewhere in flight.
        Column {
          visible: !root.setupComplete && root.setupConsented
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: root.bootstrapping
            width: parent.width
            text: "Setting things up..."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !root.bootstrapping && root.needsEarctl && !root.earctlPresent
            width: parent.width
            text: "Everything is installed except earctl, which talks to "
                + "the earbuds. Installing it may ask for your password, "
                + "so it needs a terminal."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.bootstrapping && root.needsEarctl && !root.earctlPresent
            width: parent.width
            text: "Install earctl"
            iconText: "󰇚"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.installEarctl()
          }

          // earctl appeared on its own: one more explicit click finishes the job.
          Text {
            visible: !root.bootstrapping && root.lastError === ""
              && (!root.needsEarctl || root.earctlPresent)
            width: parent.width
            text: "Almost there. Finish the setup that was agreed to:"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.bootstrapping && (!root.needsEarctl || root.earctlPresent)
            width: parent.width
            text: root.lastError !== "" ? "Try setup again" : "Finish setup"
            iconText: "󰇚"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.bootstrap()
          }
        }

        Column {
          visible: root.setupComplete && !root.paired
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "No Nothing or CMF earbuds are paired yet. Pair them once "
                + "and this panel takes over from there."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: "Open Bluetooth"
            iconText: "󰂯"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.bluetooth")
          }
        }

        Column {
          visible: root.setupComplete && root.paired && !root.connected
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            // Say Bluetooth explicitly; everything below needs the link.
            text: root.linkUp
                ? "Connected over Bluetooth. Waiting for the earbuds to answer."
                : (root.linkFailed
                    ? "The earbuds did not answer. Take them out of the case, "
                      + "then try the switch again."
                    : "Connect over Bluetooth first, with the switch above or "
                      + "from the Bluetooth panel. Everything else needs that link.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.linkUp
            width: parent.width
            text: "Open Bluetooth"
            iconText: "󰂯"
            bordered: true
            foreground: root.foreground
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.bluetooth")
          }
        }

        PanelSectionHeader {
          visible: root.connected && root.setupComplete
          text: "Noise Cancellation"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: modeRow
          visible: root.connected && root.setupComplete
          width: parent.width
          spacing: Style.space(8)

          readonly property real cellWidth: (width - spacing * 2) / 3

          ModeButton { width: modeRow.cellWidth; value: "anc";   label: "Noise cancellation" }
          ModeButton { width: modeRow.cellWidth; value: "trans"; label: "Transparency" }
          ModeButton { width: modeRow.cellWidth; value: "off";   label: "Off" }
        }

        // Strength only exists inside ANC. Hand-rolled so the four chips flex
        // evenly (ButtonGroup sizes each to its label).
        Row {
          id: strengthRow
          visible: root.setupComplete && root.connected && root.mode === "anc"
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
          visible: root.connected && root.setupComplete
          text: "Battery"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Tiles: the meter is readable at a glance.
        Row {
          id: batteryRow
          visible: root.connected && root.setupComplete
          width: parent.width
          spacing: Style.space(8)

          // The case only reports while connected; a permanent "—" would read as broken.
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
          visible: root.connected && root.setupComplete
          text: "Playback"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Toggle {
          visible: root.connected && root.setupComplete
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
          visible: root.connected && root.setupComplete
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

        Button {
          width: parent.width
          enabled: root.connected && root.setupComplete
          opacity: root.connected && root.setupComplete ? 1.0 : 0.45
          text: ringTimer.running ? "Stop" : "Find"
          iconText: "󰂚"
          tooltipText: ringTimer.running ? "Stop the tone" : "Ring both buds"
          bordered: true
          foreground: root.foreground
          accent: root.foreground
          fontFamily: root.fontFamily
          onClicked: ringTimer.running ? root.stopRing() : root.ring()
        }

        Text {
          visible: root.configNotice !== "" && root.setupComplete
          width: parent.width
          text: root.configNotice
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component ModeButton: Item {
    id: modeButton

    property string value: ""
    property string label: ""

    // ear-slash blocks, ear lets through, prohibit is off (as in Nothing X).
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
    // Shell battery convention: urgent below 20, dim when unknown.
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

          // Same pulse the power panel uses while charging.
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
