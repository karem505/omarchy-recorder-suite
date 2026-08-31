#!/usr/bin/env bash
# Installer for omarchy-recorder-suite. Copies everything into user-owned
# locations only (never touches /usr/share/omarchy), backs up the two config
# files it edits, and reloads Hyprland + the Omarchy shell.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%s)"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

for dep in gpu-screen-recorder quickshell ffmpeg jq; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep" >&2; exit 1; }
done
pacman -Q qt6-multimedia-ffmpeg >/dev/null 2>&1 ||
  echo "WARNING: qt6-multimedia-ffmpeg not found - Montage needs it for video playback (sudo pacman -S qt6-multimedia-ffmpeg)"

say "Installing scripts to ~/.local/bin"
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/recorder-shim"
install -m 755 "$HERE/bin/"* "$HOME/.local/bin/"
install -m 755 "$HERE/shim/omarchy-notification-send" "$HOME/.local/lib/recorder-shim/"

say "Installing the Montage editor to ~/.config/quickshell/montage"
mkdir -p "$HOME/.config/quickshell/montage"
install -m 644 "$HERE/montage/"* "$HOME/.config/quickshell/montage/"

say "Installing the shell plugin and bar script"
mkdir -p "$HOME/.config/omarchy/plugins/recorder-suite.click-ripple" \
  "$HOME/.config/omarchy/bar/scripts"
install -m 644 "$HERE/plugin/"* "$HOME/.config/omarchy/plugins/recorder-suite.click-ripple/"
install -m 755 "$HERE/bar/recorder-status" "$HOME/.config/omarchy/bar/scripts/"

say "Installing the desktop entry and icon"
mkdir -p "$HOME/.local/share/applications" \
  "$HOME/.local/share/icons/hicolor/scalable/apps"
sed "s|^Exec=montage-editor|Exec=$HOME/.local/bin/montage-editor|" \
  "$HERE/desktop/montage.desktop" >"$HOME/.local/share/applications/montage.desktop"
install -m 644 "$HERE/desktop/montage.svg" \
  "$HOME/.local/share/icons/hicolor/scalable/apps/montage.svg"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

say "Enabling the plugin and bar widget in shell.json"
if [[ -f $SHELL_JSON ]]; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.recorder-suite.$STAMP"
  # Idempotent by construction: remove our entries wherever they are (the
  # user may have moved the widget to another bar section), then add exactly
  # one of each back. Safe to re-run after updates or config resets.
  tmp="$(mktemp)"
  jq '.plugins = ((.plugins // []) | map(select(.id != "recorder-suite.click-ripple"))
        + [{"id": "recorder-suite.click-ripple"}])
      | (if (.bar.layout | type) == "object" then
          .bar.layout |= with_entries(.value |=
            (if type == "array" then map(select(.id != "recorder-status")) else . end))
        else . end)
      | (if (.bar.layout.center | type) == "array" then
          .bar.layout.center += [{
            "id": "recorder-status",
            "type": "command",
            "exec": "~/.config/omarchy/bar/scripts/recorder-status",
            "interval": 1,
            "tooltip": "Recorder status",
            "onClick": "screenrecord-pause-toggle"
          }]
        else . end)' "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
  jq -e '.bar.layout.center | type == "array"' "$SHELL_JSON" >/dev/null ||
    echo "NOTE: shell.json has no bar.layout.center section - add the recorder-status widget manually (see README)."
else
  echo "NOTE: $SHELL_JSON not found - skipping plugin/bar registration."
fi

say "Adding keybindings to ~/.config/hypr/bindings.lua"
if [[ ! -f $BINDINGS ]]; then
  echo "NOTE: $BINDINGS not found - add the keybinding block manually (see README)."
elif grep -q 'omarchy-recorder-suite' "$BINDINGS"; then
  echo "Keybinding block already present - leaving bindings.lua untouched."
elif grep -qE 'screenrecord-pause-toggle|zoom-to-mouse|click-ripple-emit|"screenrecord-toggle"' "$BINDINGS"; then
  # A key bound twice fires twice per press - for the pause toggle that means
  # pause+resume in one hit. Never stack our block on top of manual binds.
  echo "WARNING: bindings.lua already references recorder-suite scripts outside"
  echo "the managed block. Skipping the keybinding append to avoid double-firing"
  echo "keys - remove those lines and re-run, or add the block manually (README)."
else
  cp "$BINDINGS" "$BINDINGS.bak.recorder-suite.$STAMP"
  cat >>"$BINDINGS" <<'EOF'

-- >>> omarchy-recorder-suite >>>
-- Pause/resume whichever recorder is live (system recorder first, then OBS).
o.bind("ALT + P", "Pause/resume recording", "screenrecord-pause-toggle")
-- Smooth zoom-to-mouse, captured live in recordings. Forwards F2 to OBS
-- when nothing is recording and the screen is not zoomed.
o.bind("F2", "Zoom to mouse", "zoom-to-mouse smart")
-- Stock screenrecording toggle, with the saved-notification click rewired
-- to the Montage editor.
hl.unbind("ALT + PRINT")
o.bind("ALT + PRINT", "Screenrecording", "screenrecord-toggle")
-- Click ripple waves while recording; non_consuming passes clicks through.
o.bind("mouse:272", "Click ripple (while recording)", "click-ripple-emit", { non_consuming = true })
-- <<< omarchy-recorder-suite <<<
EOF
fi

say "Reloading Hyprland and the Omarchy shell"
hyprctl reload >/dev/null 2>&1 || true
hyprctl configerrors 2>/dev/null || true
omarchy restart shell >/dev/null 2>&1 || true

say "Done. Record with ALT + PRINT, pause with ALT + P, zoom with F2."
echo "If ALT + P or F2 were already bound on your setup, edit the"
echo "omarchy-recorder-suite block at the bottom of ~/.config/hypr/bindings.lua."
