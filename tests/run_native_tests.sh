#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/native-tests"
TARGET="${SWIFT_TARGET:-arm64-apple-macosx11.0}"
mkdir -p "$BUILD"

xcrun swiftc -parse-as-library -Onone -g -D BATTERY_HOG_TESTING \
    -target "$TARGET" \
    "$ROOT/src/SystemSupport.swift" \
    "$ROOT/src/AgentGateStore.swift" \
    "$ROOT/src/BatteryHogStores.swift" \
    "$ROOT/src/WorkloadDetector.swift" \
    "$ROOT/src/BatteryHogBackend.swift" \
    "$ROOT/tests/NativeBackendTests.swift" \
    -o "$BUILD/BatteryHogNativeTests" -framework Foundation -framework AppKit

xcrun swiftc -parse-as-library -Onone -g \
    -target "$TARGET" \
    "$ROOT/src/SystemSupport.swift" \
    "$ROOT/src/AgentGateStore.swift" \
    "$ROOT/src/BatteryHogGate.swift" \
    -o "$BUILD/batteryhog-gate" -framework Foundation

BATTERY_HOG_TEST_GATE="$BUILD/batteryhog-gate" "$BUILD/BatteryHogNativeTests"
