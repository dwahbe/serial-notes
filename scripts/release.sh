#!/usr/bin/env bash
# Cut a release by tagging + pushing. GitHub Actions does the heavy lifting
# (build → Developer ID sign → notarize → staple → GitHub Release → appcast
# update) — see .github/workflows/release.yml. This script just validates the
# tree and creates the tag so you're not hand-typing `git tag`.
#
# Usage:
#   scripts/release.sh 0.2.0
#
# Versioning: SemVer. Major version 0 stays "beta" — but beta builds ship as
# FULL GitHub releases, not pre-releases, so /releases/latest and the site
# download link resolve. CI just titles them "vX.Y.Z (beta)"; the "(beta)"
# signal is derived from the 0 major (the in-app About row). Bump to 1.0.0 to
# leave beta.
#
# The pushed tag triggers the workflow; watch it with: gh run watch

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 <version>   e.g. $0 0.2.0" >&2
    exit 2
fi
TAG="v$VERSION"

# --- preflight ----------------------------------------------------------
# This script is git-only (tag + push); CI does all the gh-based publishing,
# so there's no gh requirement here.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty — commit or stash first" >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag $TAG already exists" >&2
    exit 1
fi
# The Sparkle build number is the commit count (see build-app.sh), and Sparkle
# decides upgrades by it. A tag on the SAME commit as the last release would
# carry an identical build number, so installed users would never be offered
# the update — refuse it.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]] && [[ "$(git rev-list -n1 "$LAST_TAG")" == "$(git rev-parse HEAD)" ]]; then
    echo "ERROR: HEAD is the same commit as $LAST_TAG — the build number wouldn't" >&2
    echo "       increase, so Sparkle wouldn't offer this update. Commit a change first." >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "WARNING: releasing from '$BRANCH', not 'main'." >&2
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
fi

# Smoke-check that the tree compiles before we publish a tag. CI does the full
# signed/notarized build, but catching a broken build here avoids a public tag
# that produces no release (after which the "tag exists" guard blocks a clean
# retry until you delete the tag).
echo "==> compile check (swift build)"
swift build >/dev/null

# --- tag + push ---------------------------------------------------------
# Push the branch first so the tagged commit exists on the remote for CI.
echo "==> pushing $BRANCH"
git push origin "$BRANCH"

echo "==> tagging $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> pushed $TAG — GitHub Actions will build, notarize, and publish."
echo "    watch:  gh run watch"
echo "    or:     gh run list --workflow=release.yml"
