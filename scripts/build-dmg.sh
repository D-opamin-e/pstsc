#!/bin/bash
# Builds Pstsc.app with bundled FreeRDP and packs it into build/Pstsc-<version>.dmg:
# the app on the left, an Applications shortcut on the right, an arrow in between.
# 사용법: scripts/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh --no-install

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Pstsc.app/Contents/Info.plist)"
dmg="build/Pstsc-$version.dmg"
staging="build/dmg"
rw="build/Pstsc-rw.dmg"
volume="Pstsc"

rm -rf "$staging" "$rw" "$dmg"
mkdir -p "$staging/.background"
cp -R build/Pstsc.app "$staging/"
ln -s /Applications "$staging/Applications"
swift scripts/dmg-background.swift "$staging/.background/background.png"

# Lay the window out on a writable image, then compress it.
hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true
hdiutil create -quiet -srcfolder "$staging" -volname "$volume" -fs HFS+ -format UDRW "$rw"
hdiutil attach -quiet -noautoopen "$rw"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$volume"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 522}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Pstsc.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach -quiet "/Volumes/$volume"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
rm -rf "$rw" "$staging"
echo "DMG: $dmg"
