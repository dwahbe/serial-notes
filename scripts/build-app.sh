#!/usr/bin/env bash
# Build the SwiftPM binary and wrap it into SerialNotes.app so that
# LaunchServices-gated APIs (UNUserNotificationCenter, Login Items, etc.) work.
#
# Output: <repo>/.build/SerialNotes.app

set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "usage: $0 [debug|release]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SerialNotes"
BUNDLE_ID="com.serialnotes.app"
SRC_DIR="$ROOT/Sources/$APP_NAME"
INFO_PLIST="$SRC_DIR/Info.plist"
ENTITLEMENTS="$SRC_DIR/SerialNotes.entitlements"
OUT_DIR="$ROOT/.build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> swift build ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "ERROR: binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# --- Stamp the version into the bundled Info.plist (before signing) ------
# Single source of truth is the latest git tag (vX.Y.Z -> X.Y.Z). The build
# number is the commit count, which is monotonic across the history. An
# explicit MARKETING_VERSION env var wins (release.sh sets it so the tag and
# the artifact stay in lock-step). Falls back to whatever Info.plist already
# carries when not in a git checkout / no tags exist yet.
PLIST="$APP_BUNDLE/Contents/Info.plist"
GIT_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
SHORT_VERSION="${MARKETING_VERSION:-${GIT_TAG#v}}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"

if [[ -n "$SHORT_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$PLIST"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi
echo "==> version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"

# Write PkgInfo so LaunchServices treats this as a proper app.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Sign with entitlements so TCC + notifications behave like a real app.
# Defaults to ad-hoc ("-"). To produce a distributable, notarizable build,
# export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" before
# running. The hardened runtime (--options runtime) is already on, which
# notarization requires.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> codesign (ad-hoc)"
else
    echo "==> codesign ($SIGN_IDENTITY)"
fi
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    "$APP_BUNDLE" >/dev/null

# Register with LaunchServices so the bundle ID resolves immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> built $APP_BUNDLE"
echo "    bundle id: $BUNDLE_ID"
