#!/bin/bash
# Build, sign (Developer ID + hardened runtime), notarize, staple, and package
# "Battery Hog.app" into a distributable, Gatekeeper-clean .dmg.
#
# ── One-time setup (needs an Apple Developer Program membership, $99/yr) ──
#   1. In Xcode ▸ Settings ▸ Accounts, add your Apple ID and create a
#      "Developer ID Application" certificate (it lands in your login keychain).
#   2. Save notary credentials once (App-Store-Connect API key or Apple ID):
#        xcrun notarytool store-credentials BatteryHog-notary \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"
#
# ── Usage ──
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash src/release.sh
# Optional env:
#   VERSION=1.2                  bundle/dmg version (default 1.2)
#   NOTARY_PROFILE=BatteryHog-notary
#   SKIP_NOTARIZE=1              build + sign + dmg only (dry run, no notarization)

set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="${VERSION:-1.2}"
NOTARY_PROFILE="${NOTARY_PROFILE:-BatteryHog-notary}"
DIST="$ROOT/dist"
APP="$DIST/Battery Hog.app"
DMG="$DIST/BatteryHog-$VERSION.dmg"
SWIFT_TARGET="${SWIFT_TARGET:-arm64-apple-macosx11.0}"

if [ -z "$SIGN_ID" ]; then
    echo "Set SIGN_ID to your Developer ID Application identity, e.g.:"
    echo '  SIGN_ID="Developer ID Application: Your Name (TEAMID)" bash src/release.sh'
    echo
    echo "Developer ID identities found in your keychain:"
    security find-identity -v -p codesigning | grep "Developer ID Application" \
        || echo "  (none — create one in Xcode ▸ Settings ▸ Accounts)"
    exit 1
fi

echo "==> Clean"
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
if ! iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"; then
    echo "   iconutil rejected the iconset; using the built-in ICNS packer"
    python3 make_icns.py "$ICONSET" "$C/Resources/AppIcon.icns"
fi

echo "==> Compile (Swift)"
swiftc -O -target "$SWIFT_TARGET" BatteryHogApp.swift -o "$C/MacOS/BatteryHog" \
    -framework Cocoa -framework WebKit -framework UserNotifications

echo "==> Bundle"
cp Info.plist "$C/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$C/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$C/Info.plist" 2>/dev/null || true
cp "$ROOT/battery_hog.py" "$C/Resources/battery_hog.py"
cp "$ROOT/batteryhog_workloads.py" "$C/Resources/batteryhog_workloads.py"
cp "$ROOT/batteryhog_gate.py" "$C/Resources/batteryhog_gate.py"
chmod +x "$C/Resources/batteryhog_gate.py"
cp "$ROOT/dashboard.html" "$C/Resources/dashboard.html"
printf 'APPL????' > "$C/PkgInfo"

echo "==> Sign (Developer ID, hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$C/MacOS/BatteryHog"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Build DMG"
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Battery Hog" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
rm -rf "$STAGE"

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "==> SKIP_NOTARIZE set — signed app + DMG are in $DIST (not notarized)."
    exit 0
fi

echo "==> Notarize (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Staple"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP" || true

echo
echo "==> Done:  $DMG"
echo "    Gatekeeper check:  spctl -a -t open --context context:primary-signature -v \"$DMG\""
