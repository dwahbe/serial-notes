// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import vercel from '@astrojs/vercel';

// https://astro.build/config
export default defineConfig({
  // Keep in sync with SITE.url in src/consts.ts — enables absolute URL building
  // (canonical/OG, future sitemap) via Astro.site.
  site: 'https://serialnotes.app',
  // Static-first: every existing page prerenders exactly as before; only routes
  // that opt out with `export const prerender = false` (/admin, /appcast.xml)
  // run as Vercel server functions.
  adapter: vercel(),
  vite: {
    plugins: [tailwindcss()]
  }
});