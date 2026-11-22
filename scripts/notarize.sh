#!/bin/bash
# Notarizes a Developer ID–signed Studio.app (then writes the release zip) or a signed Studio.dmg,
# and staples the ticket.
# Usage: scripts/notarize.sh build/release/Studio.app build/release/Studio.zip
#        scripts/notarize.sh build/release/Studio.dmg
#
# Credentials, either:
#   App Store Connect API key (recommended):  NOTARY_KEY_PATH (.p8 file), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   or an Apple ID:                           NOTARY_APPLE_ID, NOTARY_PASSWORD (app-specific), NOTARY_TEAM_ID
#   or a saved notarytool profile:            NOTARY_PROFILE (xcrun notarytool store-credentials …)
set -euo pipefail
APP="$1"; ZIP="${2:-}"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  auth=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "notarize.sh: no notary credentials set" >&2; exit 1
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [[ "$APP" == *.dmg ]]; then upload="$APP"
else upload="$tmp/upload.zip"; ditto -c -k --keepParent "$APP" "$upload"; fi
echo "Submitting $(basename "$APP") to Apple's notary service (usually a few minutes)…"
out=$(xcrun notarytool submit "$upload" "${auth[@]}" --wait --output-format json)
echo "$out"
id=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
status=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
if [[ "$status" != "Accepted" ]]; then
  [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" || true
  echo "Notarization failed: $status" >&2; exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
if [[ "$APP" == *.dmg ]]; then
  spctl --assess --type open --context context:primary-signature --verbose "$APP"
  exit 0
fi
spctl --assess --type execute --verbose "$APP"
[[ -n "$ZIP" ]] || exit 0
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Wrote $ZIP"
