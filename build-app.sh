#!/bin/bash
# Builds Studio.app into ./build. Usage: ./build-app.sh [--open]
#   APP=path/Studio.app      where to build the bundle (default build/Studio.app)
#   VERSION=1.2.3            CFBundleShortVersionString (default 0.1); BUILD_NUMBER sets CFBundleVersion
#   SIGN_IDENTITY="Developer ID Application: …"   sign for distribution (hardened runtime + timestamp),
#                            ready for scripts/notarize.sh; without it the app is signed ad hoc for local use.
set -euo pipefail
cd "$(dirname "$0")"
#   UNIVERSAL=1              build for Apple silicon and Intel (release builds)
if [[ -n "${UNIVERSAL:-}" ]]; then
  # One arch at a time (a combined multi-arch build trips over SwiftTerm's build plugin), then lipo.
  swift build -c release --arch arm64
  swift build -c release --arch x86_64
  BIN=.build/universal; mkdir -p "$BIN"
  for b in Studio studio-mcp studio-attach; do
    lipo -create .build/arm64-apple-macosx/release/$b .build/x86_64-apple-macosx/release/$b -output "$BIN/$b"
  done
else
  swift build -c release
  BIN=.build/release
fi
APP="${APP:-build/Studio.app}"
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
# Update the bundle in place (never delete it): deleting a running app's bundle makes the Dock lose its tile.
# New files are written next to the old ones and renamed over them, so a running copy keeps its old binary.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Studio" "$APP/Contents/MacOS/.Studio.new" && mv -f "$APP/Contents/MacOS/.Studio.new" "$APP/Contents/MacOS/Studio"
cp "$BIN/studio-mcp" "$APP/Contents/MacOS/.studio-mcp.new" && mv -f "$APP/Contents/MacOS/.studio-mcp.new" "$APP/Contents/MacOS/studio-mcp"
cp "$BIN/studio-attach" "$APP/Contents/MacOS/.studio-attach.new" && mv -f "$APP/Contents/MacOS/.studio-attach.new" "$APP/Contents/MacOS/studio-attach"
# Studio's Claude plugin (skills), loaded into every session it starts with --plugin-dir
rm -rf "$APP/Contents/Resources/.StudioPlugin.new" && cp -R Resources/StudioPlugin "$APP/Contents/Resources/.StudioPlugin.new" \
  && rm -rf "$APP/Contents/Resources/StudioPlugin" && mv "$APP/Contents/Resources/.StudioPlugin.new" "$APP/Contents/Resources/StudioPlugin"
# AWS Lambda MicroVMs sandbox image (agent + Dockerfile + one-time setup script)
rm -rf "$APP/Contents/Resources/.MicroVMAgent.new" && cp -R Resources/MicroVMAgent "$APP/Contents/Resources/.MicroVMAgent.new" \
  && rm -rf "$APP/Contents/Resources/MicroVMAgent" && mv "$APP/Contents/Resources/.MicroVMAgent.new" "$APP/Contents/Resources/MicroVMAgent"
cp Resources/AppIcon.icns "$APP/Contents/Resources/.AppIcon.new" && mv -f "$APP/Contents/Resources/.AppIcon.new" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/.Info.plist.new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Studio</string>
  <key>CFBundleDisplayName</key><string>Studio</string>
  <key>CFBundleIdentifier</key><string>dev.local.studio</string>
  <key>CFBundleExecutable</key><string>Studio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
mv -f "$APP/Contents/.Info.plist.new" "$APP/Contents/Info.plist"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inside out: the bundled MCP server first, then the app. Hardened runtime and a secure timestamp are
  # what notarization requires.
  for bin in "$APP/Contents/MacOS/studio-mcp" "$APP/Contents/MacOS/studio-attach" "$APP"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bin"
  done
  codesign --verify --strict --deep "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
