#!/usr/bin/env bash
# Cut a release: build + zip the .app, tag the commit, and publish a GitHub
# (pre-)release with auto-generated notes.
#
# Usage:
#   scripts/release.sh 0.2.0           # beta pre-release (default while < 1.0)
#   scripts/release.sh 1.0.0 --stable  # mark as a full (non-pre) release
#
# Requires: gh CLI (authenticated) + a clean working tree.
#
# Distribution note: this signs with whatever SIGN_IDENTITY build-app.sh picks
# up (ad-hoc by default). Once you have a Developer ID Application cert, export
# SIGN_IDENTITY and add a notarization step (notarytool submit --wait + stapler
# staple) after the zip is built, before `gh release create`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
PRERELEASE=1
for arg in "${@:2}"; do
    case "$arg" in
        --stable) PRERELEASE=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [--stable]   e.g. $0 0.2.0" >&2
    exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2
    exit 2
fi

TAG="v$VERSION"

# --- preflight ----------------------------------------------------------
command -v gh >/dev/null || { echo "ERROR: gh CLI not found (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run: gh auth login)" >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty — commit or stash first" >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag $TAG already exists" >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "WARNING: releasing from '$BRANCH', not 'main'." >&2
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
fi

# --- build --------------------------------------------------------------
# Pin the marketing version so the artifact matches the tag we're about to
# create, regardless of older tags in the history.
echo "==> building release $VERSION"
MARKETING_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release

APP="$ROOT/.build/SerialNotes.app"
ZIP="$ROOT/.build/SerialNotes-$VERSION.zip"
echo "==> zipping $ZIP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# --- publish (only after a successful build) ----------------------------
echo "==> tagging $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

TITLE="$TAG"
RELEASE_ARGS=(--title "$TITLE" --generate-notes "$ZIP")
if [[ "$PRERELEASE" -eq 1 ]]; then
    TITLE="$TAG (beta)"
    RELEASE_ARGS=(--title "$TITLE" --generate-notes --prerelease "$ZIP")
fi

echo "==> creating GitHub release"
gh release create "$TAG" "${RELEASE_ARGS[@]}"

echo "==> done: $(gh release view "$TAG" --json url -q .url)"
