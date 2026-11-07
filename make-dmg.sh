#!/bin/bash
# Builds iSound.app and packages it into build/iSound-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/iSound-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/iSound.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
rm -f "$DMG"
# Build read-write first so the disk can show the app icon, then compress.
RW="$STAGE.rw.dmg"
hdiutil create -volname "iSound $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(hdiutil attach -nobrowse -readwrite "$RW" | tail -1 | awk -F'\t' '{print $NF}')
xcrun SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach -quiet "$MOUNT"
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG"
echo "Built $DMG"
