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
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

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
  // What the user just asked for. Shown as applied until the next reading
  // confirms or corrects it, so the click itself is the feedback.
  property string pendingAnc: ""
  property string pendingCodec: ""
  // -1 none, 0 off, 1 on
  property int pendingLatency: -1
  property int pendingInEar: -1
  property int pendingBassLevel: 0
  readonly property string shownAnc: pendingAnc !== "" ? pendingAnc : anc
  readonly property string shownMode: Model.modeOf(shownAnc)
  readonly property string shownStrength: Model.strengthOf(shownAnc)
  readonly property string shownCodec: pendingCodec !== "" ? pendingCodec : codec
  readonly property bool shownLatency: pendingLatency >= 0 ? pendingLatency === 1 : lowLatency
  readonly property bool shownInEar: pendingInEar >= 0 ? pendingInEar === 1 : inEar
  readonly property int shownBassLevel: pendingBassLevel > 0 ? pendingBassLevel : bassLevel
  property string lastError: ""
  // Find asks first: the tone is loud enough to hurt a bud still in an ear.
  property bool ringConfirmOpen: false

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

  // A real terminal, so the installer can prompt and show build progress.
  // Detached; the poll below notices when it finishes.
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

  // Ear (3)-only features. The wrapper reports null on models that don't
  // support them, so `has*` gates whether the control appears at all.
  readonly property bool hasSuperMic: connected && typeof state.super_mic === "boolean"
  // Spatial audio has no getter, so support comes from the model earctl
  // resolved. Ear (3) and CMF Buds 2 take it; on Ear (3) it excludes bass.
  readonly property string modelBase: connected && state.model_base ? String(state.model_base) : ""
  readonly property bool hasSpatial: modelBase === "B173" || modelBase === "B179"
  readonly property bool bassExcludesSpatial: modelBase === "B173"
  readonly property bool superMic: connected && state.super_mic === true
  readonly property bool hasEnhancedBass: connected && typeof state.enhanced_bass === "boolean"
  readonly property bool enhancedBass: connected && state.enhanced_bass === true
  readonly property int bassLevel: connected && typeof state.bass_level === "number" ? state.bass_level : 0
  // Five levels, confirmed from the app: device byte = level * 2 (2..10).
  readonly property var bassLevels: [1, 2, 3, 4, 5]
  // Spatial audio is set-only (the buds expose no getter), so its state is
  // local intent, not a reading. It can drift if changed from the phone.
  property bool spatialFixed: false

  // A2DP codec is a host/PipeWire setting, reported by the wrapper via pactl.
  readonly property string codec: connected && state.codec ? String(state.codec) : ""
  readonly property var codecs: connected && state.codecs ? state.codecs : []

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

  function apply(raw) {
    root.busy = false
    var text = String(raw || "").trim()
    if (!text) return
    try {
      root.state = JSON.parse(text)
      root.pendingAnc = ""
      root.pendingCodec = ""
      root.pendingLatency = -1
      root.pendingInEar = -1
      root.pendingBassLevel = 0
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
    if (next === "anc") setLevel(root.shownStrength !== "" ? root.shownStrength : "nc-high")
    else if (next === "trans") setLevel("transparency")
    else setLevel("off")
  }

  // A click beats a status poll, which is abandoned, and an earlier click
  // of the same kind, which start() supersedes. A different set still in
  // flight refuses, so two writes never race on the one RFCOMM session.
  function claim(proc) {
    if (!root.busy) { root.busy = true; return true }
    if (statusProc.live) { statusProc.stop(); return true }
    return proc.live
  }

  function setLevel(level) {
    if (level === "" || !root.claim(setProc)) return
    root.pendingAnc = Model.longOf(level)
    setProc.start(root.cmd(["set", "anc", level]))
  }

  function askRing() {
    if (!root.connected || !root.setupComplete || ringTimer.running) return
    ringConfirm.selectedIndex = 1
    root.ringConfirmOpen = true
  }

  function cancelRing() {
    root.ringConfirmOpen = false
  }

  function ring() {
    root.ringConfirmOpen = false
    if (!root.connected) return
    ringProc.start(root.cmd(["ring"]))
    ringTimer.restart()
  }

  // The one click the Find button acts on: ask first, or stop a running tone.
  function toggleRing() {
    if (ringTimer.running) root.stopRing()
    else root.askRing()
  }

  function stopRing() {
    root.ringConfirmOpen = false
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
    if (!root.claim(latencyProc)) return
    root.pendingLatency = on ? 1 : 0
    latencyProc.start(root.cmd(["set", "latency", on ? "true" : "false"]))
  }

  function setInEar(on) {
    if (!root.claim(inEarProc)) return
    root.pendingInEar = on ? 1 : 0
    inEarProc.start(root.cmd(["set", "in-ear", on ? "true" : "false"]))
  }

  function setSuperMic(on) {
    if (!root.claim(superMicProc)) return
    superMicProc.start(root.cmd(["set", "super-mic", on ? "true" : "false"]))
  }

  // Enabling bass keeps the current level (or 2 the first time). The wrapper
  // clears spatial when bass turns on; mirror that locally so the tile agrees.
  function setEnhancedBass(on) {
    if (!root.claim(bassProc)) return
    if (on && root.bassExcludesSpatial) root.spatialFixed = false
    var lvl = root.bassLevel >= 1 && root.bassLevel <= 5 ? root.bassLevel : 3
    bassProc.start(root.cmd(["set", "enhanced-bass", on ? "true" : "false", String(lvl)]))
  }

  function setBassLevel(n) {
    if (n < 1 || n > 5 || !root.claim(bassProc)) return
    root.pendingBassLevel = n
    if (root.bassExcludesSpatial) root.spatialFixed = false
    bassProc.start(root.cmd(["set", "enhanced-bass", "true", String(n)]))
  }

  // Set-only: reflect the intent locally, since status carries no spatial
  // field. Enabling spatial clears bass on the device (mutual exclusivity).
  function setSpatial(fixed) {
    if (!root.claim(spatialProc)) return
    root.spatialFixed = fixed
    spatialProc.start(root.cmd(["set", "spatial", fixed ? "fixed" : "off"]))
  }

  function setCodec(name) {
    if (name === "" || name === root.shownCodec || !root.claim(codecProc)) return
    root.pendingCodec = String(name)
    codecProc.start(root.cmd(["set", "codec", String(name)]))
  }

  function stopAll() {
    var ps = [probeProc, earctlProc, bootstrapProc, statusProc, setProc,
              ringProc, unringProc, linkProc, latencyProc, inEarProc,
              superMicProc, bassProc, spatialProc, codecProc]
    for (var i = 0; i < ps.length; i++) ps[i].stop()
  }

  Component.onCompleted: root.probe()
  Component.onDestruction: root.stopAll()

  // BlueZ said so; ask the wrapper for details now rather than next poll.
  onLinkUpChanged: Qt.callLater(root.refresh)

  // Closing the panel or losing the buds withdraws the question.
  onOpenedChanged: if (!root.opened) root.cancelRing()
  onConnectedChanged: if (!root.connected) root.cancelRing()

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
      bp.watchdog.interval = (parseInt(bp.deadline, 10) + 8) * 1000
      bp.watchdog.restart()
    }

    // Abandon in-flight and queued work; used on destruction.
    function stop() {
      bp.pendingArgs = null
      bp.live = false
      bp.watchdog.stop()
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
      bp.watchdog.stop()
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

    // Process has no default child property. Keep the watchdog in an explicit
    // object-valued property so the component can be instantiated by QML.
    property Timer watchdog: Timer {
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

  // The wrapper echoes a fresh status after the set, so no second read.
  BoundedProcess {
    id: setProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      root.pendingAnc = ""
      if (ok) root.apply(out)
      else if (code === 124) root.lastError = "The earbuds command timed out."
      else Qt.callLater(root.refresh)
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
      root.pendingLatency = -1
      if (ok) root.apply(out)
    }
  }

  BoundedProcess {
    id: inEarProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      root.pendingInEar = -1
      if (ok) root.apply(out)
    }
  }

  BoundedProcess {
    id: superMicProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (ok) root.apply(out)
    }
  }

  BoundedProcess {
    id: bassProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      root.pendingBassLevel = 0
      if (ok) root.apply(out)
    }
  }

  // Spatial has no read-back of its own, but enabling it clears bass on the
  // device, so re-read to update the bass tile.
  BoundedProcess {
    id: spatialProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      if (ok) root.apply(out)
      else Qt.callLater(root.refresh)
    }
  }

  // The wrapper waits for the sink to come back before it echoes status,
  // so the spinner runs for as long as the switch really takes.
  BoundedProcess {
    id: codecProc
    deadline: "20"
    onDone: function(code, out, err, ok) {
      root.busy = false
      root.pendingCodec = ""
      if (ok) root.apply(out)
      if (!ok || root.codec === "") Qt.callLater(root.refresh)
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    // 520 clipped the action buttons.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.ringConfirmOpen ? root.cancelRing() : root.close()
      onTabRequested: function(direction) {
        if (root.ringConfirmOpen) ringConfirm.selectedIndex = ringConfirm.selectedIndex === 0 ? 1 : 0
        else root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.ringConfirmOpen && dx !== 0) ringConfirm.selectedIndex = ringConfirm.selectedIndex === 0 ? 1 : 0
      }
      onActivateRequested: {
        if (!root.ringConfirmOpen) return
        if (ringConfirm.selectedIndex === 0) root.cancelRing()
        else root.ring()
      }
      onTextKey: function(t) {
        if (root.ringConfirmOpen) return
        if (t === "r" || t === "R") root.refresh()
        else if (t === "f" || t === "F") root.toggleRing()
        else if (t === "1") root.setMode("off")
        else if (t === "2") root.setMode("trans")
        else if (t === "3") root.setMode("anc")
        else if (t === "0") root.setLink(!root.connected)
        else if (t === "l" || t === "L") root.setLatency(!root.lowLatency)
        else if (t === "i" || t === "I") root.setInEar(!root.inEar)
        else if ((t === "b" || t === "B") && root.hasEnhancedBass) root.setEnhancedBass(!root.enhancedBass)
        else if ((t === "s" || t === "S") && root.hasSpatial) root.setSpatial(!root.spatialFixed)
        else if ((t === "m" || t === "M") && root.hasSuperMic) root.setSuperMic(!root.superMic)
      }

      // Sits over the whole card; the scrim swallows clicks and the key
      // catcher routes Esc, Tab, arrows and Enter to it while it is open.
      // Local copy of the shell's ConfirmDialog so the buttons can be centred.
      ConfirmCard {
        id: ringConfirm
        anchors.fill: parent
        z: 10
        opened: root.ringConfirmOpen
        message: "This will ring the earbuds loudly,\nare you sure?"
        confirmText: "Ring"
        background: root.bar ? root.bar.background : Color.background
        foreground: root.foreground
        urgent: root.urgent
        fontFamily: root.fontFamily
        onCanceled: root.cancelRing()
        onConfirmed: root.ring()
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
                + "~/.config/earbuds. Nothing runs as root. If earctl is missing,\n"
                + "setup offers a terminal to build it from pinned source.\n"
                + "Git and a Rust toolchain are required for the build."
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
                + "the earbuds. Setup builds it from pinned source in a terminal. "
                + "Git and a Rust toolchain are required; no password is needed."
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
          visible: root.setupComplete && root.connected && root.shownMode === "anc"
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
              selected: root.shownStrength === modelData.value
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

        Grid {
          id: playbackGrid
          visible: root.connected && root.setupComplete
          width: parent.width
          columns: 2
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(8)

          readonly property real cellWidth: (width - columnSpacing) / 2

          ToggleTile {
            width: playbackGrid.cellWidth
            label: "Low lag"
            tip: "Lower audio delay for games"
            checked: root.shownLatency
            onToggled: root.setLatency(!root.shownLatency)
          }

          ToggleTile {
            width: playbackGrid.cellWidth
            label: "In-ear"
            tip: "Pause when a bud is removed"
            checked: root.shownInEar
            onToggled: root.setInEar(!root.shownInEar)
          }

          ToggleTile {
            visible: root.hasSuperMic
            width: playbackGrid.cellWidth
            label: "Super Mic"
            tip: "Case Talk-button mic for calls"
            checked: root.superMic
            onToggled: root.setSuperMic(!root.superMic)
          }
        }

        // Laid out as in Nothing X: two round choices, Fixed and Off.
        PanelSectionHeader {
          visible: root.connected && root.setupComplete && root.hasSpatial
          text: "Spatial audio"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          visible: root.connected && root.setupComplete && root.hasSpatial
          width: parent.width
          readonly property real cellWidth: (width - spacing) / 2
          spacing: Style.space(8)

          ChoiceButton {
            width: parent.cellWidth
            label: "Fixed"
            iconName: "circle-dashed"
            selected: root.spatialFixed
            onChosen: root.setSpatial(true)
          }

          ChoiceButton {
            width: parent.cellWidth
            label: "Off"
            iconName: "prohibit"
            selected: !root.spatialFixed
            onChosen: root.setSpatial(false)
          }
        }

        // Ultra bass as in Nothing X: a switch, and a five-step slider while on.
        Toggle {
          visible: root.connected && root.setupComplete && root.hasEnhancedBass
          width: parent.width
          label: "Ultra bass"
          description: root.enhancedBass ? "Level " + root.shownBassLevel : "Off"
          checked: root.enhancedBass
          foreground: root.foreground
          accent: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setEnhancedBass(!root.enhancedBass)
        }

        Item {
          visible: root.connected && root.setupComplete && root.hasEnhancedBass && root.enhancedBass
          width: parent.width
          height: Style.space(34)

          PanelSlider {
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 1
            maximum: 5
            step: 1
            integer: true
            tickCount: 5
            value: root.shownBassLevel
            onReleased: function(v) { root.setBassLevel(Math.round(v)) }
          }
        }

        PanelSeparator { visible: root.connected; width: parent.width; foreground: root.foreground }

        PanelSectionHeader {
          visible: root.connected && root.setupComplete && root.codecs.length > 0
          text: "Audio codec"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Chips for each codec the buds currently advertise (LDAC needs the
        // Nothing X "High-quality audio" setting on and dual connection off).
        Row {
          id: codecRow
          visible: root.connected && root.setupComplete && root.codecs.length > 0
          width: parent.width
          spacing: Style.space(6)

          readonly property int count: root.codecs.length
          readonly property real cellWidth:
            count > 0 ? (width - spacing * (count - 1)) / count : width

          Repeater {
            model: root.codecs

            delegate: Button {
              required property var modelData

              readonly property bool switching: root.pendingCodec === modelData

              width: codecRow.cellWidth
              // Switching renegotiates the A2DP link, which takes a few
              // seconds. The chip shows only a spinning icon until the new
              // codec reads back, centred by the button itself, and keeps
              // its resting height so the row does not move.
              property real restingHeight: 0
              onImplicitHeightChanged: if (!switching) restingHeight = implicitHeight
              height: switching && restingHeight > 0 ? restingHeight : implicitHeight
              text: switching ? "" : String(modelData).toUpperCase()
              iconText: switching ? "󰑓" : ""
              iconSize: fontSize
              iconSpinning: switching
              selected: root.shownCodec === modelData
              bordered: true
              foreground: root.foreground
              accent: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.setCodec(modelData)
            }
          }
        }

        PanelSeparator {
          visible: root.connected && root.setupComplete && root.codecs.length > 0
          width: parent.width
          foreground: root.foreground
        }

        Button {
          width: parent.width
          enabled: root.connected && root.setupComplete
          opacity: root.connected && root.setupComplete ? 1.0 : 0.45
          text: ringTimer.running ? "Stop" : "Find (f)"
          iconText: "󰂚"
          tooltipText: ringTimer.running ? "Stop the tone" : "Ring both buds (asks first)"
          bordered: true
          foreground: root.foreground
          accent: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.toggleRing()
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

  // Compact half-width switch tile for the Playback grid. Fill and border
  // come from the theme foreground, as in ModeButton. The row owns the
  // click; the switch is presentation only.
  component ToggleTile: Rectangle {
    id: tile

    property string label: ""
    property string tip: ""
    property bool checked: false
    signal toggled()

    readonly property bool hot: tileMouse.containsMouse

    implicitHeight: Style.space(46)
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, tile.hot ? 0.08 : 0.04)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, tile.hot ? 0.25 : 0.14)

    Behavior on color { ColorAnimation { duration: 100 } }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(6)

      Text {
        width: parent.width - tileSwitch.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        text: tile.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      ToggleSwitch {
        id: tileSwitch
        anchors.verticalCenter: parent.verticalCenter
        checked: tile.checked
        interactive: false
        foreground: root.foreground
        accent: root.foreground
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.toggled()
    }

    PanelToolTip {
      visible: tileMouse.containsMouse && tile.tip !== ""
      text: tile.tip
      fontFamily: root.fontFamily
    }
  }

  // Round choice with a caption, the ANC row look, for any two-way setting.
  component ChoiceButton: Item {
    id: choice

    property string label: ""
    property string iconName: ""
    property bool selected: false
    signal chosen()

    readonly property real diameter: Style.space(44)
    implicitHeight: choiceColumn.implicitHeight

    Column {
      id: choiceColumn
      width: parent.width
      spacing: Style.space(6)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: choice.diameter
        height: choice.diameter
        radius: width / 2
        color: choice.selected
          ? root.foreground
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

        Behavior on color { ColorAnimation { duration: 180 } }

        PhosphorIcon {
          anchors.centerIn: parent
          iconSize: Style.space(22)
          icon: choice.iconName
          color: choice.selected ? Color.popups.background : root.foreground
        }
      }

      Text {
        width: parent.width
        text: choice.label
        color: choice.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: choice.chosen()
    }
  }

  component ModeButton: Item {
    id: modeButton

    property string value: ""
    property string label: ""

    // ear-slash blocks, ear lets through, prohibit is off (as in Nothing X).
    readonly property string iconName: value === "trans" ? "ear"
      : (value === "off" ? "prohibit" : "ear-slash")

    readonly property bool selected: root.shownMode === value
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

      // "LEFT   75%" on one line keeps the section short.
      Item {
        width: parent.width
        implicitHeight: labelText.implicitHeight

        Text {
          id: labelText
          anchors.left: parent.left
          text: tile.label
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          anchors.right: parent.right
          anchors.baseline: labelText.baseline
          text: tile.known ? tile.value + "%" : "—"
          color: tile.tone
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
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
