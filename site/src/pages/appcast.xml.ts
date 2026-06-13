import type { APIRoute } from "astro";
import { recordPing } from "../lib/analytics";

// On-demand proxy in front of the repo-committed appcast (CI keeps committing
// appcast.xml to main; that file stays the single source of truth). Serving it
// from serialnotes.app lets us count update checks — the one request every
// install already makes — as an anonymous active-user signal. The ping stores
// (UTC day, app version, count) and nothing else.
//
// SUFeedURL in the app points here from v0.1.7 on; older installs keep reading
// the GitHub raw URL directly, so this route must serve a byte-faithful copy.
export const prerender = false;

const APPCAST_SOURCE =
  "https://raw.githubusercontent.com/dwahbe/serial-notes/main/appcast.xml";

// Sparkle's default User-Agent: "<app name>/<short version> Sparkle/<framework version>".
const sparkleVersion = (ua: string): string =>
  ua.match(/^[^/]+\/(\S+)\s+Sparkle\//)?.[1] ?? "unknown";

export const GET: APIRoute = async ({ request }) => {
  const ua = request.headers.get("user-agent") ?? "";
  // Count only real Sparkle checks; browsers, bots, and curl don't skew numbers.
  const counting = ua.includes("Sparkle")
    ? recordPing(sparkleVersion(ua))
    : Promise.resolve();

  try {
    const upstream = await fetch(APPCAST_SOURCE, {
      signal: AbortSignal.timeout(10_000),
    });
    if (!upstream.ok) throw new Error(`upstream ${upstream.status}`);
    const xml = await upstream.text();
    await counting;
    return new Response(xml, {
      headers: {
        "Content-Type": "application/xml; charset=utf-8",
        // Every check must reach this function or it isn't counted — never let
        // Vercel's CDN absorb the request.
        "Cache-Control": "no-store",
      },
    });
  } catch {
    await counting;
    // Sparkle shrugs off a failed check and retries on its next cycle.
    return new Response("appcast temporarily unavailable", { status: 502 });
  }
};
