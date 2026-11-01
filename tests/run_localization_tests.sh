#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/localization-tests/BatteryHogLocalizationTests.app"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Resources"
cp -R "$ROOT/locales" "$C/Resources/"
xcrun swiftc -parse-as-library "$ROOT/src/Localization.swift" \
    "$ROOT/tests/LocalizationTests.swift" -o "$C/MacOS/LocalizationTests"
cat > "$C/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalizationTests</string>
<key>CFBundleIdentifier</key><string>com.lukefairbanks.batteryhog.localization-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
"$C/MacOS/LocalizationTests" -AppleLanguages '(en)'
"$C/MacOS/LocalizationTests" -AppleLanguages '(zh-Hans)'
