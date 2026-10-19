#!/bin/bash
# Packs build/Wayfile.app into build/Wayfile-<version>.dmg (drag-to-Applications layout).
# Usage: scripts/make-dmg.sh [--build]   (--build runs scripts/build-app.sh release first)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wayfile.app"

[[ "${1:-}" == "--build" ]] && "$ROOT/scripts/build-app.sh" release
[[ -d "$APP" ]] || { echo "No $APP — run scripts/build-app.sh first (or pass --build)"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Wayfile-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Wayfile $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG" >/dev/null 2>&1 || true
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
