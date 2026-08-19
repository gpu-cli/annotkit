# AnnotKit — web

The landing page at **https://annotkit.gpu-cli.sh**. One page, no router, no
docs site. Spec: [`../docs/epic-landing-page.md`](../docs/epic-landing-page.md).

Isolated from the Swift package: its own lockfile, its own toolchain. Nothing
in here affects `swift build` or `swift test`.

## Commands

Run from the repo root (go-task), or with `npm --prefix web run <script>`.

| Task | What it does |
|---|---|
| `task web:dev` | Vite dev server on :5173. UI only — `/api/subscribe` 404s. |
| `task web:dev:functions` | `wrangler pages dev` in front of Vite, so the subscribe function runs locally. Needs `web/.dev.vars`. |
| `task web:build` | Sync fonts → typecheck → `vite build` into `web/dist`. |
| `task web:test` | Vitest — the subscribe contract and the email-validator parity. |
| `task web:contrast` | Prints the WCAG table for every token pair the page renders. Exits non-zero on a fail. |
| `task web:responsive` | Drives headless Chrome at 320/375/414/768/1280 px and fails on horizontal overflow or a wrapped affordance (gates 34, 49, 50). Needs `dist` — run after a build. |
| `task web:og` | Re-renders `public/og.png` from `scripts/og-template.html`. |
| `task web:deploy` | Build, then deploy to the Pages **production** branch. |
| `task web:deploy:preview` | Build, then deploy to a Pages **preview** URL. |

## Layout

```
web/
  index.html            meta, canonical, OG, the display-font preload
  src/
    copy.ts             every string on the page, in one file
    config.ts           name, URLs, analytics keys — no hard-coded identity
    captures.ts         the figure manifest (pending → ready, see below)
    analytics.ts        PostHog: cookieless, fixed taxonomy, no PII
    styles/tokens.css   the Hallmark stamp + the whole palette and type scale
    styles/base.css     reset, elements, every component style
    sections/           the eight sections, in DOM order
    components/         CodeBlock · SubscribeForm · Figure · Section
  shared/               email validation, imported by BOTH client and function
  functions/api/        the Pages Function — POST /api/subscribe
  tests/                vitest
  scripts/              font sync · contrast table · responsive check · OG card
```

## Configuration

Copy `.env.example` → `.env` for the client-side build vars, and
`.dev.vars.example` → `.dev.vars` for the function's secrets in local dev.

| Name | Where it lives | Notes |
|---|---|---|
| `RESEND_API_KEY` | Pages secret, per environment | Restricted key: Contacts **write** only. |
| `RESEND_SEGMENT_ID` | `wrangler.jsonc` `vars`, per environment | Preview gets its own segment so test signups stay out of the real list. |
| `SUBSCRIBE_RL` | Optional KV binding | Per-IP limiter, 5/hour. Absent → limiter off. |
| `VITE_POSTHOG_KEY` | Build env | PostHog **project** key. Public by design. Empty → analytics inert. |
| `VITE_POSTHOG_HOST` | Build env | Region host, e.g. `https://eu.i.posthog.com`. |
| `VITE_SITE_URL` | Build env | Canonical origin. Defaults to the production URL. |

## Cloudflare Pages setup

Connect the repo to a Pages project and use these build settings. The repo root
is the Swift package, so the **root directory must be `web`** — every other
field is relative to it.

| Field | Value |
|---|---|
| Framework preset | **None** |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Root directory | `web` |
| Node version | pinned to 22 by `web/.node-version` |

Pages runs `npm ci` for you when it sees `package-lock.json`; the build script
then syncs the fonts, typechecks both tsconfigs, and runs `vite build`. Dev
dependencies are needed at build time (TypeScript, Vite) — don't set
`NPM_FLAGS=--omit=dev`.

`wrangler.jsonc` sits at the root directory, so Pages reads the project name,
the compatibility date, `pages_build_output_dir`, and the per-environment
`RESEND_SEGMENT_ID` from it. Its `name` (`annotkit`) must match the Pages
project name. `functions/api/subscribe.ts` is picked up automatically and
served at `/api/subscribe` — there is nothing to configure for it.

**The config file is the source of truth.** Once a Pages project has a
`wrangler.jsonc`, the fields it declares become read-only in the dashboard —
you can see them, you cannot edit them there. So `RESEND_SEGMENT_ID` is changed
by editing this file and redeploying, not in the UI. Encrypted secrets are a
separate store and stay dashboard-editable.

Then, once per environment:

```sh
cd web
npx wrangler pages secret put RESEND_API_KEY --project-name annotkit
```

`wrangler pages secret put` has no environment flag, so for a per-environment
key set it in the dashboard instead: **Settings → Variables and secrets**, add
`RESEND_API_KEY` as an *encrypted secret*, once under Production and once under
Preview. Secrets are not part of `wrangler.jsonc`, so they stay editable there
even though the plain vars do not (see below).

and set the build-time client vars in **Settings → Environment variables**
(they are compiled into the bundle, so they belong to the build, not the
runtime):

| Variable | Preview | Production |
|---|---|---|
| `VITE_POSTHOG_KEY` | the PostHog project key | same |
| `VITE_POSTHOG_HOST` | e.g. `https://eu.i.posthog.com` | same |
| `VITE_SITE_URL` | leave unset — previews then advertise the production canonical, which is what you want for a preview that must not be indexed | `https://annotkit.gpu-cli.sh` |

## Deploying

**With the Git integration connected, there is no deploy command** — pushing to
the production branch deploys production, and opening a PR deploys a preview.
The commands below are for a manual or CI direct upload, and for the first
deploy before the repo is connected.

```sh
task web:deploy            # build, then deploy to production
task web:deploy:preview    # build, then deploy to a preview URL
```

Both wrap `wrangler pages deploy` and run from `web/`, which matters: Wrangler
reads `wrangler.jsonc` from the current directory, and that is where the
per-environment `RESEND_SEGMENT_ID` lives. Deploying from the repo root skips
it silently.

The raw form, if you want it without the task:

```sh
cd web
npm run build
wrangler login                                                        # first time only
wrangler pages deploy dist --project-name annotkit --branch main      # production
wrangler pages deploy dist --project-name annotkit --branch preview   # a preview URL
```

`--branch` is the load-bearing flag. Wrangler infers the branch from git when
you omit it, so an unqualified deploy from `main` goes straight to production —
which is why the tasks state it rather than leave it to inference. Any branch
name that is not the project's production branch produces a preview deployment
at `<branch>.annotkit.pages.dev`.

Secrets are not part of a deploy. `wrangler pages secret put` writes them once
per environment (see above), and they persist across deployments.

## Design

Hallmark, genre **editorial**: macrostructure **Specimen**, theme **Specimen**,
nav **N6** masthead, footer **Ft1**. The stamp, the palette, the type scale and
the pre-emit critique scores are at the top of `src/styles/tokens.css`; the run
is recorded in `.hallmark/log.json`.

Two rules worth knowing before editing:

- **Every colour and font comes through a token.** No inline hex, no inline
  `oklch()`, no bare `font-family` outside `tokens.css` (gate 48). Need a value
  that doesn't exist? Add the token first.
- **Section numbers stack above their headings.** Never a label-left /
  heading-right two-column head (gate 54), even though the Specimen sketch
  draws it that way.

`node scripts/contrast.mjs` mirrors the palette and prints the WCAG table. If
you change a colour in `tokens.css`, change it there too and re-run — CI does.

`node scripts/responsive-check.mjs` is the automated half of the responsive
floor: it overrides Chrome's device metrics (the browser clamps its own window
to 500 px, so `--window-size` cannot reach 320) and fails the build on any
horizontal overflow or two-line affordance.

The 58-gate slop-test record for this build is in
[`.hallmark/slop-test.md`](.hallmark/slop-test.md).

## Captures

Figures are real recordings from `task demo`. Until a shot is recorded,
`src/captures.ts` marks it `pending` and the page renders a labelled empty
plate naming the shot. See [`public/captures/README.md`](public/captures/README.md)
for the shot list and how to land one.
