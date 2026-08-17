// Pure helpers for the nbfc fan-control panel. No state — anything stateful
// belongs on Panel.qml.
//
// The nbfc CLI is the single source of truth: `nbfc status` is parsed here
// into fan records, and the panel stages edits (mode / fan / percent) that are
// only written back via `nbfc set` when the user presses Save.

function clampPercent(value) {
  var n = Number(value)
  if (!isFinite(n)) return 50
  return Math.max(0, Math.min(100, Math.round(n)))
}

// "CPU fan" -> "CPU", "GPU fan" -> "GPU". Strips a trailing "fan"/"Fan"
// word; leaves everything else untouched.
function shortName(name) {
  var n = String(name || "").replace(/\s*fan\s*$/i, "").trim()
  return n || String(name || "")
}

// Parse the human-readable `nbfc status` output into fan records.
//
//   Read-only                : false
//   Selected Config Name     : Acer Nitro AN515-57
//
//   Fan Display Name         : CPU fan
//   Temperature              : 62.50
//   Auto Control Enabled     : true
//   Critical Mode Enabled    : false
//   Current Fan Speed        : 3703.00
//   Target Fan Speed         : 47.00
//   Fan Speed Steps          : 100
//
// Returns { readOnly, configName, fans: [{ name, shortName, temperature,
// auto, critical, rpm, target, steps }] }.
function parseStatus(text) {
  var out = { readOnly: false, configName: "", fans: [] }
  var lines = String(text || "").split("\n")
  var current = null
  var i, line, m, key, value
  for (i = 0; i < lines.length; i++) {
    line = lines[i].replace(/\r$/, "")
    m = line.match(/^\s*([^:]+?)\s*:\s*(.*?)\s*$/)
    if (!m) continue
    key = m[1].replace(/\s+$/, "")
    value = m[2].trim()
    if (key === "Fan Display Name") {
      current = {
        name: value,
        shortName: shortName(value),
        temperature: 0,
        auto: true,
        critical: false,
        rpm: 0,
        target: 0,
        steps: 100
      }
      out.fans.push(current)
    } else if (key === "Read-only") {
      out.readOnly = value === "true"
    } else if (key === "Selected Config Name") {
      out.configName = value
    } else if (current) {
      if (key === "Temperature") current.temperature = Number(value)
      else if (key === "Auto Control Enabled") current.auto = value === "true"
      else if (key === "Critical Mode Enabled") current.critical = value === "true"
      else if (key === "Current Fan Speed") current.rpm = Number(value)
      else if (key === "Target Fan Speed") current.target = Number(value)
      else if (key === "Fan Speed Steps") current.steps = Number(value)
    }
  }
  return out
}

// Derive the applied (on-system) UI state from a fan list:
//   - all fans in auto   -> mode "auto" (fan/percent irrelevant)
//   - one fan manual     -> mode "manual" selecting that fan at its target %
//   - all fans manual at the same % -> mode "manual", "all fans" at that %
//   - otherwise          -> first manual fan at its target %
// Returns { mode, fanIndex, percent } where fanIndex -1 = all fans.
function deriveApplied(fans) {
  var manual = []
  var i
  for (i = 0; i < fans.length; i++) if (!fans[i].auto) manual.push(i)
  if (manual.length === 0) return { mode: "auto", fanIndex: -1, percent: 50 }

  var first = manual[0]
  var allManual = manual.length === fans.length
  var same = true
  for (i = 0; i < manual.length; i++) {
    if (Math.round(fans[manual[i]].target) !== Math.round(fans[first].target)) same = false
  }
  if (allManual && same) return { mode: "manual", fanIndex: -1, percent: clampPercent(fans[first].target) }
  return { mode: "manual", fanIndex: first, percent: clampPercent(fans[first].target) }
}

// ASCII fan art: 4 static frames, one per speed quartile. More spokes = faster
// fan (2 spokes at <=25%, 4 at <=50%, 6 at <=75%, 8 above). The selected frame
// is picked by fanFrame() from the fan's speed percent; there is no animation.
// All lines are 5 chars wide so the art box stays put as frames swap.
var FAN_FRAMES = [
  "     \n  │  \n  ◯  \n  │  \n     ",
  "     \n  │  \n──◯──\n  │  \n     ",
  "    ╱\n  │ ╱\n──◯──\n ╱│  \n╱    ",
  "╲   ╱\n ╲│╱ \n──◯──\n ╱│╲ \n╱   ╲"
]

// Index into FAN_FRAMES for a fan running at the given speed percent
// (0-100). Bounds clamp so out-of-range input still selects a valid frame.
function fanFrame(speedPercent) {
  var p = Number(speedPercent) || 0
  if (p <= 25) return 0
  if (p <= 50) return 1
  if (p <= 75) return 2
  return 3
}

if (typeof module !== "undefined") {
  module.exports = {
    clampPercent: clampPercent,
    shortName: shortName,
    parseStatus: parseStatus,
    deriveApplied: deriveApplied,
    FAN_FRAMES: FAN_FRAMES,
    fanFrame: fanFrame
  }
}