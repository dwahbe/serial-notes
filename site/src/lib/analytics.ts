import { SITE } from "../consts";

// Supabase project backing the appcast ping counter. Both values are public by
// design (the publishable key maps to the `anon` role, which can only execute
// record_appcast_ping — RLS with zero policies blocks every read and direct
// write). Reads require the secret key, which lives in the SUPABASE_SECRET_KEY
// env var and never ships to a client.
export const SUPABASE_URL = "https://kwkgrtoaduryfdgqjnwf.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY =
  "sb_publishable_NANPtL0onCmGZAYsUkuqfg_33otXt6x";

const GITHUB_REPO = SITE.github.replace("https://github.com/", "");

/**
 * Count one Sparkle update check. Stores (UTC day, app version, count) and
 * nothing else — no IP, no identifier, no timestamp beyond the day. Best-effort:
 * any failure is swallowed so counting can never affect the appcast response.
 */
export async function recordPing(version: string): Promise<void> {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/record_appcast_ping`, {
      method: "POST",
      headers: {
        apikey: SUPABASE_PUBLISHABLE_KEY,
        Authorization: `Bearer ${SUPABASE_PUBLISHABLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_version: version }),
      signal: AbortSignal.timeout(3_000),
    });
  } catch {
    // Lost count beats a broken update feed.
  }
}

export interface PingRow {
  day: string; // YYYY-MM-DD (UTC, matches the counter's current_date)
  version: string;
  count: number;
}

/** Read daily ping counts for the trailing `sinceDays` days (secret key only). */
export async function readPings(
  secretKey: string,
  sinceDays: number,
): Promise<PingRow[]> {
  const since = new Date(Date.now() - sinceDays * 86_400_000)
    .toISOString()
    .slice(0, 10);
  const url =
    `${SUPABASE_URL}/rest/v1/appcast_pings` +
    `?select=day,version,count&day=gte.${since}&order=day.asc`;
  const res = await fetch(url, {
    headers: { apikey: secretKey, Authorization: `Bearer ${secretKey}` },
    signal: AbortSignal.timeout(5_000),
  });
  if (!res.ok) throw new Error(`Supabase read failed (${res.status})`);
  return res.json();
}

export interface ReleaseStat {
  tag: string;
  publishedAt: string;
  downloads: number;
}

/**
 * Per-release download totals from the GitHub API. Counts include Sparkle
 * auto-update downloads, so they're a ceiling on installs, not a user count.
 * Unauthenticated is fine for a single-admin page; GITHUB_TOKEN raises the
 * rate limit if Vercel's shared egress IPs ever run into 403s.
 */
export async function fetchReleaseStats(token?: string): Promise<ReleaseStat[]> {
  const res = await fetch(
    `https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      signal: AbortSignal.timeout(10_000),
    },
  );
  if (!res.ok) throw new Error(`GitHub API failed (${res.status})`);
  const releases: Array<{
    tag_name: string;
    published_at: string;
    assets: Array<{ download_count: number }>;
  }> = await res.json();
  return releases.map((r) => ({
    tag: r.tag_name,
    publishedAt: r.published_at,
    downloads: r.assets.reduce((sum, a) => sum + a.download_count, 0),
  }));
}
