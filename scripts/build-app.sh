#!/bin/bash
# Builds Wayfile and wraps the executable into build/Wayfile.app.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Wayfile.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Wayfile"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wayfile"
# The sandboxed JavaScript runner lives next to the app's executable.
cp "$(dirname "$BIN")/wayfile-script-runner" "$APP/Contents/MacOS/wayfile-script-runner"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Translations (Resources/Localization/<lang>.lproj, kept up to date by scripts/i18n.py).
cp -R "$ROOT/Resources/Localization/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wayfile</string>
    <key>CFBundleDisplayName</key><string>Wayfile</string>
    <key>CFBundleIdentifier</key><string>dev.wayfile.app</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>sk</string>
    </array>
    <key>CFBundleExecutable</key><string>Wayfile</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>Wayfile looks for file servers (SMB, AFP, WebDAV) on your network to connect to.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_smb._tcp</string>
        <string>_afpovertcp._tcp</string>
        <string>_webdav._tcp</string>
        <string>_webdavs._tcp</string>
    </array>
    <key>NSAppleEventsUsageDescription</key><string>Wayfile runs your AppleScripts and opens Terminal for container shells.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
touch "$APP" # nudge Finder/Dock to pick up a changed icon
echo "Built $APP"
