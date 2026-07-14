#!/bin/bash
# Build "Battery Hog.app" and package it into a downloadable .dmg.
#
# Free — no Apple Developer account. The app is ad-hoc signed (required to run on
# Apple Silicon) but NOT notarized, so the first launch shows a Gatekeeper prompt;
# see the README "Download" section for the one-time "Open Anyway" step.
# For a warning-free, notarized build instead, use src/release.sh.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
source "$ROOT/src/version.sh"
SPARKLE_ROOT="$(bash "$ROOT/src/fetch_sparkle.sh")"
APP_NAME="${APP_NAME:-Battery Hog}"
BUNDLE_ID="${BUNDLE_ID:-com.lukefairbanks.batteryhog}"
DIST="${DIST:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${DMG_NAME:-BatteryHog-$VERSION.dmg}"
SWIFT_TARGET="${SWIFT_TARGET:-arm64-apple-macosx11.0}"
source "$ROOT/src/native_build.sh"

rm -rf "$DIST"; mkdir -p "$DIST"
C="$APP/Contents"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks" "$C/Helpers"

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
if ! iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"; then
    echo "   iconutil rejected the iconset; using the built-in ICNS packer"
    python3 make_icns.py "$ICONSET" "$C/Resources/AppIcon.icns"
fi

echo "==> Compile (Swift)"
compile_battery_hog_native "$C"

echo "==> Bundle"
cp Info.plist "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$C/Info.plist"
stamp_bundle_version "$C/Info.plist"
ditto "$SPARKLE_ROOT/Sparkle.framework" "$C/Frameworks/Sparkle.framework"
cp "$SPARKLE_ROOT/LICENSE" "$C/Resources/Sparkle-LICENSE.txt"
cp "$ROOT/dashboard.html" "$C/Resources/dashboard.html"
printf 'APPL????' > "$C/PkgInfo"

echo "==> Ad-hoc sign"
codesign --force --sign - "$C/Helpers/batteryhog-gate"
codesign --force --sign - "$C/MacOS/BatteryHog"
codesign --force --sign - "$APP"
codesign --deep --verify --strict "$APP"

if [ "${SKIP_DMG:-0}" = "1" ]; then
    echo "==> Done: $APP"
    exit 0
fi

echo "==> Build DMG"
"$ROOT/src/build_dmg.sh" "$APP" "$DMG" "Battery Hog Installer"

echo "==> Done: $DMG"
