#!/bin/bash
# Canonical Battery Hog version helpers. This file is sourced by build/release
# scripts; VERSION at the repository root is the only editable version source.

if [ -z "${ROOT:-}" ]; then
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

VERSION_FILE="$ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "Missing canonical version file: $VERSION_FILE" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain exactly three numeric components (found: $VERSION)" >&2
    exit 1
fi

stamp_bundle_version() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Delete :CFBundleShortVersionString" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :CFBundleVersion" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$plist"
}
