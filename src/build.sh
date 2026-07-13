#!/bin/bash
# Builds "Battery Hog.app" from the sources in this folder.
set -e
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
APP="$ROOT/Battery Hog.app"
C="$APP/Contents"
SWIFT_TARGET="${SWIFT_TARGET:-arm64-apple-macosx11.0}"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources"

echo "==> Building icon (.icns)"
swift make_icon.swift >/dev/null
ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"; mkdir "$ICONSET"
sips -z 16 16     icon_1024.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     icon_1024.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     icon_1024.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     icon_1024.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   icon_1024.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   icon_1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   icon_1024.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   icon_1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   icon_1024.png --out "$ICONSET/icon_512x512.png"    >/dev/null
cp icon_1024.png "$ICONSET/icon_512x512@2x.png"
if ! iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"; then
    echo "   iconutil rejected the iconset; using the built-in ICNS packer"
    python3 make_icns.py "$ICONSET" "$C/Resources/AppIcon.icns"
fi

echo "==> Compiling Swift app"
swiftc -O -target "$SWIFT_TARGET" BatteryHogApp.swift -o "$C/MacOS/BatteryHog" \
    -framework Cocoa -framework WebKit -framework UserNotifications

echo "==> Assembling bundle"
cp Info.plist "$C/Info.plist"
cp "$ROOT/battery_hog.py" "$C/Resources/battery_hog.py"
cp "$ROOT/batteryhog_workloads.py" "$C/Resources/batteryhog_workloads.py"
cp "$ROOT/batteryhog_gate.py" "$C/Resources/batteryhog_gate.py"
chmod +x "$C/Resources/batteryhog_gate.py"
cp "$ROOT/dashboard.html" "$C/Resources/dashboard.html"
printf 'APPL????' > "$C/PkgInfo"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> Installing to /Applications"
rm -rf "/Applications/Battery Hog.app"
cp -R "$APP" "/Applications/" && echo "   installed: /Applications/Battery Hog.app"
rm -rf "$APP"   # remove staging copy; the installed one in /Applications is canonical

echo "==> Done. Launch 'Battery Hog' from Spotlight or Launchpad."
