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

# SwiftPM resource bundles (e.g. KeyboardShortcuts' localizations). Bundle.module
# fatalErrors at runtime if a package's bundle is missing from Contents/Resources,
# so copy every generated *.bundle. Resource-only bundles carry no code and are
# sealed by the outer app signature; a bundle that ever gains an executable would
# need its own inside-out codesign step like Sparkle below.
for RESOURCE_BUNDLE in "$ROOT/.build/$CONFIG"/*.bundle; do
    [[ -d "$RESOURCE_BUNDLE" ]] || continue
    echo "==> bundling $(basename "$RESOURCE_BUNDLE")"
    ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
done

# App icon (CFBundleIconFile=AppIcon in Info.plist). Regenerate the .icns from
# the brand mark with ./icon/make-icon.sh. Warn rather than fail if it's
# missing so a checkout without the prebuilt icon still produces a runnable app.
APP_ICON="$SRC_DIR/AppIcon.icns"
if [[ -f "$APP_ICON" ]]; then
    cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "WARNING: $APP_ICON missing — app will use the generic icon (run ./icon/make-icon.sh)" >&2
fi

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

# --- Dev flavor: give ad-hoc local builds a distinct identity ----------------
# A downloaded production build and a local run.sh build would otherwise share
# the same bundle ID — and therefore the same TCC permissions and UserDefaults
# domain — and macOS won't run two same-ID apps at once. Ad-hoc (dev) builds get
# `.dev` appended so they install side-by-side with production, fully isolated;
# the app tags itself "DEV" in the menu bar. Release/CI builds (a real Developer
# ID) keep the production identity. Keyed off the same signal as the timestamp /
# signing branch below.
if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
    BUNDLE_ID="$BUNDLE_ID.dev"
    echo "==> dev flavor: $BUNDLE_ID"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Serial Notes (Dev)" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Serial Notes (Dev)" "$PLIST"
    # Don't let the local build try to Sparkle-update itself to production.
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$PLIST"
fi

# Write PkgInfo so LaunchServices treats this as a proper app.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# --- Embed Sparkle.framework -------------------------------------------------
# The SwiftPM binary loads @rpath/Sparkle.framework/Versions/B/Sparkle, but the
# only rpath `swift build` bakes in is @loader_path. So copy the framework into
# Contents/Frameworks and add the @executable_path/../Frameworks rpath, or the
# app can't find Sparkle at launch. `ditto` preserves the framework's symlinks
# and the executable bits its helper tools need.
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SPARKLE_SRC="$(/usr/bin/find "$ROOT/.build/artifacts" -type d -path "*/Sparkle.xcframework/macos-*/Sparkle.framework" 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_SRC" ]]; then
    echo "ERROR: Sparkle.framework not found under .build/artifacts (did 'swift build' resolve Sparkle?)" >&2
    exit 1
fi
echo "==> embedding Sparkle.framework"
mkdir -p "$FRAMEWORKS_DIR"
ditto "$SPARKLE_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if ! otool -l "$APP_BIN" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN"
fi

# Sign with entitlements so TCC + notifications behave like a real app.
# Defaults to ad-hoc ("-"). To produce a distributable, notarizable build,
# export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" before
# running.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Two flags differ between dev and release signing:
#   * Timestamp — a real Developer ID signature needs a secure (RFC-3161)
#     timestamp from Apple's TSA; notarization rejects signatures without one.
#     Ad-hoc builds skip it (a network round-trip we don't want in the run.sh
#     hot loop, and ad-hoc can't be notarized anyway).
#   * Hardened runtime — required for notarization, so release builds get it.
#     Ad-hoc dev builds DON'T: hardened runtime enforces library validation,
#     which requires every loaded library to share the main binary's Team ID.
#     Ad-hoc signatures carry no Team ID, so an ad-hoc app loading the ad-hoc
#     Sparkle.framework gets killed by dyld at launch ("Team IDs differ").
#     The release is safe because it signs the app AND the framework with the
#     same Developer ID. $RUNTIME_FLAG is intentionally UNQUOTED at the codesign
#     sites so it expands to two args (--options runtime) or to nothing.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> codesign (ad-hoc, no hardened runtime)"
    TIMESTAMP_FLAG="--timestamp=none"
    RUNTIME_FLAG=""
else
    echo "==> codesign ($SIGN_IDENTITY)"
    TIMESTAMP_FLAG="--timestamp"
    RUNTIME_FLAG="--options runtime"
fi

# Sign Sparkle inside-out: the nested helpers (XPC services, Updater.app,
# Autoupdate) first, then the framework bundle, then the app last. Each helper
# signs clean — they ship with only empty / Sparkle-owned entitlements we don't
# need for Developer ID distribution, and a stray entitlement only risks
# notarization. The framework is sealed after its helpers so their signatures
# are recorded in its CodeResources.
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
# Sparkle ships its code under a versioned dir (Versions/B across all of 2.x).
# Read Versions/Current rather than hardcoding "B" so a future framework layout
# change can't silently skip signing a helper and fail notarization.
SPARKLE_VER="$(readlink "$SPARKLE_FW/Versions/Current" 2>/dev/null || echo B)"
for component in \
    "Versions/$SPARKLE_VER/XPCServices/Downloader.xpc" \
    "Versions/$SPARKLE_VER/XPCServices/Installer.xpc" \
    "Versions/$SPARKLE_VER/Updater.app" \
    "Versions/$SPARKLE_VER/Autoupdate"; do
    codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAG "$TIMESTAMP_FLAG" \
        "$SPARKLE_FW/$component" >/dev/null
done
codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAG "$TIMESTAMP_FLAG" \
    "$SPARKLE_FW" >/dev/null

# Finally the app itself (with entitlements), now that the framework it
# references is signed.
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    $RUNTIME_FLAG \
    "$TIMESTAMP_FLAG" \
    "$APP_BUNDLE" >/dev/null

# Register with LaunchServices so the bundle ID resolves immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> built $APP_BUNDLE"
echo "    bundle id: $BUNDLE_ID"
