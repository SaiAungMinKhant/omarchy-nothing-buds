.pragma library

// earctl reports the enum's serde name ("noise_cancellation_high"); the CLI
// setter takes the short form ("nc-high"). Only the long form ever arrives
// from a read, so the mapping is one-way.
var LEVELS = {
  "off":                            { mode: "off",    strength: "",         label: "ANC off" },
  "transparency":                   { mode: "trans",  strength: "",         label: "Transparency" },
  "noise_cancellation_low":         { mode: "anc",    strength: "nc-low",   label: "ANC low" },
  "noise_cancellation_mid":         { mode: "anc",    strength: "nc-mid",   label: "ANC mid" },
  "noise_cancellation_high":        { mode: "anc",    strength: "nc-high",  label: "ANC high" },
  "noise_cancellation_adaptive":    { mode: "anc",    strength: "adaptive", label: "ANC adaptive" }
}

function level(anc) {
  return LEVELS[String(anc || "")] || { mode: "", strength: "", label: "Unknown" }
}

function modeOf(anc)     { return level(anc).mode }
function strengthOf(anc) { return level(anc).strength }
function labelOf(anc)    { return level(anc).label }

// Glyph for the bar pill. Deliberately three distinct silhouettes so the
// mode is readable at bar size without colour doing the work.
function glyph(connected, anc) {
  if (!connected) return "󰋋"
  var m = modeOf(anc)
  if (m === "trans") return "󰟅"   // ear-hearing: ambient passes through
  if (m === "anc") return "󰟇"     // ear-hearing-off: outside noise blocked
  return "󰋋"                      // headphones: no processing
}

// Lowest of the two buds — the number that actually matters for "do I need
// to charge these". The case is reported separately and is often absent.
function lowestBattery(state) {
  if (!state || state.connected !== true) return -1
  var vals = []
  if (typeof state.left === "number") vals.push(state.left)
  if (typeof state.right === "number") vals.push(state.right)
  return vals.length > 0 ? Math.min.apply(null, vals) : -1
}

function batteryText(value) {
  return typeof value === "number" ? value + "%" : "—"
}

function summary(state) {
  if (!state || state.connected !== true) return "Disconnected"
  var parts = [labelOf(state.anc)]
  var low = lowestBattery(state)
  if (low >= 0) parts.push(low + "%")
  if (state.charging === true) parts.push("charging")
  return parts.join(" · ")
}
