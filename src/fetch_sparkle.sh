#!/bin/bash
# Fetches the pinned Sparkle binary distribution into an ignored build cache.
# Prints the extracted distribution path for use by other scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
CACHE_ROOT="${SPARKLE_CACHE_DIR:-$ROOT/.build/sparkle/$SPARKLE_VERSION}"
DIST_ROOT="$CACHE_ROOT/distribution"
ARCHIVE="$CACHE_ROOT/Sparkle-$SPARKLE_VERSION.tar.xz"

mkdir -p "$CACHE_ROOT"
WORK="$(mktemp -d "$CACHE_ROOT/.fetch.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ARCHIVE_VALID=0
if [ -f "$ARCHIVE" ]; then
    ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    if [ "$ACTUAL_SHA" = "$SPARKLE_SHA256" ]; then
        ARCHIVE_VALID=1
    else
        echo "Cached Sparkle archive checksum mismatch; downloading a clean copy." >&2
        rm -f "$ARCHIVE"
    fi
fi

if [ "$ARCHIVE_VALID" != "1" ]; then
    DOWNLOAD="$WORK/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "==> Fetching Sparkle $SPARKLE_VERSION" >&2
    curl --fail --location --silent --show-error "$SPARKLE_URL" --output "$DOWNLOAD"

    ACTUAL_SHA="$(shasum -a 256 "$DOWNLOAD" | awk '{print $1}')"
    if [ "$ACTUAL_SHA" != "$SPARKLE_SHA256" ]; then
        echo "Sparkle checksum mismatch" >&2
        echo "  expected: $SPARKLE_SHA256" >&2
        echo "  actual:   $ACTUAL_SHA" >&2
        exit 1
    fi
    mv "$DOWNLOAD" "$ARCHIVE"
fi

# Never trust a previously extracted framework: reconstruct it from the
# checksum-verified archive for every build or release invocation.
mkdir -p "$WORK/extracted"
tar -xJf "$ARCHIVE" -C "$WORK/extracted"
if [ ! -f "$WORK/extracted/Sparkle.framework/Versions/B/Sparkle" ] || \
   [ ! -x "$WORK/extracted/bin/sign_update" ]; then
    echo "Sparkle archive is missing required release tools." >&2
    exit 1
fi
rm -rf "$DIST_ROOT"
mv "$WORK/extracted" "$DIST_ROOT"

printf '%s\n' "$DIST_ROOT"
