#!/bin/bash
# Build TokenTracker and assemble a menu-bar-only .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="TokenTracker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TokenTracker "$APP/Contents/MacOS/TokenTracker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TokenTracker</string>
    <key>CFBundleIdentifier</key><string>local.tokentracker</string>
    <key>CFBundleName</key><string>Token Tracker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
