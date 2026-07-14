#!/bin/bash
# Shared Swift compilation contract for every Battery Hog bundle path.

BATTERY_HOG_APP_SOURCES=(
    "$ROOT/src/SystemSupport.swift"
    "$ROOT/src/AgentGateStore.swift"
    "$ROOT/src/BatteryHogStores.swift"
    "$ROOT/src/WorkloadDetector.swift"
    "$ROOT/src/BatteryHogBackend.swift"
    "$ROOT/src/BatteryHogApp.swift"
)

BATTERY_HOG_GATE_SOURCES=(
    "$ROOT/src/SystemSupport.swift"
    "$ROOT/src/AgentGateStore.swift"
    "$ROOT/src/BatteryHogGate.swift"
)

compile_battery_hog_native() {
    local contents="$1"
    xcrun swiftc -parse-as-library -O -whole-module-optimization \
        -target "$SWIFT_TARGET" "${BATTERY_HOG_APP_SOURCES[@]}" \
        -o "$contents/MacOS/BatteryHog" \
        -F "$SPARKLE_ROOT" -framework Sparkle \
        -framework Cocoa -framework WebKit -framework UserNotifications \
        -Xlinker -rpath -Xlinker '@loader_path/../Frameworks'

    xcrun swiftc -parse-as-library -O -whole-module-optimization \
        -target "$SWIFT_TARGET" "${BATTERY_HOG_GATE_SOURCES[@]}" \
        -o "$contents/Helpers/batteryhog-gate" -framework Foundation
    chmod 755 "$contents/Helpers/batteryhog-gate"
}
