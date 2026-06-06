// Cursor-proximity halftone: dots near the pointer swell, easing back when it
// leaves — the classic "interactive dot grid" effect, done on the SVG we
// already render (no canvas, no dependency). Each dot's radius is driven by its
// distance to the cursor; a per-frame lerp toward that target keeps the motion
// fluid. The rAF loop idles itself: it only runs while the pointer is over the
// graphic or while dots are still settling back to their base size.
//
// Skipped for coarse/touch pointers and reduced-motion users — the SSR markup
// already renders the static lock, so this is purely an enhancement.

export function initDotHover(svg: SVGSVGElement) {
  const fine = matchMedia("(hover: hover) and (pointer: fine)").matches;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!fine || reduce) return;

  const circles = Array.from(svg.querySelectorAll<SVGCircleElement>("circle"));
  const n = circles.length;
  if (!n) return;

  // Cache geometry in flat arrays — the per-frame loop never touches the DOM
  // except to write the one value that changed.
  const cx = new Float32Array(n);
  const cy = new Float32Array(n);
  const baseR = new Float32Array(n);
  const curR = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    cx[i] = circles[i].cx.baseVal.value;
    cy[i] = circles[i].cy.baseVal.value;
    baseR[i] = circles[i].r.baseVal.value;
    curR[i] = baseR[i];
  }

  const RADIUS = 48; // influence radius, in viewBox units
  const RADIUS2 = RADIUS * RADIUS;
  const MAX_BUMP = 2.4; // extra radius added at the cursor
  const EASE = 0.2; // fraction of the gap closed each frame

  let px = 0;
  let py = 0;
  let active = false;
  let raf = 0;

  // Map a client-space point into the SVG's user (viewBox) coordinates,
  // accounting for scaling + letterboxing from preserveAspectRatio.
  function toViewBox(clientX: number, clientY: number) {
    const m = svg.getScreenCTM();
    if (!m) return null;
    const inv = m.inverse();
    return {
      x: clientX * inv.a + clientY * inv.c + inv.e,
      y: clientX * inv.b + clientY * inv.d + inv.f,
    };
  }

  function frame() {
    let moving = false;
    for (let i = 0; i < n; i++) {
      let target = baseR[i];
      if (active) {
        const dx = cx[i] - px;
        const dy = cy[i] - py;
        const d2 = dx * dx + dy * dy;
        if (d2 < RADIUS2) {
          const t = 1 - Math.sqrt(d2) / RADIUS; // 1 at cursor → 0 at edge
          target += MAX_BUMP * t * t; // eased falloff
        }
      }
      const next = curR[i] + (target - curR[i]) * EASE;
      if (Math.abs(next - curR[i]) > 0.002) {
        curR[i] = next;
        circles[i].r.baseVal.value = next;
        moving = true;
      }
    }
    raf = moving || active ? requestAnimationFrame(frame) : 0;
  }

  function ensureRunning() {
    if (!raf) raf = requestAnimationFrame(frame);
  }

  svg.addEventListener("pointermove", (e) => {
    const p = toViewBox(e.clientX, e.clientY);
    if (!p) return;
    px = p.x;
    py = p.y;
    active = true;
    ensureRunning();
  });
  svg.addEventListener("pointerleave", () => {
    active = false;
    ensureRunning();
  });
}
