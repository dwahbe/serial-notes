// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  // Keep in sync with SITE.url in src/consts.ts — enables absolute URL building
  // (canonical/OG, future sitemap) via Astro.site.
  site: 'https://serialnotes.app',
  vite: {
    plugins: [tailwindcss()]
  }
});