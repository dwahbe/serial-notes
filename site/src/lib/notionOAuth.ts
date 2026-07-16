// Single source of truth for the Notion OAuth constants shared by the two
// server routes — /oauth/notion/start (flavor → redirect-URI selection) and
// /api/notion/token (exchange allowlist) — so the lists can't drift: an edit
// that landed in only one of them would let the authorize leg succeed and then
// fail every exchange at runtime.
//
// The URIs are byte-exact copies of what's registered in Notion's developer
// portal; the app holds the same strings in NotionOAuthFlow.redirectURI(isDevBuild:).
export const NOTION_REDIRECT_URIS: Record<"prod" | "dev", string> = {
  prod: "https://serialnotes.app/oauth/notion/callback",
  dev: "https://serialnotes.app/oauth/notion/dev-callback",
};

export const NOTION_ALLOWED_REDIRECT_URIS = new Set<string>(
  Object.values(NOTION_REDIRECT_URIS),
);

/**
 * Flavor→URI lookup hardened against Object.prototype keys — a bare
 * `NOTION_REDIRECT_URIS[flavor]` with flavor="constructor" resolves to a
 * truthy inherited function instead of undefined.
 */
export const notionRedirectURI = (flavor: string): string | null =>
  Object.hasOwn(NOTION_REDIRECT_URIS, flavor)
    ? NOTION_REDIRECT_URIS[flavor as "prod" | "dev"]
    : null;

// Pinned API version for Notion's OAuth endpoints (the reference marks the
// header required, and the token response shape — refresh_token included — is
// defined per version). Keep in sync with NotionAPIClient.notionVersion.
export const NOTION_API_VERSION = "2026-03-11";
