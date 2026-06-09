import type { APIRoute } from "astro";
import { SITE } from "../consts";

// Build-time only: prerenders to a static /robots.txt. Generated from SITE.url
// (consts.ts) rather than a hand-written public/robots.txt so the host stays
// single-sourced — mirrors the og.png.ts / sitemap.xml.ts pattern.
export const prerender = true;

export const GET: APIRoute = () =>
  new Response(
    `User-agent: *\nAllow: /\n\nSitemap: ${SITE.url}/sitemap.xml\n`,
    { headers: { "Content-Type": "text/plain; charset=utf-8" } },
  );
