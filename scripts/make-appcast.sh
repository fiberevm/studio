#!/bin/bash
# Writes the Sparkle update feed (appcast.xml) for one release to stdout: one item per build (Apple silicon
# and Intel), each pointing at its zip and signed with the EdDSA update key. Installed copies read it from
# https://github.com/fiberevm/studio/releases/latest/download/appcast.xml and update themselves.
# Usage: scripts/make-appcast.sh 0.2.0 <zip> <build> <url> [<zip> <build> <url> …]
#   e.g. scripts/make-appcast.sh 0.2.0 \
#          build/release/Studio-arm64.zip 115 https://github.com/fiberevm/studio/releases/download/v0.2.0/Studio-arm64.zip \
#          build/release/Studio-x86_64.zip 114 https://github.com/fiberevm/studio/releases/download/v0.2.0/Studio-x86_64.zip
#   each zip must be the final one (after notarize.sh rewrote it); 0.2.0 is CFBundleShortVersionString and
#   <build> is that zip's CFBundleVersion, the number Sparkle compares, which must go up with every release.
# A zip published under a name with arm64 in it (the URL) gets <sparkle:hardwareRequirements>arm64: Intel Macs skip that item. Sparkle has no
# Intel-only requirement, so the Apple silicon build must have the higher build number: Apple silicon Macs
# then take it over the Intel one (both are offered to them), Intel Macs take the Intel one.
# The private key comes from SPARKLE_PRIVATE_KEY (CI secret), or from the login keychain when that is unset
# (where Sparkle's generate_keys put it).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; shift
(( $# > 0 && $# % 3 == 0 )) || { echo "make-appcast.sh: expected <zip> <build> <url> triples after the version" >&2; exit 1; }
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x "$SIGN" ]] || { echo "make-appcast.sh: no sign_update at $SIGN (swift package resolve)" >&2; exit 1; }
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
items=""
while (( $# )); do
  ZIP="$1"; BUILD="$2"; URL="$3"; shift 3
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    attrs=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$ZIP")
  else
    attrs=$("$SIGN" "$ZIP")
  fi
  # attrs is: sparkle:edSignature="…" length="…"
  [[ "$attrs" == *'sparkle:edSignature="'* && "$attrs" == *'length="'* ]] || { echo "make-appcast.sh: unexpected sign_update output: $attrs" >&2; exit 1; }
  # …/releases/download/v0.2.0/Studio-arm64.zip → …/releases/tag/v0.2.0 (the release's page, for "What's New")
  TAG_DIR="${URL%/*}"; TAG_URL="${TAG_DIR%/download/*}/tag/${TAG_DIR##*/}"
  HW=""; [[ "${URL##*/}" == *arm64* ]] && HW="
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
  items+="
    <item>
      <title>Studio $VERSION</title>
      <pubDate>$DATE</pubDate>
      <link>$TAG_URL</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>$HW
      <sparkle:fullReleaseNotesLink>$TAG_URL</sparkle:fullReleaseNotesLink>
      <enclosure url=\"$URL\" type=\"application/octet-stream\" $attrs/>
    </item>"
done
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Studio</title>$items
  </channel>
</rss>
XML
