#!/bin/bash
# Build a polished Finder-style DMG around an already assembled .app bundle.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 /path/to/App.app /path/to/output.dmg [volume name]" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$1"
DMG="$2"
VOLUME_NAME="${3:-Battery Hog Installer}"
APP_NAME="$(basename "$APP")"
DIST="$(dirname "$DMG")"
RW_DMG="$DIST/.${APP_NAME%.app}-installer-rw.dmg"
MOUNT_DIR=""
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        if hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force -quiet >/dev/null 2>&1; then
            DEVICE=""
        else
            echo "Warning: could not detach $DEVICE; preserving $RW_DMG" >&2
            return
        fi
    fi
    rm -f "$RW_DMG"
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
    echo "App bundle not found: $APP" >&2
    exit 66
fi

mkdir -p "$DIST"
rm -f "$DMG" "$RW_DMG"

APP_SIZE_KB="$(du -sk "$APP" | awk '{print $1}')"
IMAGE_SIZE_MB="$(( (APP_SIZE_KB + 1023) / 1024 + 32 ))"
if [ "$IMAGE_SIZE_MB" -lt 64 ]; then
    IMAGE_SIZE_MB=64
fi

# A writable image is required because Finder stores the icon positions,
# window geometry, and background choice in the volume's .DS_Store.
hdiutil create \
    -size "${IMAGE_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -type UDIF \
    -nospotlight \
    -ov "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$3 ~ /^\// {print $3; exit}')"
if [ -z "$DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
    echo "Could not determine the mounted DMG device or volume path" >&2
    exit 1
fi
FINDER_DISK_NAME="$(basename "$MOUNT_DIR")"

ditto "$APP" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
swift "$SCRIPT_DIR/make_dmg_background.swift" "$MOUNT_DIR/.background/background.png" >/dev/null

SetFile -a V "$MOUNT_DIR/.background"

# Finder owns .DS_Store. This is intentionally strict: a release should fail
# instead of silently shipping a plain, unconfigured disk image.
osascript - "$FINDER_DISK_NAME" "$APP_NAME" <<'APPLESCRIPT'
on run arguments
    set volumeName to item 1 of arguments
    set applicationName to item 2 of arguments

    tell application "Finder"
        tell disk volumeName
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set bounds of container window to {140, 120, 820, 572}

            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to true
            set background picture of viewOptions to file ".background:background.png"

            set position of item applicationName of container window to {170, 236}
            set position of item "Applications" of container window to {510, 236}

            update without registering applications
            delay 2
            close container window
            delay 1
        end tell
    end tell
end run
APPLESCRIPT

for _ in $(seq 1 40); do
    [ -s "$MOUNT_DIR/.DS_Store" ] && break
    sleep 0.25
done
if [ ! -s "$MOUNT_DIR/.DS_Store" ]; then
    echo "Finder did not write the installer layout (.DS_Store)" >&2
    exit 1
fi

# Finder's update command removes a pre-existing .VolumeIcon.icns, so install
# the volume icon only after Finder has finished writing the window metadata.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_DIR"
fi

rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes"
sync
for delay in 1 1 2 3; do
    if hdiutil detach "$DEVICE" -quiet; then
        DEVICE=""
        break
    fi
    sleep "$delay"
done
if [ -n "$DEVICE" ]; then
    echo "Could not detach the writable installer volume" >&2
    exit 1
fi

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG" >/dev/null

# On newer macOS releases hdiutil can return while the UDZO trailer is still
# being finalized. Do not hand back a transient 512-byte image or fail a good
# build on the first "resource temporarily unavailable" verification attempt.
DMG_VERIFIED=0
for _ in $(seq 1 80); do
    if hdiutil verify "$DMG" >/dev/null 2>&1; then
        DMG_VERIFIED=1
        break
    fi
    sleep 0.25
done
if [ "$DMG_VERIFIED" != "1" ]; then
    echo "Compressed installer image did not become verifiable: $DMG" >&2
    hdiutil verify "$DMG" >&2 || true
    exit 1
fi

echo "==> Styled DMG: $DMG"
