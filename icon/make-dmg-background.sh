#!/usr/bin/env bash
# Regenerate the drag-to-Applications DMG window background.
#
# The artwork is drawn with AppKit (CoreText) rather than rasterized from an SVG:
# QuickLook's SVG thumbnailer silently drops <text>, so the headline never
# rendered. The Swift renderer below is the single source of truth for the layout.
# Output: a multi-representation icon/DMGBackground.tiff carrying both @1x (640×400)
# and @2x (1280×800) pixels, so the DMG window is crisp on Retina. make-dmg.sh
# copies the committed .tiff into the disk image.
#
# Run this only when the artwork changes; the committed .tiff is what ships. Uses
# only built-in tools (swift, sips, tiffutil) — no extra deps.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_TIFF="$ROOT/icon/DMGBackground.tiff"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RENDERER="$WORK/render.swift"
cat > "$RENDERER" <<'SWIFT'
import AppKit
import CoreText

// Backdrop for the drag-to-Applications DMG window (see scripts/make-dmg.sh).
// 640×400 = the DMG window's content size. Finder draws the app icon (centered at
// 160,190) and the Applications alias (centered at 480,190) ON TOP of this image,
// so the icon zones are left clear. On-brand with the site: white paper, near-black
// ink, the site's Geist caption, and an SF Symbol arrow toward Applications.
//
// argv[1] = output PNG. argv[2] (optional) = a Geist .ttf to register + use for the
// caption; if absent/unregisterable, the caption falls back to the system font.
let W: CGFloat = 640, H: CGFloat = 400

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: render <out.png> [geist.ttf]\n".utf8)); exit(2)
}

// Brand caption font: Geist SemiBold (matches the marketing site) when its TTF is
// passed in, else the system semibold so the script still runs offline. Registered
// once — CTFontManagerRegisterFontsForURL fails on a second call for the same URL,
// which would silently knock later captions back to the system font.
let geistAvailable: Bool = {
    guard CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty else { return false }
    let url = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
    if CTFontManagerRegisterFontsForURL(url, .process, nil) { return true }
    FileHandle.standardError.write(Data("warning: could not load Geist — using system font\n".utf8))
    return false
}()
func captionFont(size: CGFloat) -> NSFont {
    if geistAvailable, let geist = NSFont(name: "Geist-SemiBold", size: size) {
        return geist
    }
    return .systemFont(ofSize: size, weight: .semibold)
}
let outPath = CommandLine.arguments[1]

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
// Draw in 640×400 point coords at 2× scale. Scaling the CTM (rather than tagging
// rep.size) keeps the PNG a plain 72-dpi 1280×800 image, which tiffutil's
// -cathidpicheck needs to pair cleanly with the 640×400 @1x version.
ctx.cgContext.scaleBy(x: 2, y: 2)

NSColor.white.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let ink = NSColor(srgbRed: 10/255, green: 10/255, blue: 10/255, alpha: 1)

// One familiar caption in the gap between the icons (Finder places the app at
// x≈160 and Applications at x≈480, both centered at y≈190). No headline — the
// drag-and-drop pattern speaks for itself.
let caption = NSAttributedString(string: "drag and drop", attributes: [
    .font: captionFont(size: 22),
    .foregroundColor: ink,
])
let capSize = caption.size()
caption.draw(at: NSPoint(x: (W - capSize.width) / 2, y: H - 116 - capSize.height))

// Arrow: Apple's own SF Symbol (functional iconography per DESIGN.md), rather
// than a hand-drawn head. Both icons sit at the same height, so a clean
// horizontal arrow points straight from the app to the Applications folder.
// Tinted to `ink` via a palette config; baked into the TIFF, so there's no
// runtime SF Symbols dependency.
let arrowCfg = NSImage.SymbolConfiguration(pointSize: 58, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
if let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "drag to Applications")?
    .withSymbolConfiguration(arrowCfg) {
    let s = arrow.size
    let cx: CGFloat = 320, cy: CGFloat = 206  // centered in the gap, just below the caption
    arrow.draw(
        in: NSRect(x: cx - s.width / 2, y: H - cy - s.height / 2, width: s.width, height: s.height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
} else {
    FileHandle.standardError.write(Data("warning: SF Symbol arrow.right unavailable\n".utf8))
}

// Second step, below the icons. The drag alone launches nothing — and a
// menu-bar-only app shows no window or Dock icon until opened — so without this
// line the install dead-ends at the drop. (Double-clicking the app in the DMG
// also works: it installs itself and relaunches; see MoveToApplications.swift.)
let hint = NSAttributedString(string: "then open it from your Applications folder", attributes: [
    .font: captionFont(size: 15),
    .foregroundColor: ink.withAlphaComponent(0.55),
])
let hintSize = hint.size()
hint.draw(at: NSPoint(x: (W - hintSize.width) / 2, y: H - 318 - hintSize.height))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { exit(1) }
SWIFT

# Fetch the site's brand font (Geist SemiBold) for the caption. Mirrors how
# site/src/pages/og.png.ts sources Geist from the Fontsource API — no committed
# binary. Only needed when regenerating this asset; the shipped TIFF is committed.
# Falls back to the system font (with a warning) if offline.
echo "==> fetching Geist (Fontsource)"
FONT_TTF="$WORK/geist-semibold.ttf"
if ! curl -fsSL "https://api.fontsource.org/v1/fonts/geist-sans/latin-600-normal.ttf" \
    -o "$FONT_TTF" 2>/dev/null; then
    echo "WARNING: could not fetch Geist — caption falls back to the system font" >&2
    FONT_TTF=""
fi

echo "==> rendering @2x (1280×800) via AppKit"
HI="$WORK/DMGBackground@2x.png"
swift "$RENDERER" "$HI" "$FONT_TTF"

echo "==> downscaling -> 640×400 @1x"
LO="$WORK/DMGBackground.png"
sips -z 400 640 "$HI" --out "$LO" >/dev/null

echo "==> tiffutil -> $OUT_TIFF"
# -cathidpicheck verifies the second image is exactly 2× the first, then writes a
# multi-rep TIFF flagging the larger one as the HiDPI representation.
tiffutil -cathidpicheck "$LO" "$HI" -out "$OUT_TIFF" >/dev/null

echo "==> done: $OUT_TIFF ($(du -h "$OUT_TIFF" | cut -f1))"
