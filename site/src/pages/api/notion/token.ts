import type { APIRoute } from "astro";
import { getSecret } from "astro:env/server";
import { NOTION_ALLOWED_REDIRECT_URIS, NOTION_API_VERSION } from "../../../lib/notionOAuth";

// Stateless pass-through that adds the client-secret Basic auth Notion's OAuth
// endpoints require (no PKCE support), for the three actions the app needs:
// exchange (authorization_code), refresh (refresh_token), and revoke. Notion's
// status + JSON body are returned verbatim so the app sees exactly what Notion
// said. Same privacy invariant as the appcast counter: nothing here is ever
// stored or logged — codes and tokens only transit this function.
export const prerender = false;

const TOKEN_URL = "https://api.notion.com/v1/oauth/token";
const REVOKE_URL = "https://api.notion.com/v1/oauth/revoke";

const NO_STORE = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
};

const reject = (status: number, error: string) =>
  new Response(JSON.stringify({ error }), { status, headers: NO_STORE });

export const POST: APIRoute = async ({ request }) => {
  const clientID = getSecret("NOTION_CLIENT_ID");
  const clientSecret = getSecret("NOTION_CLIENT_SECRET");
  if (!clientID || !clientSecret) return reject(500, "server_not_configured");

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return reject(400, "invalid_json");
  }
  const field = (key: string): string | null =>
    typeof body[key] === "string" && body[key] !== "" ? (body[key] as string) : null;

  let url: string;
  let payload: Record<string, string>;
  switch (body.action) {
    case "exchange": {
      const code = field("code");
      const redirectURI = field("redirect_uri");
      if (!code || !redirectURI) return reject(400, "missing_fields");
      if (!NOTION_ALLOWED_REDIRECT_URIS.has(redirectURI)) return reject(400, "redirect_uri_not_allowed");
      url = TOKEN_URL;
      payload = { grant_type: "authorization_code", code, redirect_uri: redirectURI };
      break;
    }
    case "refresh": {
      const refreshToken = field("refresh_token");
      if (!refreshToken) return reject(400, "missing_fields");
      url = TOKEN_URL;
      payload = { grant_type: "refresh_token", refresh_token: refreshToken };
      break;
    }
    case "revoke": {
      const token = field("token");
      if (!token) return reject(400, "missing_fields");
      url = REVOKE_URL;
      payload = { token };
      break;
    }
    default:
      return reject(400, "unknown_action");
  }

  const basic = Buffer.from(`${clientID}:${clientSecret}`).toString("base64");
  try {
    const upstream = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Basic ${basic}`,
        "Content-Type": "application/json",
        // The endpoint reference marks the version header required (and the
        // token response shape is defined per version) — pin it so a future
        // default-version change can't reshape refresh_token under us.
        "Notion-Version": NOTION_API_VERSION,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });
    return new Response(await upstream.text(), { status: upstream.status, headers: NO_STORE });
  } catch {
    return reject(502, "notion_unreachable");
  }
};
