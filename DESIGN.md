# Design

_macOS app design below; the marketing site (`site/`) is documented at the end._

## Fundamentals

- Menu bar-only app — no Dock icon, no main window
- macOS 26+, Liquid Glass throughout
- Single `MenuBarExtra` popover (`.window` style), dark color scheme
- Two states: **idle** (controls + storage picker) and **recording** (timer + stop)

## Layout

- Popover width: 280pt
- Content padding: 20pt
- Vertical spacing: 16pt between sections
- State transitions (idle↔recording) resize the popover instantly — do **not**
  animate the root size. `MenuBarExtra(.window)` won't resize its NSWindow off an
  animated size change, which leaves a transparent dead zone + detached shadow
  when the shorter recording layout is shown. See `MenuBarView.body`.

## Liquid Glass Rules

- Wrap the entire popover in `GlassEffectContainer`
- `.glassProminent` for the single primary action per state
- `.glass` for secondary interactive elements
- Never apply glass to content (text, labels, status indicators)
- Never stack glass without a `GlassEffectContainer`
- Never mix `.regular` and `.clear` glass variants
- No custom tints — system defaults only

## Icons

- **Decorative / functional iconography:** monochrome SF Symbols only.
- **Brand mark** (the waveform-in-a-circle) is a *custom* glyph, **not** an SF Symbol —
  so it stays identical across the app, the app icon, and the website, and because
  Apple's SF Symbols license forbids using a system symbol as an app/brand logo. See
  **### Brand mark** below.
- Menu bar icon reflects state via the custom `BrandMark` (`BrandMark.swift`): **idle** is
  a monochrome **template** image (macOS tints it to the menu bar + inverts it when the
  menu opens); **recording** is the orange "live" variant — a filled orange disc
  (`Color.recordingLive`) with the waveform knocked in white. (Not the old SF Symbols
  `waveform.circle` / `record.circle`.)

### Brand mark

- One canonical glyph, drawn in a 32×32 space. **Single source of truth is the website
  favicon (`site/public/favicon.svg`)**; `BrandMark.swift` (app) and `icon/AppIcon.svg`
  (app icon) mirror its exact coordinates — keep them in lockstep.
  - Circle: center (16,16), r 12, stroke 2.0. Six thin bars: stroke 1.6, round caps,
    at x = 9.5 / 12.1 / 14.7 / 17.3 / 19.9 / 22.5, with a dynamic rhythm that decays to
    a tiny bar at the right end (SF-waveform-inspired — thin, elegant, generous padding
    to the ring). `Logo.astro` is the same glyph at 0.5×.
- The glyph is shared; only the *chrome* changes per use case:

  | Surface | Chrome |
  |---|---|
  | Menu bar (idle) | bare glyph, monochrome template |
  | Menu bar (recording) | filled orange disc (`Color.recordingLive`) + white bars |
  | Popover header | bare glyph, `.primary` |
  | Meeting-detected banner | filled black disc + white bars |
  | App icon | glyph on a full-bleed near-black tile (gradient; macOS rounds + shadows) |
  | Favicon | glyph on a `#0a0a0a` rounded tile |
  | OG card | white glyph, tile-less, on the dark card background |

- Website rasters (`favicon.ico`, `og-logo.png`) derive from the canonical glyph and only
  need regenerating if the glyph itself changes.

### App icon

- The brand mark (see above) — a white waveform-in-a-circle — on a near-black tile
  (`#0a0a0a`). Reuses the canonical favicon glyph coordinates verbatim.
- Source: `icon/AppIcon.svg` (1024×1024). **Full-bleed** for macOS 26 (Tahoe): the
  near-black tile (subtle `#1c1c1e → #0a0a0a` top-to-bottom gradient) fills the whole
  canvas with **no margin and no baked drop shadow** — macOS composites every app icon
  into its own rounded tile and adds the shadow, so the previous floated-squircle
  master left a transparent margin that the system tile filled with white (a stray
  border around the mark). The SVG keeps a light `rx≈180` (≈17.6%, deliberately tighter
  than Apple's ~22% mask) purely as a fallback shape: under the system mask our squarer
  corners sit fully covered (no white gap); if the OS ever doesn't mask, the icon still
  reads as rounded rather than a sharp square. (Menu bar-only app, so it appears in
  Finder, Spotlight, and the About box rather than the Dock.)
- The full-bleed master is also the right starting point if we later adopt Apple's
  **Icon Composer** (`.icon` / Liquid Glass) — the layers are already edge-to-edge.
- Regenerate the `.icns` with `./icon/make-icon.sh` (built-in tools only:
  `qlmanage` → `sips` → `iconutil`). It writes `Sources/SerialNotes/AppIcon.icns`,
  which `build-app.sh` copies into the bundle (`CFBundleIconFile = AppIcon`).

## Typography & Hierarchy

- System fonts; `.monospaced` design for time/numeric displays
- `.numericText()` content transition for changing numbers
- `.primary` for interactive elements and key info
- `.secondary` for labels and supporting icons
- `.tertiary` for disclosure indicators and hints
- Errors: `.red` foreground, `.caption` font, 2-line max

## System Panels

- Use `NSOpenPanel` for file operations
- Surface panels the menu-bar way — `NSApp.activate()` + `orderFrontRegardless()`; the app stays `.accessory` for its whole lifetime, never flipping to `.regular` (see CLAUDE.md → App shell → Activation policy)

---

# Marketing site (`site/`)

The landing page is a separate Astro + Tailwind v4 project (build/deploy details
live in the "Marketing site" section of `CLAUDE.md`). The look is deliberately
**Vercel-inspired**: pure-white paper, near-black ink, hairline grays, and a
faint technical-drawing grid. All site-wide tokens live in
`site/src/styles/global.css` (`@theme`).

## What we design with

- **Astro 6** components (`.astro`) — plain HTML, no UI framework.
- **Tailwind CSS v4** via `@tailwindcss/vite`; tokens declared in `@theme`
  (there is no `tailwind.config`). Custom motifs (grid, masks, clearings,
  crosses) are hand-written classes in `global.css`.
- **Geist** / **Geist Mono** typefaces (`--font-sans` / `--font-mono`). Mono is
  reserved for code, eyebrow labels, timestamps, and the faux `.md` preview.
- OG image generated at build with `astro-og-canvas`.
- North star: restrained developer-product sites — **Vercel**, Linear —
  generous whitespace, hairline structure, type that sits in *clearings* rather
  than on top of busy backgrounds.

## Palette tokens (`global.css @theme`)

- `--color-ink` #0a0a0a (near-black) · `--color-ink-soft` #2b2b2b
- `--color-muted` #5f5f5f · `--color-faint` #6f6f6f — secondary / tertiary text
- `--color-line` #ececec — **structural** hairlines (frame, nav, card borders)
- `--color-grid-line` #f1f1f1 — **decorative grid only**, a hair lighter than
  `--color-line` so the backdrop recedes and never competes with real borders
- `--color-line-soft` #f4f4f4 · `--color-paper` #ffffff

## Layout & motifs

- Content sits in a centered `max-w-6xl` column framed by hairlines (a real
  `border-l` plus a 1px outset shadow on the right edge, so both lines land
  exactly on grid lines — see the comment in `index.astro`). Corner `+`
  cross-marks (`.cross`) frame it like a technical drawing.
- Display type uses `.tracking-tightest` (-0.04em) and Tailwind's
  `text-balance` / `text-pretty`.
- Full-bleed sections break out with `left-1/2 w-screen -translate-x-1/2`;
  `html`/`body` use `overflow-x: clip` to hide the breakout overflow without
  killing the sticky nav.

## Grid backdrop + "clearing"

The graph-paper grid (`.bg-grid`, 64px rhythm, anchored to viewport center) is
**texture, not structure**. Two rules keep it from feeling busy behind headlines:

1. **Recede the lines.** The grid paints in `--color-grid-line` (lighter than
   real borders). On the dark "Private by design" band it's white at
   `opacity-[0.07]`.
2. **Clear behind the type.** A soft radial wash sits *above* the grid and
   *below* the content, centered on the headline, so the grid fades to the page
   color directly under the text and returns to faint texture at the edges — the
   headline reads as calm negative space (the Vercel move).
   - `.hero-clear` — **white** wash for the light hero.
   - `.closing-clear` — **ink** wash for the dark closing band (same idea,
     inverted color, tuned to that section's shorter vertical rhythm).
   - Both are responsive (separate mobile / `sm:` radii). The radial center
     (`at 50% Ypx`) tracks the headline — **re-tune it if a section's vertical
     spacing changes.** Layering: grid `-z-10` → clear `-z-[9]` → content.

- The hero grid additionally fades at its outer edge via `.mask-radial`
  (anchored top-center); the closing grid intentionally runs to the band edges.
- Both grids drift at 0.25× scroll (`gridParallax.ts`) for subtle depth, and
  honor `prefers-reduced-motion`.
