#!/bin/bash
# Builds iSound.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/iSound.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/iSound "$APP/Contents/MacOS/iSound"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signing identity keeps macOS permissions across rebuilds (ad-hoc signing resets them).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
