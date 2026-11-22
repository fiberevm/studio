#!/bin/bash
# Packs Studio.app into the drag-to-Applications installer: a disk image that opens a window with Studio,
# an arrow and an Applications shortcut. Signs the image when SIGN_IDENTITY is a real identity.
# Usage: scripts/make-dmg.sh build/release/Studio.app build/release/Studio.dmg
# Needs dmgbuild (pipx install dmgbuild), which writes the window layout without driving Finder, so it
# works the same on CI.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"; DMG="$2"
[[ -d "$APP" ]] || { echo "make-dmg.sh: no app at $APP" >&2; exit 1; }

if command -v dmgbuild >/dev/null; then run=(dmgbuild)
elif command -v pipx >/dev/null; then run=(pipx run dmgbuild)
else echo "make-dmg.sh: needs dmgbuild (pipx install dmgbuild)" >&2; exit 1; fi

rm -f "$DMG"
"${run[@]}" -s scripts/dmg-settings.py \
  -D app="$APP" -D background=Resources/dmg/background.tiff -D icon=Resources/AppIcon.icns \
  "Studio" "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "Wrote $DMG"
