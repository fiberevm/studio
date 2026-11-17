#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (uses AppKit's SVG renderer; no extra tools).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swiftc -O -o "$tmp/svg2png" scripts/svg2png.swift
set=$tmp/AppIcon.iconset
mkdir -p "$set"
for s in 16 32 128 256 512; do
  "$tmp/svg2png" Resources/AppIcon.svg "$set/icon_${s}x${s}.png" $s >/dev/null
  "$tmp/svg2png" Resources/AppIcon.svg "$set/icon_${s}x${s}@2x.png" $((s * 2)) >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
rm -rf "$tmp"
echo "wrote Resources/AppIcon.icns"
