pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Palette sourced from the active Omarchy theme, same file the shell reads
// (~/.local/state/omarchy/current/theme/colors.toml). Watched, so a theme
// change restyles the editor live. Fallbacks only matter if the file is
// missing entirely.
QtObject {
  id: root

  property color background: "#101014"
  property color panel: "#1b1c20"
  property color panelHi: "#2a2b30"
  property color fg: "#e8e3d3"
  property color muted: "#606269"
  property color accent: "#ae6759"
  property color red: "#b7885a"
  property color yellow: "#ffe88b"
  property color green: "#d7be6e"

  // Follows the fontconfig alias omarchy-font-set writes, like the shell bar.
  readonly property string fontFamily: "monospace"

  property FileView colorsFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.load(text())
    onFileChanged: reload()
  }

  function load(raw) {
    var map = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) map[m[1]] = m[2]
    }
    if (map.background) background = map.background
    if (map.foreground) fg = map.foreground
    if (map.muted) muted = map.muted
    if (map.accent) accent = map.accent
    if (map.red) red = map.red
    if (map.yellow) yellow = map.yellow
    if (map.green) green = map.green
    panel = map.lighter_background || Qt.lighter(background, 1.6)
    panelHi = Qt.lighter(panel, 1.35)
  }
}
