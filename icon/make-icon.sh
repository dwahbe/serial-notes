#!/usr/bin/env bash
# Regenerate the app icon from icon/AppIcon.svg.
#
# Pipeline: SVG --(qlmanage)--> 1024px PNG master --(sips)--> .iconset of all
# required sizes --(iconutil)--> Sources/SerialNotes/AppIcon.icns, which
# build-app.sh copies into SerialNotes.app/Contents/Resources/ at wrap time.
#
# Run this only when the artwork changes; the committed .icns is what ships.
# Uses only built-in macOS tools (qlmanage, sips, iconutil) — no extra deps.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/icon/AppIcon.svg"
OUT_ICNS="$ROOT/Sources/SerialNotes/AppIcon.icns"

if [[ ! -f "$SVG" ]]; then
    echo "ERROR: source not found at $SVG" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> rasterizing $SVG -> 1024px master"
# qlmanage renders SVG via WebKit (honors gradients + drop shadow + alpha),
# unlike sips which rasterizes at the SVG's intrinsic size. It writes
# "<name>.png" into the output dir.
qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/AppIcon.svg.png"
if [[ ! -f "$MASTER" ]]; then
    echo "ERROR: qlmanage did not produce $MASTER" >&2
    exit 1
fi

echo "==> building .iconset"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
# name:size pairs required by iconutil for a complete macOS icon.
for entry in \
    "icon_16x16.png:16" \
    "icon_16x16@2x.png:32" \
    "icon_32x32.png:32" \
    "icon_32x32@2x.png:64" \
    "icon_128x128.png:128" \
    "icon_128x128@2x.png:256" \
    "icon_256x256.png:256" \
    "icon_256x256@2x.png:512" \
    "icon_512x512.png:512" \
    "icon_512x512@2x.png:1024"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

echo "==> iconutil -> $OUT_ICNS"
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo "==> done: $OUT_ICNS ($(du -h "$OUT_ICNS" | cut -f1))"
