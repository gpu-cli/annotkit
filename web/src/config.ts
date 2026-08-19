/**
 * Everything environment- or identity-shaped, in one place.
 *
 * The name is provisional (DECISIONS.md: trademark check before public
 * release), so it lives here and never hard-coded in a component — a rebrand
 * should be a one-file change, not a grep.
 */

export const site = {
  name: "AnnotKit",
  /** STUB — confirm before launch (epic §11, maintainer action 6). */
  url: import.meta.env.VITE_SITE_URL ?? "https://annotkit.gpu-cli.sh",
  repo: "https://github.com/gpu-cli/annotkit",
  issues: "https://github.com/gpu-cli/annotkit/issues",
  license: "https://github.com/gpu-cli/annotkit/blob/main/LICENSE",
  /**
   * Set false while the repo is still private — the GitHub CTA then reads as
   * unavailable instead of sending visitors to a 404 (epic §11 risk row).
   */
  repoIsPublic: true,
} as const;

export const analytics = {
  key: import.meta.env.VITE_POSTHOG_KEY ?? "",
  host: import.meta.env.VITE_POSTHOG_HOST ?? "https://eu.i.posthog.com",
} as const;

/** Where the subscribe Pages Function lives. Same-origin, always. */
export const SUBSCRIBE_ENDPOINT = "/api/subscribe";
