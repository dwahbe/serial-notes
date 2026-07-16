// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import vercel from '@astrojs/vercel';

// https://astro.build/config
export default defineConfig({
  // Keep in sync with SITE.url in src/consts.ts — enables absolute URL building
  // (canonical/OG) via Astro.site. The sitemap builds from SITE.url directly.
  site: 'https://serialnotes.app',
  // Static-first: every existing page prerenders exactly as before; only routes
  // that opt out with `export const prerender = false` (/admin, /appcast.xml,
  // /oauth/notion/start, /api/notion/token) run as Vercel server functions.
  // The two /oauth/notion/*callback pages stay static — they only bounce the
  // browser into the app's custom URL scheme.
  adapter: vercel(),
  // Dev/preview only (Vercel ignores it): honor an externally assigned port
  // (e.g. Claude's preview harness) so parallel sessions don't fight over 4321.
  server: { port: Number(process.env.PORT ?? 4321) },
  vite: {
    plugins: [tailwindcss()]
  }
});