#!/usr/bin/env bash
# Removes everything install.sh put in place. The keybinding block and the
# shell.json entries are removed in place (backups are made first).
set -euo pipefail

STAMP="$(date +%s)"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"

rm -f "$HOME/.local/bin/"{screenrecord-pause-toggle,screenrecord-toggle,zoom-to-mouse,click-ripple-emit,recorder-notify-watch,montage-editor}
rm -rf "$HOME/.local/lib/recorder-shim"
rm -rf "$HOME/.config/quickshell/montage"
rm -rf "$HOME/.config/omarchy/plugins/recorder-suite.click-ripple"
rm -f "$HOME/.config/omarchy/bar/scripts/recorder-status"
rm -f "$HOME/.local/share/applications/montage.desktop"
rm -f "$HOME/.local/share/icons/hicolor/scalable/apps/montage.svg"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

if [[ -f $BINDINGS ]] && grep -q 'omarchy-recorder-suite' "$BINDINGS"; then
  cp "$BINDINGS" "$BINDINGS.bak.recorder-suite-uninstall.$STAMP"
  sed -i '/>>> omarchy-recorder-suite >>>/,/<<< omarchy-recorder-suite <<</d' "$BINDINGS"
fi

if [[ -f $SHELL_JSON ]] && grep -q 'recorder-suite.click-ripple\|recorder-status' "$SHELL_JSON"; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.recorder-suite-uninstall.$STAMP"
  tmp="$(mktemp)"
  # Strip the widget from every bar section - the user may have moved it.
  jq '.plugins = ((.plugins // []) | map(select(.id != "recorder-suite.click-ripple")))
      | (if (.bar.layout | type) == "object" then
          .bar.layout |= with_entries(.value |=
            (if type == "array" then map(select(.id != "recorder-status")) else . end))
        else . end)' \
    "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
fi

hyprctl reload >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true
echo "omarchy-recorder-suite removed."
