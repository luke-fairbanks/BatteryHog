#!/bin/bash
# Updates the local Homebrew tap checkout from the canonical VERSION and the
# already-published DMG. It deliberately stops before commit/push for review.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/version.sh"

TAG="v$VERSION"
DMG="$ROOT/dist/BatteryHog-$VERSION.dmg"
TAP_REPO="${TAP_REPO:-$(brew --repository luke-fairbanks/tap)}"
CASK="$TAP_REPO/Casks/battery-hog.rb"

if [ ! -f "$DMG" ] || [ ! -f "$CASK" ]; then
    echo "Missing release DMG or Homebrew cask." >&2
    exit 66
fi
if [ -n "$(git -C "$TAP_REPO" status --porcelain)" ]; then
    echo "Refusing to edit a dirty Homebrew tap checkout: $TAP_REPO" >&2
    exit 1
fi
if [ "$(gh release view "$TAG" --repo luke-fairbanks/BatteryHog --json isDraft \
    --jq '.isDraft')" != "false" ]; then
    echo "$TAG must be public before its Homebrew cask is staged." >&2
    exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
gh release download "$TAG" --repo luke-fairbanks/BatteryHog \
    --pattern "$(basename "$DMG")" --dir "$WORK"

LOCAL_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
PUBLIC_SHA="$(shasum -a 256 "$WORK/$(basename "$DMG")" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$PUBLIC_SHA" ]; then
    echo "Published DMG does not match the locally reviewed release artifact." >&2
    exit 1
fi

VERSION="$VERSION" SHA256="$LOCAL_SHA" perl -0pi -e '
    s/version "[^"]+"/version "$ENV{VERSION}"/;
    s/sha256 "[0-9a-f]+"/sha256 "$ENV{SHA256}"/;
' "$CASK"

grep -Fq "version \"$VERSION\"" "$CASK"
grep -Fq "sha256 \"$LOCAL_SHA\"" "$CASK"
brew style "$CASK"
git -C "$TAP_REPO" diff --check

echo
git -C "$TAP_REPO" diff -- "$CASK"
echo
echo "Homebrew cask staged for review. When approved:"
echo "  git -C '$TAP_REPO' add '$CASK'"
echo "  git -C '$TAP_REPO' commit -m 'Update Battery Hog to $VERSION'"
echo "  git -C '$TAP_REPO' push origin main"
