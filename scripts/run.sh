#!/usr/bin/env bash
# Dev loop: kill any running SerialNotes, rebuild the .app, launch it.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SerialNotes"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"
# Absolute path to *this repo's* dev-build executable. We scope every kill to
# this path so we never terminate a downloaded production app: both ship the
# same executable name ("SerialNotes") and the same Contents/MacOS/SerialNotes
# suffix, and differ only by location + bundle ID (com.serialnotes.app.dev vs
# com.serialnotes.app). Matching the bare name or suffix would catch production
# too, defeating the .dev isolation that build-app.sh sets up for side-by-side runs.
DEV_APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> stopping existing $APP_NAME (dev build) instances"
# Kill every dev variant: wrapped .app, raw SwiftPM binary, and Xcode DerivedData
# builds — all anchored to this repo so a production install elsewhere survives.
# Also kill any attached lldb/debugserver so traced processes can actually exit.
pkill -9 -f "debugserver.*$APP_NAME" 2>/dev/null || true
pkill -9 -f "lldb-rpc-server" 2>/dev/null || true
pkill -f "$DEV_APP_BIN" 2>/dev/null || true                # our wrapped dev .app
pkill -f "$ROOT/\.build/$CONFIG/$APP_NAME" 2>/dev/null || true  # raw SwiftPM binary
pkill -f "DerivedData/.*/$APP_NAME" 2>/dev/null || true    # stray Xcode build

# Purge any stale Xcode DerivedData build so LaunchServices can't resolve our
# bundle ID to it. Using Run in Xcode recreates it — avoid that and use this script.
shopt -s nullglob
DERIVED_GLOB=(
    "$HOME"/Library/Developer/Xcode/DerivedData/serial-notes-*
    "$HOME"/Library/Developer/Xcode/DerivedData/distracted-ride-*
)
shopt -u nullglob
for d in ${DERIVED_GLOB[@]+"${DERIVED_GLOB[@]}"}; do
    if [ -d "$d" ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$d/Build/Products/Debug/" 2>/dev/null || true
        rm -rf "$d"
    fi
done

# Wait for our dev process to actually exit before rebuilding/launching.
# Match on the full dev-build path (pgrep -f), not the bare name (pgrep -x),
# so a running production app doesn't keep this loop spinning or get SIGKILLed.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f "$DEV_APP_BIN" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
if pgrep -f "$DEV_APP_BIN" >/dev/null 2>&1; then
    echo "    warning: dev $APP_NAME still running after SIGTERM, sending SIGKILL"
    pkill -9 -f "$DEV_APP_BIN" 2>/dev/null || true
    sleep 0.3
fi

"$ROOT/scripts/build-app.sh" "$CONFIG"

echo "==> launching $APP_BUNDLE"
open "$APP_BUNDLE"
