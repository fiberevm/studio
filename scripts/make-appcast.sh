#!/bin/bash
# Writes the Sparkle update feed (appcast.xml) for one release to stdout: a single item pointing at that
# release's Studio.zip, signed with the EdDSA update key. Installed copies read it from
# https://github.com/fiberevm/studio/releases/latest/download/appcast.xml and update themselves.
# Usage: scripts/make-appcast.sh build/release/Studio.zip 0.2.0 57 https://github.com/fiberevm/studio/releases/download/v0.2.0/Studio.zip
#   the zip must be the final one (after notarize.sh rewrote it); 0.2.0 is CFBundleShortVersionString and
#   57 is CFBundleVersion, the number Sparkle compares, which must go up with every release.
# The private key comes from SPARKLE_PRIVATE_KEY (CI secret), or from the login keychain when that is unset
# (where Sparkle's generate_keys put it).
set -euo pipefail
cd "$(dirname "$0")/.."
ZIP="$1"; VERSION="$2"; BUILD="$3"; URL="$4"
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x "$SIGN" ]] || { echo "make-appcast.sh: no sign_update at $SIGN (swift package resolve)" >&2; exit 1; }
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  attrs=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$ZIP")
else
  attrs=$("$SIGN" "$ZIP")
fi
# attrs is: sparkle:edSignature="…" length="…"
[[ "$attrs" == *'sparkle:edSignature="'* && "$attrs" == *'length="'* ]] || { echo "make-appcast.sh: unexpected sign_update output: $attrs" >&2; exit 1; }
TAG_URL="${URL%/*}"; TAG_URL="${TAG_URL/\/download\//\/tag\/}"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Studio</title>
    <item>
      <title>Studio $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>$TAG_URL</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$TAG_URL</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $attrs/>
    </item>
  </channel>
</rss>
XML
