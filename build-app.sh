#!/bin/bash
# Builds Studio.app into ./build. Usage: ./build-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Studio.app
# Update the bundle in place (never delete it): deleting a running app's bundle makes the Dock lose its tile.
# New files are written next to the old ones and renamed over them, so a running copy keeps its old binary.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Studio "$APP/Contents/MacOS/.Studio.new" && mv -f "$APP/Contents/MacOS/.Studio.new" "$APP/Contents/MacOS/Studio"
cp .build/release/studio-mcp "$APP/Contents/MacOS/.studio-mcp.new" && mv -f "$APP/Contents/MacOS/.studio-mcp.new" "$APP/Contents/MacOS/studio-mcp"
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
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
mv -f "$APP/Contents/.Info.plist.new" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
