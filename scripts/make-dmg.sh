#!/usr/bin/env bash
# Build a styled, drag-to-Applications DMG from a built .app.
#
# Usage: scripts/make-dmg.sh <App.app> <output.dmg> [volume-name]
#
# Produces a compressed read-only DMG whose window shows the app on the left, an
# Applications-folder alias on the right, and a background that guides the drag
# (icon/DMGBackground.tiff). Uses only built-in tools — hdiutil for the image and
# Finder (via osascript) for the window layout. No third-party deps.
#
# The Finder styling is best-effort: if Apple-Events automation is unavailable
# (e.g. a locked-down CI session) the script still emits a working DMG that
# contains the app + the Applications symlink, just without the custom window.

set -euo pipefail

APP="${1:-}"
OUT="${2:-}"
VOLNAME="${3:-Serial Notes}"

if [[ -z "$APP" || -z "$OUT" ]]; then
    echo "usage: $0 <App.app> <output.dmg> [volume-name]" >&2
    exit 2
fi
if [[ ! -d "$APP" ]]; then
    echo "ERROR: app bundle not found at $APP" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKGROUND="$ROOT/icon/DMGBackground.tiff"
APP_NAME="$(basename "$APP")"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
TMP_DMG="$WORK/rw.dmg"
mkdir -p "$STAGE"
cleanup() {
    # Detach any lingering mount from a failed run before discarding the workdir.
    [[ -n "${DEVICE:-}" ]] && hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> staging $APP_NAME"
# ditto preserves the bundle's signature, symlinks, and executable bits.
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
if [[ -f "$BACKGROUND" ]]; then
    mkdir -p "$STAGE/.background"
    cp "$BACKGROUND" "$STAGE/.background/background.tiff"
else
    echo "WARNING: $BACKGROUND missing — DMG will have no custom background (run ./icon/make-dmg-background.sh)" >&2
fi

echo "==> creating writable image"
# Size the image to the staged content plus slack for the .DS_Store Finder writes.
STAGE_KB="$(du -sk "$STAGE" | awk '{print $1}')"
SIZE_MB="$(( STAGE_KB / 1024 + 50 ))"
rm -f "$TMP_DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_MB}m" \
    -ov "$TMP_DMG" >/dev/null

echo "==> mounting"
# Parse the attached device node so detach is exact even if the volume name clashes.
DEVICE="$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen \
    | grep -E '^/dev/' | grep 'Apple_HFS' | awk '{print $1}' | head -1)"
if [[ -z "$DEVICE" ]]; then
    echo "ERROR: could not mount $TMP_DMG" >&2
    exit 1
fi
# Give the volume a moment to settle before Finder pokes at it.
sleep 2

echo "==> styling window (best-effort)"
APPLESCRIPT="$WORK/style.applescript"
cat > "$APPLESCRIPT" <<'APPLESCRIPT_EOF'
on run argv
    set volName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        -- Bound every Apple Event so a wedged Finder (possible on a headless CI
        -- session) raises a timeout the caller can treat as "styling failed"
        -- rather than hanging the whole release.
        with timeout of 60 seconds
            tell disk volName
                open
                set theWindow to container window
                set current view of theWindow to icon view
                set toolbar visible of theWindow to false
                set statusbar visible of theWindow to false
                -- 640×400 content area to match DMGBackground.tiff (+~23px title bar).
                set the bounds of theWindow to {200, 120, 840, 543}
                set opts to the icon view options of theWindow
                set arrangement of opts to not arranged
                set icon size of opts to 120
                set text size of opts to 12
                set background picture of opts to file ".background:background.tiff"
                set position of item appName of theWindow to {160, 190}
                set position of item "Applications" of theWindow to {480, 190}
                update without registering applications
                delay 1
                close
            end tell
        end timeout
    end tell
end run
APPLESCRIPT_EOF
if ! osascript "$APPLESCRIPT" "$VOLNAME" "$APP_NAME" >/dev/null 2>&1; then
    echo "WARNING: Finder styling failed (no automation access?) — shipping an unstyled DMG" >&2
fi

# Make Finder flush the .DS_Store that records the window layout + icon positions.
sync

echo "==> detaching"
# Retry: Finder/Spotlight can briefly hold the volume right after styling.
for attempt in 1 2 3 4 5; do
    if hdiutil detach "$DEVICE" >/dev/null 2>&1; then DEVICE=""; break; fi
    sleep "$attempt"
done
[[ -z "$DEVICE" ]] || { echo "ERROR: could not detach $DEVICE" >&2; exit 1; }

echo "==> compressing -> $OUT"
rm -f "$OUT"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "==> built $OUT ($(du -h "$OUT" | cut -f1))"
