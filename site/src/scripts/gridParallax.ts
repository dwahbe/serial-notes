// Slight parallax for the hairline grid backdrops: drift a layer's
// background-position-y at `factor`× scroll so the pattern lags the content
// (~0.75× perceived) and reads as depth. Shifting the pattern — not the
// element — keeps the radial vignette static and can never expose a grid edge.
// rAF-throttled; honors prefers-reduced-motion.
export function initGridParallax(el: HTMLElement, factor = 0.25, base = -1) {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  let ticking = false;

  function apply() {
    ticking = false;
    el.style.backgroundPositionY = `${base + window.scrollY * factor}px`;
  }
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(apply);
  }
  function enable() {
    window.addEventListener("scroll", onScroll, { passive: true });
    apply();
  }
  function disable() {
    window.removeEventListener("scroll", onScroll);
    el.style.backgroundPositionY = "";
  }

  if (!reduce.matches) enable();
  reduce.addEventListener("change", (e) => (e.matches ? disable() : enable()));
}
