#!/bin/bash
# Builds a signed Sparkle feed for the final, stapled DMG. The signing key stays
# in the user's login Keychain under SPARKLE_KEY_ACCOUNT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/version.sh"

SPARKLE_ROOT="$(bash "$SCRIPT_DIR/fetch_sparkle.sh")"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-com.lukefairbanks.batteryhog}"
FEED_URL="https://github.com/luke-fairbanks/BatteryHog/releases/latest/download/appcast.xml"
DIST="$ROOT/dist"
DMG="${1:-$DIST/BatteryHog-$VERSION.dmg}"
OUTPUT="$DIST/appcast.xml"
mkdir -p "$DIST"

if [ ! -f "$DMG" ]; then
    echo "Final DMG not found: $DMG" >&2
    exit 66
fi
if [ "$(basename "$DMG")" != "BatteryHog-$VERSION.dmg" ]; then
    echo "DMG name must match VERSION ($VERSION): $DMG" >&2
    exit 64
fi

PLIST_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$SCRIPT_DIR/Info.plist")"
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_ROOT/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
if [ "$PLIST_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]; then
    echo "Sparkle Keychain key does not match src/Info.plist SUPublicEDKey" >&2
    echo "Use the '$SPARKLE_KEY_ACCOUNT' key that signed this updater lineage." >&2
    exit 1
fi

WORK="$(mktemp -d "$DIST/.appcast.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cp "$DMG" "$WORK/$(basename "$DMG")"

# Preserve earlier feed entries when one exists. Only the initial updater
# release may legitimately receive a 404; network/server failures must not
# silently discard the update lineage.
PREVIOUS_FEED="$WORK/previous-appcast.xml"
if ! HTTP_STATUS="$(curl --location --silent --show-error \
    --output "$PREVIOUS_FEED" --write-out '%{http_code}' "$FEED_URL")"; then
    echo "Could not retrieve the previous Sparkle feed." >&2
    exit 1
fi
case "$HTTP_STATUS" in
    200)
        mv "$PREVIOUS_FEED" "$WORK/appcast.xml"
        ;;
    404)
        rm -f "$PREVIOUS_FEED"
        if [ "$VERSION" != "1.4.0" ]; then
            echo "The previous Sparkle feed is missing for update $VERSION." >&2
            exit 1
        fi
        echo "==> No previous appcast found; creating the initial feed"
        ;;
    *)
        echo "Could not retrieve the previous Sparkle feed (HTTP $HTTP_STATUS)." >&2
        exit 1
        ;;
esac

if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
    if [ ! -f "$RELEASE_NOTES_FILE" ]; then
        echo "Release notes file not found: $RELEASE_NOTES_FILE" >&2
        exit 66
    fi
    cp "$RELEASE_NOTES_FILE" "$WORK/BatteryHog-$VERSION.${RELEASE_NOTES_FILE##*.}"
fi

"$SPARKLE_ROOT/bin/generate_appcast" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --maximum-deltas 0 \
    --maximum-versions 0 \
    --versions "$VERSION" \
    --download-url-prefix \
      "https://github.com/luke-fairbanks/BatteryHog/releases/download/v$VERSION/" \
    --link "https://github.com/luke-fairbanks/BatteryHog/releases/tag/v$VERSION" \
    --embed-release-notes \
    -o "$WORK/appcast.xml" \
    "$WORK"

xmllint --noout "$WORK/appcast.xml"
"$SPARKLE_ROOT/bin/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" --verify "$WORK/appcast.xml"

ARCHIVE_SIGNATURE="$(xmllint --xpath \
    'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
    "$WORK/appcast.xml")"
if [ -z "$ARCHIVE_SIGNATURE" ]; then
    echo "Generated appcast is missing the DMG EdDSA signature" >&2
    exit 1
fi
"$SPARKLE_ROOT/bin/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" --verify "$DMG" "$ARCHIVE_SIGNATURE"
if ! grep -q 'sparkle-signatures:' "$WORK/appcast.xml"; then
    echo "Generated appcast is missing the signed-feed signature" >&2
    exit 1
fi

cp "$WORK/appcast.xml" "$OUTPUT"
echo "==> Signed appcast: $OUTPUT"
