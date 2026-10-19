#!/bin/bash
# Regenerates Resources/AppIcon.icns from logo.png. Run after changing the logo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$ROOT/logo.png" "$WORK/master.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$WORK/master.png" "$ROOT/Resources/AppIcon.png"
echo "Wrote Resources/AppIcon.icns"
