#!/bin/bash
# Battery Hog's Developer ID team is part of the update trust lineage. A build
# signed by another valid certificate can notarize successfully but cannot
# safely replace the existing app through Sparkle.

if [ -z "${ROOT:-}" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

RELEASE_TEAM_FILE="$ROOT/RELEASE_TEAM_ID"
EXPECTED_TEAM_ID="$(tr -d '[:space:]' < "$RELEASE_TEAM_FILE")"
if [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Invalid RELEASE_TEAM_ID: $EXPECTED_TEAM_ID" >&2
    exit 1
fi

codesign_team_id() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        | awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

require_codesign_team() {
    local target="$1"
    local actual
    actual="$(codesign_team_id "$target")"
    if [ "$actual" != "$EXPECTED_TEAM_ID" ]; then
        echo "Wrong Developer ID team for $target" >&2
        echo "  expected: $EXPECTED_TEAM_ID" >&2
        echo "  actual:   ${actual:-none}" >&2
        exit 1
    fi
}

require_battery_hog_bundle_team() {
    local app="$1"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    local sparkle_bin="$framework/Versions/B"
    local targets=(
        "$sparkle_bin/XPCServices/Installer.xpc"
        "$sparkle_bin/XPCServices/Downloader.xpc"
        "$sparkle_bin/Autoupdate"
        "$sparkle_bin/Updater.app"
        "$framework"
        "$app/Contents/MacOS/BatteryHog"
        "$app"
    )
    local target
    for target in "${targets[@]}"; do
        require_codesign_team "$target"
    done
}
