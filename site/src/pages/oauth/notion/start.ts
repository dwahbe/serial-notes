import type { APIRoute } from "astro";
import { getSecret } from "astro:env/server";
import { notionRedirectURI } from "../../../lib/notionOAuth";

// Entry point for the app's "Connect Notion" flow. The app opens this URL in
// the default browser with a random `state` and its build flavor; this route
// owns the OAuth client ID and the redirect-URI selection (the shared
// src/lib/notionOAuth allowlist, byte-exact against Notion's developer
// portal), so the deployed site is the source of truth for OAuth config.
export const prerender = false;

const AUTHORIZE_URL = "https://api.notion.com/v1/oauth/authorize";

const NO_STORE = { "Cache-Control": "no-store" };

export const GET: APIRoute = ({ url }) => {
  const state = url.searchParams.get("state") ?? "";
  if (!state || state.length > 256) {
    return new Response("missing or invalid state", { status: 400, headers: NO_STORE });
  }
  const redirectURI = notionRedirectURI(url.searchParams.get("flavor") ?? "");
  if (!redirectURI) {
    return new Response("unknown flavor", { status: 400, headers: NO_STORE });
  }
  const clientID = getSecret("NOTION_CLIENT_ID");
  if (!clientID) {
    return new Response("NOTION_CLIENT_ID isn't configured", { status: 500, headers: NO_STORE });
  }

  const authorize = new URL(AUTHORIZE_URL);
  authorize.searchParams.set("client_id", clientID);
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("owner", "user");
  authorize.searchParams.set("redirect_uri", redirectURI);
  authorize.searchParams.set("state", state);

  return new Response(null, {
    status: 302,
    headers: { Location: authorize.href, ...NO_STORE },
  });
};
