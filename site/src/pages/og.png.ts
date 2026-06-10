import type { APIRoute } from "astro";
import { generateOpenGraphImage } from "astro-og-canvas";

// Build-time only: astro-og-canvas renders this to a static /og.png during
// `astro build` (canvaskit-wasm). Nothing ships to the client. Fonts are the
// site's Geist, pulled from the Fontsource API and cached across builds.
export const prerender = true;

export const GET: APIRoute = async () => {
  const body = await generateOpenGraphImage({
    // No description: just the brand lockup + the headline, kept large and
    // readable at iMessage/Slack preview sizes.
    title: "Meeting notes, where you already work",
    bgGradient: [[10, 10, 10]], // --color-ink
    // og-logo.png = the site-header lockup (white mark + "Serial Notes") on
    // transparency, rendered at 3× — regenerate with `bun scripts/make-og-logo.mjs`
    // and keep this width at ⅓ of the PNG's.
    logo: { path: "./src/og-logo.png", size: [378] },
    padding: 80,
    border: { color: [64, 64, 64], width: 14, side: "block-end" },
    fonts: ["https://api.fontsource.org/v1/fonts/geist-sans/latin-700-normal.ttf"],
    font: {
      title: {
        color: [250, 250, 250],
        size: 68,
        weight: "Bold",
        families: ["Geist"],
        lineHeight: 1.1,
      },
    },
    format: "PNG",
  });

  return new Response(body, {
    headers: {
      "Content-Type": "image/png",
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
};
