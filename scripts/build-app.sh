#!/bin/bash
# Builds Pstsc.app (release) with its Dock icon and bundled FreeRDP/OpenSSL, and installs it to
# /Applications. Pin this app in the Dock instead of the bare PstscAgent binary: a bare binary
# shows the generic "exec" icon whenever Pstsc is not running.
# 사용법: scripts/build-app.sh [--no-install]
set -euo pipefail

cd "$(dirname "$0")/.."
deps="build/deps/freerdp"
[ -f "$deps/lib/libfreerdp3.3.dylib" ] || scripts/build-freerdp.sh
swift build -c release
bin="$(swift build -c release --show-bin-path)"

app="build/Pstsc.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PstscAgent" "$bin/PstscDockProxy" "$app/Contents/MacOS/"

# Bundle FreeRDP and OpenSSL; every reference between them goes through @rpath.
frameworks="$app/Contents/Frameworks"
mkdir -p "$frameworks"
libs="libfreerdp3.3.dylib libfreerdp-client3.3.dylib libwinpr3.3.dylib libssl.3.dylib libcrypto.3.dylib"
for lib in $libs; do
    cp -L "$deps/lib/$lib" "$frameworks/$lib"
    chmod u+w "$frameworks/$lib"
    install_name_tool -id "@rpath/$lib" "$frameworks/$lib" 2>/dev/null
done
# The development rpath points into this checkout; the app only uses Contents/Frameworks.
install_name_tool -delete_rpath "$PWD/$deps/lib" "$app/Contents/MacOS/PstscAgent"
cp "$deps/../FreeRDP-"*/LICENSE "$app/Contents/Resources/LICENSE-FreeRDP.txt"
cp "$deps/../openssl-"*/LICENSE.txt "$app/Contents/Resources/LICENSE-OpenSSL.txt"

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
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$frameworks"/*.dylib >/dev/null
codesign --force --sign - "$app" >/dev/null

[ "${1:-}" = "--no-install" ] && { echo "Built: $app"; exit 0; }
rm -rf "/Applications/Pstsc.app"
cp -R "$app" "/Applications/Pstsc.app"
echo "설치됨 / Installed / インストール完了: /Applications/Pstsc.app"
