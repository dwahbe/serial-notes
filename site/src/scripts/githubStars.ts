// Live GitHub star count for the "Star on GitHub" button. The build-time count
// is baked into the markup as a fallback (and so it renders without JS); this
// runs client-side on each page load so the number stays current between site
// deploys. Unauthenticated GitHub API calls are rate-limited per visitor IP
// (60/hr), which is plenty for a marketing page.

// Compact formatting: 2 → "2", 1500 → "1.5k", 12000 → "12k".
export function formatStars(n: number): string {
  if (n < 1000) return String(n);
  const k = n / 1000;
  return `${k >= 10 ? Math.round(k) : k.toFixed(1).replace(/\.0$/, "")}k`;
}

export async function initGithubStars(root: HTMLElement) {
  const repo = root.dataset.repo;
  const count = root.querySelector<HTMLElement>("[data-star-count]");
  const number = root.querySelector<HTMLElement>("[data-star-number]");
  if (!repo || !count || !number) return;

  try {
    const res = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return;
    const data = await res.json();
    const stars = data?.stargazers_count;
    if (typeof stars !== "number") return;
    number.textContent = formatStars(stars);
    count.hidden = false;
  } catch {
    // Network failure or rate limit — keep the build-time fallback as-is.
  }
}
