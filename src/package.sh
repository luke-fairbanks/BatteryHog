#!/bin/bash
# Build "Battery Hog.app" and package it into a downloadable .dmg.
#
# Free — no Apple Developer account. The app is ad-hoc signed (required to run on
# Apple Silicon) but NOT notarized, so the first launch shows a Gatekeeper prompt;
# see the README "Download" section for the one-time "Open Anyway" step.
# For a warning-free, notarized build instead, use src/release.sh.
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="${VERSION:-1.0}"
DIST="$ROOT/dist"
APP="$DIST/Battery Hog.app"
DMG="$DIST/BatteryHog-$VERSION.dmg"

rm -rf "$DIST"; mkdir -p "$DIST"
C="$APP/Contents"; mkdir -p "$C/MacOS" "$C/Resources"

echo "==> Icon"
swift make_icon.swift >/dev/null
ICONSET="AppIcon.iconset"; rm -rf "$ICONSET"; mkdir "$ICONSET"
sips -z 16 16   icon_1024.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   icon_1024.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   icon_1024.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   icon_1024.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 icon_1024.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 icon_1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 icon_1024.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 icon_1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 icon_1024.png --out "$ICONSET/icon_512x512.png"    >/dev/null
cp icon_1024.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"

echo "==> Compile (Swift)"
swiftc -O BatteryHogApp.swift -o "$C/MacOS/BatteryHog" -framework Cocoa -framework WebKit

echo "==> Bundle"
cp Info.plist "$C/Info.plist"
cp "$ROOT/battery_hog.py" "$C/Resources/battery_hog.py"
cp "$ROOT/dashboard.html" "$C/Resources/dashboard.html"
printf 'APPL????' > "$C/PkgInfo"

echo "==> Ad-hoc sign"
codesign --force --deep --sign - "$APP"

echo "==> Build DMG"
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Battery Hog" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: $DMG"
