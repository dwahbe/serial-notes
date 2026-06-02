import type { APIRoute } from "astro";
import { generateOpenGraphImage } from "astro-og-canvas";

// Build-time only: astro-og-canvas renders this to a static /og.png during
// `astro build` (canvaskit-wasm). Nothing ships to the client. Fonts are the
// site's Geist, pulled from the Fontsource API and cached across builds.
export const prerender = true;

export const GET: APIRoute = async () => {
  const body = await generateOpenGraphImage({
    title: "Meeting notes, where you already work",
    description:
      "Serial Notes — a menu bar app that records your meetings, transcribes on-device, and exports clean Markdown.",
    bgGradient: [[10, 10, 10]], // --color-ink
    logo: { path: "./src/og-logo.png", size: [84] },
    padding: 80,
    border: { color: [64, 64, 64], width: 14, side: "block-end" },
    fonts: [
      "https://api.fontsource.org/v1/fonts/geist-sans/latin-700-normal.ttf",
      "https://api.fontsource.org/v1/fonts/geist-sans/latin-400-normal.ttf",
    ],
    font: {
      title: {
        color: [250, 250, 250],
        size: 68,
        weight: "Bold",
        families: ["Geist"],
        lineHeight: 1.1,
      },
      description: {
        color: [160, 160, 160],
        size: 30,
        weight: "Normal",
        families: ["Geist"],
        lineHeight: 1.4,
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
