/**
 * The canonical origin, in one place.
 *
 * Two build contexts need it and they cannot see each other's globals:
 * `vite.config.ts` substitutes it into index.html at build time (Node), and
 * `src/config.ts` hands it to the components (browser). Holding a copy in
 * each is how the canonical tag and the OG url end up disagreeing after a
 * domain change, so both import this.
 *
 * `VITE_SITE_URL` overrides it per environment; this is only the fallback.
 *
 * NOT the only place the domain appears — `scripts/og-template.html` prints
 * it as footer text, and that is baked into `public/og.png`. Changing the
 * domain means changing that too and re-running `npm run og`. See the
 * "Moving to a different domain" section of README.md.
 */
export const DEFAULT_SITE_URL = "https://annotkit.gpu-cli.sh";
