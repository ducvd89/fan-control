#!/bin/bash
# Builds FanControl.app (release) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI's macros ship with Xcode, not the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

VERSION="${VERSION:-1.0.1}"
APP="build/FanControl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanControl" "$APP/Contents/MacOS/FanControl"
cp "$BIN/FanControlHelper" "$APP/Contents/MacOS/FanControlHelper"
cp Resources/helper.sh "$APP/Contents/Resources/helper.sh"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FanControl</string>
  <key>CFBundleDisplayName</key><string>Fan Control</string>
  <key>CFBundleIdentifier</key><string>local.fancontrol.app</string>
  <key>CFBundleExecutable</key><string>FanControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "Built $APP"
