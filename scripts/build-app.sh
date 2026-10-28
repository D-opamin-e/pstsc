#!/bin/bash
# Builds Pstsc.app (release) with its Dock icon and installs it to /Applications.
# Pin this app in the Dock instead of the bare PstscAgent binary: a bare binary shows the
# generic "exec" icon whenever Pstsc is not running.
# 사용법: scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
bin="$(swift build -c release --show-bin-path)"

app="build/Pstsc.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PstscAgent" "$bin/PstscDockProxy" "$app/Contents/MacOS/"

iconset="build/AppIcon.iconset"
rm -rf "$iconset"
"$bin/PstscAgent" --write-iconset "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Pstsc</string>
	<key>CFBundleDisplayName</key><string>Pstsc</string>
	<key>CFBundleIdentifier</key><string>com.pstsc.agent</string>
	<key>CFBundleExecutable</key><string>PstscAgent</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null

rm -rf "/Applications/Pstsc.app"
cp -R "$app" "/Applications/Pstsc.app"
echo "설치됨 / Installed / インストール完了: /Applications/Pstsc.app"
