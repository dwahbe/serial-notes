// Regenerate src/og-logo.png — the brand lockup composited onto the social
// card by src/pages/og.png.ts. White mark (public/favicon.svg geometry, no
// background tile since the card bg is the same ink) + "Serial Notes" in
// Geist SemiBold, mirroring the site header (src/components/Logo.astro), on
// a transparent canvas. Drawn with canvaskit-wasm (already a dependency via
// astro-og-canvas); the font comes from the same Fontsource API the card
// build pulls from. Run from site/: `bun scripts/make-og-logo.mjs`.
import { writeFile } from "node:fs/promises";
import path from "node:path";
import CanvasKitInit from "canvaskit-wasm";

const ROOT = path.join(import.meta.dirname, "..");
const OUT = path.join(ROOT, "src/og-logo.png");
const FONT_URL = "https://api.fontsource.org/v1/fonts/geist-sans/latin-600-normal.ttf";

// Everything is drawn at 3× the size the card displays the lockup at, so the
// downscale in astro-og-canvas stays crisp. Mark geometry = favicon.svg's
// 32-unit viewBox × SCALE.
const SCALE = 6;
const MARK_BOX = 32 * SCALE;
const FONT_SIZE = 160;
const TRACKING = -0.025 * FONT_SIZE; // Tailwind tracking-tight, like the header
const GAP = 30; // mark box → wordmark (the box already pads the circle)

const CanvasKit = await CanvasKitInit({
  locateFile: (file) => path.join(ROOT, "node_modules/canvaskit-wasm/bin", file),
});

const fontData = await (await fetch(FONT_URL)).arrayBuffer();
const fontMgr = CanvasKit.FontMgr.FromData(fontData);
if (!fontMgr) throw new Error("could not load Geist font data");

const paragraphStyle = new CanvasKit.ParagraphStyle({
  textAlign: CanvasKit.TextAlign.Left,
  textStyle: {
    color: CanvasKit.WHITE,
    fontFamilies: [fontMgr.getFamilyName(0)],
    fontSize: FONT_SIZE,
    letterSpacing: TRACKING,
  },
});
const builder = CanvasKit.ParagraphBuilder.Make(paragraphStyle, fontMgr);
builder.addText("Serial Notes");
const para = builder.build();
para.layout(MARK_BOX * 20);

const width = Math.ceil(MARK_BOX + GAP + para.getLongestLine() + 4);
const height = MARK_BOX;
const surface = CanvasKit.MakeSurface(width, height);
const canvas = surface.getCanvas();
canvas.clear(CanvasKit.TRANSPARENT);

const stroke = new CanvasKit.Paint();
stroke.setColor(CanvasKit.WHITE);
stroke.setAntiAlias(true);
stroke.setStyle(CanvasKit.PaintStyle.Stroke);

// Circle + waveform, verbatim from favicon.svg coordinates.
stroke.setStrokeWidth(2 * SCALE);
canvas.drawCircle(16 * SCALE, 16 * SCALE, 12 * SCALE, stroke);
stroke.setStrokeWidth(1.6 * SCALE);
stroke.setStrokeCap(CanvasKit.StrokeCap.Round);
for (const [x, y1, y2] of [
  [9.5, 13.75, 18.25],
  [12.1, 12, 20],
  [14.7, 10.75, 21.25],
  [17.3, 13.5, 18.5],
  [19.9, 12, 20],
  [22.5, 14.5, 17.5],
]) {
  canvas.drawLine(x * SCALE, y1 * SCALE, x * SCALE, y2 * SCALE, stroke);
}

// Optically center the wordmark on the circle: put the cap-height midline
// (cap ≈ 0.72 em) on the circle's center line.
const baseline = 16 * SCALE + (0.72 * FONT_SIZE) / 2;
const top = baseline - para.getLineMetrics()[0].ascent;
canvas.drawParagraph(para, MARK_BOX + GAP, top);

const image = surface.makeImageSnapshot();
const png = image.encodeToBytes(CanvasKit.ImageFormat.PNG, 100);
surface.dispose();
await writeFile(OUT, png);
console.log(`wrote ${OUT} (${width}x${height}, display at 1/3: ${Math.round(width / 3)}x${Math.round(height / 3)})`);
