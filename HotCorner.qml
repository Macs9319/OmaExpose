import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Headless service: watches the cursor and summons the Expose overlay when
// it dwells in a screen corner, the way macOS hot corners work. Polls
// `hyprctl cursorpos` because Hyprland has no cursor-position signal exposed
// to Quickshell; the interval is short but the command is a cheap local
// socket round-trip.
Item {
  id: root

  property var shell: null

  readonly property string pluginId: "ronnie.expose"
  // One of: "top-left", "top-right", "bottom-left", "bottom-right".
  readonly property string corner: "top-left"
  readonly property int zonePx: 3
  readonly property int dwellMs: 300
  readonly property int pollMs: 120
  readonly property int cooldownMs: 900

  property int dwellAccumMs: 0
  property bool cooling: false

  function monitorAt(x, y) {
    var mons = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      var scale = m.scale > 0 ? m.scale : 1
      var w = m.width / scale
      var h = m.height / scale
      if (x >= m.x && x < m.x + w && y >= m.y && y < m.y + h)
        return { x: m.x, y: m.y, width: w, height: h }
    }
    return null
  }

  function inHotZone(x, y) {
    var m = root.monitorAt(x, y)
    if (!m) return false
    var lx = x - m.x
    var ly = y - m.y
    if (root.corner === "top-right") return lx >= m.width - root.zonePx && ly <= root.zonePx
    if (root.corner === "bottom-left") return lx <= root.zonePx && ly >= m.height - root.zonePx
    if (root.corner === "bottom-right") return lx >= m.width - root.zonePx && ly >= m.height - root.zonePx
    return lx <= root.zonePx && ly <= root.zonePx
  }

  function trigger() {
    if (!root.shell) return
    if (root.shell.isPluginOpen(root.pluginId)) return
    root.shell.summon(root.pluginId, "{}")
    root.cooling = true
    cooldownTimer.restart()
  }

  Timer {
    id: cooldownTimer
    interval: root.cooldownMs
    onTriggered: root.cooling = false
  }

  Timer {
    id: pollTimer
    interval: root.pollMs
    running: true
    repeat: true
    onTriggered: if (!cursorProc.running) cursorProc.running = true
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(text || "").trim()
        var m = /^(-?[0-9]+),\s*(-?[0-9]+)$/.exec(out)
        if (!m) {
          root.dwellAccumMs = 0
          return
        }
        if (root.cooling) {
          root.dwellAccumMs = 0
          return
        }
        var x = parseInt(m[1], 10)
        var y = parseInt(m[2], 10)
        if (root.inHotZone(x, y)) {
          root.dwellAccumMs += root.pollMs
          if (root.dwellAccumMs >= root.dwellMs) {
            root.dwellAccumMs = 0
            root.trigger()
          }
        } else {
          root.dwellAccumMs = 0
        }
      }
    }
  }
}
