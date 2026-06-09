import type { APIRoute } from "astro";
import { SITE } from "../consts";

// Build-time only: prerenders to a static /sitemap.xml. Hand-rolled (no
// @astrojs/sitemap dependency) since the site is a single page; add paths to
// `routes` when more pages land. Loc is built from SITE.url for one source of
// truth, matching robots.txt.ts.
export const prerender = true;

const routes = [""]; // root only — "" → SITE.url + "/"

export const GET: APIRoute = () => {
  const urls = routes
    // Trailing slash for non-root paths matches Astro's default directory build
    // format (and the per-page <link rel=canonical>), keeping loc == served URL.
    .map((path) => {
      const loc = path ? `${SITE.url}/${path}/` : `${SITE.url}/`;
      return `  <url>\n    <loc>${loc}</loc>\n  </url>`;
    })
    .join("\n");

  const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;

  return new Response(xml, {
    headers: { "Content-Type": "application/xml; charset=utf-8" },
  });
};
