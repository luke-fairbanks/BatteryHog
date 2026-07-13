#!/bin/bash
# Stages a complete GitHub release as a draft. Publishing remains a deliberate
# second step after the DMG and update feed have been reviewed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/version.sh"
source "$SCRIPT_DIR/release_identity.sh"

TAG="v$VERSION"
DMG="$ROOT/dist/BatteryHog-$VERSION.dmg"
APPCAST="$ROOT/dist/appcast.xml"
SPARKLE_ROOT="$(bash "$SCRIPT_DIR/fetch_sparkle.sh")"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.lukefairbanks.batteryhog}"
WORK=""
MOUNT_DIR=""

cleanup() {
    if [ -n "$MOUNT_DIR" ] && mount | grep -Fq " on $MOUNT_DIR "; then
        hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    fi
    [ -z "$MOUNT_DIR" ] || rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -f "$DMG" ] || [ ! -f "$APPCAST" ]; then
    echo "Run the full notarized release first; expected:" >&2
    echo "  $DMG" >&2
    echo "  $APPCAST" >&2
    exit 66
fi
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Refusing to stage a release from a dirty worktree." >&2
    exit 1
fi
if [ "$(git -C "$ROOT" branch --show-current)" != "main" ]; then
    echo "Releases must be staged from main." >&2
    exit 1
fi

echo "==> Verify release artifacts before touching GitHub"
hdiutil verify "$DMG" >/dev/null
codesign --verify --strict --verbose=2 "$DMG"
require_codesign_team "$DMG"
xcrun stapler validate "$DMG"

MOUNT_DIR="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG" >/dev/null
require_battery_hog_bundle_team "$MOUNT_DIR/Battery Hog.app"
hdiutil detach "$MOUNT_DIR" -quiet
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

xmllint --noout "$APPCAST"
"$SPARKLE_ROOT/bin/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" --verify "$APPCAST"

APPCAST_VERSION="$(xmllint --xpath \
    'string(//*[local-name()="item"]/*[local-name()="version"])' "$APPCAST")"
APPCAST_URL="$(xmllint --xpath \
    'string(//*[local-name()="enclosure"]/@url)' "$APPCAST")"
EXPECTED_URL="https://github.com/luke-fairbanks/BatteryHog/releases/download/$TAG/BatteryHog-$VERSION.dmg"
if [ "$APPCAST_VERSION" != "$VERSION" ] || [ "$APPCAST_URL" != "$EXPECTED_URL" ]; then
    echo "Appcast version or enclosure URL does not match VERSION." >&2
    exit 1
fi
ARCHIVE_SIGNATURE="$(xmllint --xpath \
    'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST")"
if [ -z "$ARCHIVE_SIGNATURE" ]; then
    echo "Appcast is missing the DMG signature." >&2
    exit 1
fi
"$SPARKLE_ROOT/bin/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" --verify "$DMG" "$ARCHIVE_SIGNATURE"

if ! git -C "$ROOT" rev-parse "$TAG^{commit}" >/dev/null 2>&1; then
    git -C "$ROOT" tag -a "$TAG" -m "Battery Hog $VERSION"
fi
if [ "$(git -C "$ROOT" rev-parse "$TAG^{commit}")" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then
    echo "$TAG does not point at the current main commit." >&2
    exit 1
fi

git -C "$ROOT" push origin "$TAG"

NOTES_ARGS=(--generate-notes)
if [ -n "${NOTES_FILE:-}" ]; then
    NOTES_ARGS=(--notes-file "$NOTES_FILE")
fi

gh release create "$TAG" \
    --repo luke-fairbanks/BatteryHog \
    --verify-tag \
    --draft \
    --title "Battery Hog $VERSION" \
    "${NOTES_ARGS[@]}" \
    "$DMG" \
    "$APPCAST"

echo
echo "Draft staged. Review both install paths, then publish with:"
echo "  gh release edit $TAG --repo luke-fairbanks/BatteryHog --draft=false --latest"
echo "  bash src/stage_homebrew_cask.sh"
