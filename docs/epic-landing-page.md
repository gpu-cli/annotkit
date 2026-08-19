# Epic — AnnotKit landing page & updates list (web/L0)

| | |
|---|---|
| Status | Proposed |
| Created | 2026-08-19 |
| Scope | New `web/` subtree — no changes to Swift targets |
| Stack (locked) | Vite + React + TypeScript · Cloudflare Pages + Pages Function · Resend (Segments/Contacts API) |
| Design (locked) | Hallmark — genre **editorial**, tone **specimen** |

A small standalone marketing page for AnnotKit: what it is, how to use it,
where the code lives, and a "get updates" signup backed by Resend. One page,
no router, no docs site, no blog.

---

## 1. Background & motivation

AnnotKit's only storefront today is `README.md`. The repo is preparing for
public release (`DECISIONS.md`: SemVer 0.x pre-1.0, MIT, standalone repo at
`github.com/gpu-cli/annotkit`). Before/around the public push we want:

1. A page that explains the product in ninety seconds — the README is written
   for someone already sold.
2. A canonical link to point people at (social posts, conference demos, the
   README itself).
3. A low-friction way to capture interest that isn't "watch the repo":
   an email updates list, owned by us, via Resend.

The page must be honest about what AnnotKit is: a pre-1.0, MIT-licensed,
single-maintainer Swift package. No invented metrics, no fake testimonials,
no venture-SaaS voice (see §6.6 — this is a hard design constraint, not a
nicety).

## 2. Goals / non-goals

**Goals**

- Explain the loop: install → click/frame a view → write a note → agent reads
  it. With real code and real captures.
- Drive two actions: **GitHub visit** (primary) and **email signup**
  (secondary). Both measurable.
- Ship a Resend-backed subscription endpoint we keep for the life of the
  project.
- Stand up `web/` infrastructure (build, previews, deploy) that later pages
  (docs, changelog) can reuse.

**Non-goals** (explicitly out of scope — push back if they creep in)

- Docs site, guides, blog, changelog page. The README stays the docs.
- Pricing, accounts, login, or any productised SaaS surface.
- Multiple pages / client-side routing.
- A comments/community layer.
- Sending actual update emails (Broadcasts) — that's a later operational
  task, not part of this epic. This epic only builds list *capture*. A
  welcome/confirmation email on signup is likewise deferred (needs a verified
  sending domain); the on-screen success state is the only confirmation in v1.
- Reworking the Swift package, README, or demo app (captures only).

## 3. Success measures

Instrumentation, not invented baselines — we measure from zero once live.

| Measure | How | Target |
|---|---|---|
| Signup conversion | `subscribed` events / unique page loads | Establish baseline in first 30 days |
| GitHub click-through | Outbound link clicks to `github.com/gpu-cli/annotkit` | Establish baseline |
| Form health | Client-side validation errors vs. submissions; 5xx rate on `/api/subscribe` | < 1 % server errors |
| Page performance | Lighthouse CI on PRs | ≥ 95 in all four categories |
| List quality | Hard-bounce / invalid addresses on first Broadcast send | < 5 % |

Analytics: **PostHog** (maintainer's existing preference). Instrumented in
L5 with a small, fixed event taxonomy; configured in cookieless/memory
persistence mode so no consent banner is required for launch. Event
properties must never carry the submitted email address or other PII —
conversion is counted, individuals are not tracked. Verify the current
SDK cookieless option at L5 (PostHog has shipped several persistence
modes; pick the one that avoids cookies/localStorage entirely).

## 4. Audience & positioning

- **Primary:** macOS/iOS developers already using AI coding agents (Claude
  Code, Cursor, et al.) who feel the "describe the UI in words and watch the
  agent guess" pain daily.
- **Secondary:** dev-tool watchers, Swift community, Agentation-curious web
  devs looking for the native analogue.
- **One-sentence positioning:** *AnnotKit is the native analogue of the web
  Agentation tool — click a view in your own app, attach a note, and hand an
  AI coding agent a selector it can trace back to code.*
- **Tone of voice:** specific, hand-set, slightly literary (editorial genre).
  Verbs over adjectives. Say "0.x, API may shift" rather than pretending
  otherwise.

## 5. Information architecture

One page, sections in DOM order. Copy deck in Appendix A; final wording is
locked in L4, derived only from facts in `README.md`, `DECISIONS.md`, and
`Package.swift`.

1. **Masthead nav** — wordmark, dateline row (`macOS 15 · iOS 17 · Swift 6 ·
   MIT`), links: GitHub ↗, Updates (in-page anchor).
2. **Hero** — oversized serif statement + standfirst + typographic CTAs
   ("Read the README ↗" primary; "Get release notes ↓" secondary anchor).
   Typography only — no mockup in the fold.
3. **§01 Install** — the two snippets from the README verbatim
   (`Annotation.install()` under `#if DEBUG`; `.installAnnotation()` for
   SwiftUI).
4. **§02 Annotate** — the targeting rules in plain language (click descends to
   the deepest actionable control; a drawn frame inverts to the largest
   surrounded element). Led by a **muted screen-recording loop** of
   AnnotKitDemo (click → composer → note) in a bare `<figure>` — the first
   visual on the page, sitting just under the hero fold — with a still figure
   (pin + composer detail) supporting the copy.
5. **§03 Hand it to the agent** — `AGENTATION_NOTES.md` sample excerpt
   (backed by a still capture of the written notes file), the sink story
   (file / clipboard / JSON), the `process-agentation-notes` skill mention.
6. **§04 Ask over MCP** — optional bridge: `swift run annotkit-mcp`, the two
   tools (`annotation_get_pending`, `annotation_resolve`).
7. **§05 Get updates** — the signup form (email only), one honest line about
   cadence, privacy microcopy.
8. **Footer** — wordmark + tagline + links (GitHub, Issues, License) + a
   colophon line (typefaces, license, clean-room note re: the
   `AGENTATION_NOTES.md` format).

Every section gets a numbered left-margin label (Specimen macrostructure
signature): `§01 … §05`.

## 6. Design direction (Hallmark)

Hallmark governs the visual build. The full flow runs at implementation time;
this section locks the picks so implementation is execution, not exploration.

### 6.1 Locked picks

| Axis | Pick | Rationale |
|---|---|---|
| Genre | **editorial** | User-selected. Reads as "crafted native software" (Swift.org-adjacent), not AI-slop SaaS. |
| Macrostructure | **10 · Specimen** | User named the specimen tone explicitly (Hallmark's gate for using Specimen). Numbered margin labels map 1:1 onto the §01–§05 story; asymmetric spans suit code + figure pairs. |
| Theme | **Specimen** | Light warm-tinted paper, ink, high-contrast serif display, single **warm accent** (< 5 % of any viewport). Never pure black/white. |
| Nav | **N6 · Newspaper masthead** | Editorial default; the dateline row carries our platform facts (`macOS 15 · iOS 17 · Swift 6`). |
| Footer | **Ft1 · Mast-headed** | Wordmark band + tagline + small links; colophon line fits the genre. |
| Enrichment | **Typography-led hero; one loop + stills (real captures)** | Hero is type only. §02 leads with a muted AnnotKitDemo loop; stills support §02/§03 — all real captures in bare `<figure>` (hairline border at most). **Hallmark gate 47: no re-drawn browser/IDE/code-window chrome.** Optional Tier-B hand-built SVG (cursor → pin → note → agent glyph) if L4 has slack. |
| Motion | **Quiet** — one orchestrated hero entrance; hairline rules draw on scroll | Editorial genre rule. `prefers-reduced-motion` honoured. No bounces, no counters. |
| Reveal | Sections fade/slide once on intersection | Single primitive, ≤ 300 ms. |

First Hallmark run for this project: no `.hallmark/log.json` exists, so no
diversification constraint applies. Implementation **must** create
`web/.hallmark/log.json` and stamp the CSS:
`/* Hallmark · genre: editorial · macrostructure: Specimen · theme: Specimen · enrichment: real-capture figure · nav: N6 · footer: Ft1 */`.

### 6.2 Typography (2 + 1 discipline)

Self-hosted via `@fontsource/*` (no Google Fonts runtime dependency), subset
to latin, `woff2`, display face preloaded.

| Role | Face | Notes |
|---|---|---|
| Display | **Fraunces** (variable) | Foundry-grade high-contrast serif; the specimen voice. Roman only — **italic headers are banned globally**; emphasis via weight/accent/drawn underline. |
| Body | **Newsreader** | Workhorse serif, optical sizes, 45–75 ch measure. Italic allowed for in-paragraph emphasis only. |
| Mono | **IBM Plex Mono** | Code, selectors, margin labels, dateline. |

Alternate if Fraunces disappoints in situ: Source Serif 4 (display) — swap is
one token change.

### 6.3 Colour

OKLCH custom properties in `src/styles/tokens.css`, locked after selection —
every declaration references `var(--token)`, **no mid-render inline hex/OKLCH**
(Hallmark gate 48). Sketch (final values tuned at L1):

- `--color-paper`: warm off-white (L > 92 %, slight warm hue)
- `--color-ink`: warm near-black (L < 25 %, tinted toward the paper's hue)
- `--color-accent`: one warm hue (10–60°) — used for §numbers, link
  underlines, the mark band, focus rings
- `--color-hairline`: ink at ~12 % alpha — hairline rules, never card borders
- Light-only. No dark mode in v1 (the specimen voice is paper; dark variant
  is a later, deliberate redesign — not a toggle).

### 6.4 Layout & responsive floor

- Asymmetric columns (e.g. 2:5 label:content), generous whitespace, 4-pt
  spacing scale.
- Verified at **320 / 375 / 414 / 768 px** — hard floor: `overflow-x: clip`
  on `html`/`body`; no two-line clickable text; image grid tracks use
  `minmax(0, 1fr)`; display headers get `overflow-wrap: anywhere`;
  section heads collapse to one column on mobile (Hallmark gates 34, 49–52).

### 6.5 Accessibility

WCAG 2.2 AA: visible `:focus-visible` rings (accent), skip link, form labels
(not placeholder-as-label), `aria-live="polite"` for form status, contrast
verified per token pair (recorded in the L1 PR), keyboard-complete form.

### 6.6 Honest-copy rule (hard constraint)

AnnotKit is pre-release: **no metrics, no testimonials, no logo walls, no
"trusted by" anything.** Hallmark treats invented proof as slop outright.
Stat-shaped layouts are therefore off the table; the Specimen macrostructure
carries authority through typography instead. Where proof would normally sit,
we show the real thing: code, captures, the note format itself.

## 7. Signup UX — state discipline

The form is the page's only stateful UI; it ships **all eight states**
(Hallmark interaction-and-states mandate), each visibly distinct:

| State | Trigger | Presentation |
|---|---|---|
| default | — | email input + "Get release notes" submit |
| hover | pointer over submit | accent underline / fill shift |
| focus-visible | keyboard focus | accent ring on input + submit |
| active | press | 1 px translate |
| disabled | submitting or invalid empty | reduced opacity, no pointer |
| loading | POST in flight | submit label → "Subscribing…", `aria-busy` |
| error | 400/429/5xx | inline message below input (what happened + what to do), input keeps value, focus moves to message |
| success | 200 | form replaced by confirmation line (`role="status"`); no toast |

Copy for states lives in Appendix A. Client validation mirrors server
validation (format only — never existence). Submit is idempotent: a duplicate
email returns the success state with "already on the list" wording.

## 8. Technical architecture

### 8.1 Repo layout

Everything lives under `web/` — isolated lockfile, isolated toolchain, zero
impact on `swift build` / `swift test`.

```
web/
  index.html
  package.json            # vite, react, react-dom, typescript, zod, @fontsource/*
  vite.config.ts
  tsconfig.json
  wrangler.jsonc          # Pages project config (name, build output, compat)
  public/
    favicon.svg
    og.png                # 1200×630, generated in L4
    captures/             # real AnnotKitDemo stills/loops (L4)
  src/
    main.tsx
    App.tsx
    copy.ts               # single source of truth for all strings
    styles/
      tokens.css          # Hallmark-stamped; colour/type/space tokens
      base.css            # reset, elements, utilities
    sections/
      Masthead.tsx  Hero.tsx  Install.tsx  Annotate.tsx
      AgentNotes.tsx  McpBridge.tsx  Signup.tsx  Footer.tsx
    components/
      CodeBlock.tsx       # mono block + copy button (8 states)
      SubscribeForm.tsx   # the state machine from §7
  functions/
    api/
      subscribe.ts        # Pages Function — POST /api/subscribe
  tests/
    subscribe.test.ts     # vitest: validation, honeypot, error mapping
```

### 8.2 The subscribe endpoint

Cloudflare **Pages Function** at `web/functions/api/subscribe.ts` (file-based
routing → `POST /api/subscribe`). Runs on Workers runtime; holds the Resend
key server-side. Contract:

```
POST /api/subscribe
Content-Type: application/json

{ "email": "dev@example.com", "url": "" }   # `url` is a hidden honeypot
                                             # field; non-empty → silent 200
```

| Status | Body | Meaning |
|---|---|---|
| 200 | `{ "status": "subscribed" }` | Contact created in Resend segment |
| 200 | `{ "status": "already_subscribed" }` | Idempotent — email already exists |
| 200 | `{ "status": "subscribed" }` (honeypot) | Bot deflection — no Resend call, no signal difference |
| 400 | `{ "error": "invalid_email" }` | Fails zod email schema |
| 405 | — | Non-POST |
| 429 | `{ "error": "rate_limited" }` | Per-IP throttle tripped |
| 502 | `{ "error": "upstream" }` | Resend call failed — logged, generic client message |

Implementation rules:

- Validate with **zod** (`z.string().email().max(254)`), trim + lowercase
  before send.
- **Resend Segments, not Audiences** — Audiences are deprecated (still
  functional, scheduled for removal). One segment, e.g. `annotkit-updates`,
  created once in the Resend dashboard by the maintainer; its ID is config.
  Subscribe call: `POST https://api.resend.com/contacts` with
  `{ email, unsubscribed: false, segments: [{ id: SEGMENT_ID }], properties: { source: "landing-page" } }`.
  Use the `resend` npm SDK or plain `fetch` (function stays dependency-light;
  `fetch` is fine for one call).
- **Duplicate semantics must be verified in the L3 spike first** (create the
  same contact twice; observe the response). Map the duplicate signal to
  `already_subscribed`; if create isn't idempotent, fall back to
  `PATCH /contacts/:email` / update-on-conflict. Record findings in the PR.
- Rate limiting: per-IP sliding window in Workers KV (binding
  `SUBSCRIBE_RL`, e.g. 5/hour/IP). Sized as a stretch inside L3 — honeypot +
  validation ship first; KV limiter lands if spam appears. Turnstile is the
  documented next escalation (skill installed), deliberately not v1.
- CORS: same-origin only; no `Access-Control-Allow-Origin` header.
- Errors: `console.error` with the Resend response body (Pages → Workers
  logs); the client never sees upstream detail.
- No database of our own — Resend is the store of record. (Revisit only if we
  later need double opt-in tokens; see §11 risks.)

### 8.3 Configuration & secrets

| Name | Where | Notes |
|---|---|---|
| `RESEND_API_KEY` | Pages secret (`wrangler pages secret put`) | Restricted key: Contacts write only (+ Email send later if welcome email ships) |
| `RESEND_SEGMENT_ID` | `wrangler.jsonc` `vars` (not secret) | One segment per environment, or a shared segment — maintainer's call |
| `PUBLIC_POSTHOG_KEY` | build-time env (`.env` / CI) | PostHog **project** API key — public by design, safe to expose client-side |
| `PUBLIC_POSTHOG_HOST` | build-time env | PostHog cloud host (pick region at project creation; EU cloud sidesteps most GDPR data-transfer questions) |
| `TURNSTILE_SECRET_KEY` | (deferred) | Only if the Turnstile escalation ships |

Preview and production environments both configured; preview gets its own
segment so test signups don't pollute the real list.

### 8.4 Build, dev, deploy

- Local dev: `npm run dev` (Vite) for pure UI; `wrangler pages dev` when
  exercising the function locally.
- Build: `vite build` → `dist/`; deploy: `wrangler pages deploy dist`.
- PR previews: Pages' Git integration (connected repo) gives automatic
  preview URLs per PR — prefer that over hand-rolled CI deploys.
- Taskfile additions (root `Taskfile.yml`, matching existing style):

  ```yaml
  web:dev:      npm --prefix web run dev
  web:build:    npm --prefix web run build
  web:test:     npm --prefix web run test
  web:deploy:   wrangler pages deploy web/dist --project-name annotkit
  ```

- CI (`.github/workflows/web.yml`): on PRs touching `web/**` —
  `npm ci`, `tsc --noEmit`, `vitest run`, `vite build`. Swift CI untouched.

### 8.5 Performance budget

- Initial JS ≤ ~60 KB gzip (React + no router + no state library — keep it
  that way; no UI kit).
- Analytics off the critical path: load PostHog via its async snippet or
  `posthog-js-lite` (~5 KB) with a hand-rolled taxonomy — the full
  `posthog-js` bundle (autocapture, replay) is unjustified for one page.
  Deferred either way (`requestIdleCallback` / after LCP).
- Fonts: ≤ 3 files woff2, subset, `font-display: swap` + `size-adjust`
  fallbacks to pin CLS ≈ 0.
- Captures: stills as `avif`/`webp` with `png` fallback; exactly **one**
  muted `webm` loop (§02 lead), ≤ ~1.5 MB, `preload="none"`, poster frame —
  paused for `prefers-reduced-motion` (poster shown instead).
- LCP ≤ 1.8 s on mid-tier mobile/4G; Lighthouse ≥ 95 all categories (CI gate).

### 8.6 SEO / social

- `<title>` + meta description from `copy.ts`; canonical URL; OpenGraph +
  Twitter card pointing at `og.png` (theme-styled, real type, **no drawn
  browser chrome**); favicon.svg (accent glyph, works at 16 px).
- `og.png` validated with opengraph.xyz during L4.

## 9. Story breakdown

Sizes: S ≈ half-day, M ≈ 1–2 days, L ≈ 3+ days for one dev.

### L0 — Scaffold & plumbing (S)
Scaffold Vite react-ts in `web/`; base CSS + empty tokens; Taskfile tasks;
CI workflow; connect Pages project; deploy "hello" to preview.
**AC:** `task web:dev` / `task web:build` run; PR preview URL works; Swift
build & tests untouched (CI proves it).

### L1 — Design tokens & type system (S)
Hallmark flow: load editorial genre + Specimen macro + theme; author
`tokens.css` (stamp + palette + type scale + spacing); wire `@fontsource`
fonts; base element styles.
**AC:** every colour/font in the build references a token; AA contrast table
recorded in PR; pre-emit self-critique scores stamped (all ≥ 3).

### L2 — Page sections (M)
Build all eight sections from `copy.ts`; CodeBlock with working copy button
(8 states); responsive at the four floor widths; quiet motion with
reduced-motion path.
**AC:** 58-gate Hallmark slop test run and results recorded in PR
(target 58/58; any fail either fixed or justified); no horizontal scroll at
320–768 px; keyboard pass complete.

### L3 — Subscribe function & Resend (M)
Spike duplicate-contact behaviour first (timebox 1 h, record result); then
`subscribe.ts` per §8.2 contract; zod validation; honeypot; vitest coverage
for every status row; secrets + vars set for preview; `wrangler pages dev`
end-to-end pass. Stretch: KV rate limiter.
**AC:** `curl` against preview lands a contact in the preview segment;
duplicate POST returns `already_subscribed`; all error rows reproduced in
tests; no secrets in client bundle (grep in CI).

### L4 — Content & assets (S)
Record/capture AnnotKitDemo (`task demo`) — the §02 loop plus §02/§03
stills, noting the build hash in each figure caption (`captured at 41263b3`);
final copy pass against Appendix A; `og.png`; favicon; README backlink PR
("Site: https://annotkit.gpu-cli.sh").
**AC:** every figure is a real capture in a bare `<figure>` (gate 47 audit);
copy audit — zero invented metrics/testimonials; OG preview validates.

### L5 — Hardening (S)
axe + keyboard a11y pass; Lighthouse CI gate wired; PostHog wired per §3
(cookieless persistence mode, taxonomy: `landing_view` · `cta_github_clicked`
· `cta_updates_clicked` · `signup_submitted` · `signup_succeeded` ·
`signup_failed{kind}` — no PII in properties); meta/robots/canonical;
Turnstile go/no-go (recommend no for launch).
**AC:** Lighthouse ≥ 95 × 4 in CI; axe zero criticals; form fully operable
keyboard-only.

### L6 — Launch (S)
Production secrets/vars; prod deploy; end-to-end prod signup (real address,
verify in Resend dashboard, then remove); wire `annotkit.gpu-cli.sh` as the
Pages custom domain (CNAME — trivial if the `gpu-cli.sh` zone is already on
Cloudflare; otherwise add the validation records at the current DNS
provider); merge README backlink.
**AC:** prod form round-trips to the production segment; site loads at the
canonical URL with valid OG cards.

**Dependencies:** L0 → L1 → L2 → L4 → L5 → L6. L3 can run parallel to L2
once the maintainer actions below are done.

**Maintainer actions (only the human can do these):**
1. Create the Resend account; create segments (`annotkit-updates` +
   `annotkit-updates-preview`); mint a restricted API key (Contacts write).
2. Create the Cloudflare Pages project (or hand over dashboard access);
   connect the repo for PR previews.
3. Set `RESEND_API_KEY` secrets (preview + production).
4. Add the `annotkit.gpu-cli.sh` custom domain to the Pages project and
   create the CNAME record wherever `gpu-cli.sh` DNS is hosted.
5. Create the PostHog project (pick cloud region); hand the project API key
   + host to CI as `PUBLIC_POSTHOG_KEY` / `PUBLIC_POSTHOG_HOST`.
6. Confirm the repo's public timing — the site links GitHub; launching the
   site while the repo is private sends visitors to a 404.
7. Later (post-epic, operational): verify a sending domain in Resend before
   the first Broadcast; Broadcasts always include the unsubscribe footer.

## 10. Epic-level definition of done

- [ ] All L-stories' acceptance criteria met and recorded in their PRs.
- [ ] Page live at `https://annotkit.gpu-cli.sh`; both CTAs verified end-to-end in prod
      (GitHub link resolves; signup lands in the production Resend segment).
- [ ] Hallmark artefacts present: stamped `tokens.css`, `web/.hallmark/log.json`
      entry, slop-test record in the L2 PR.
- [ ] Honest-copy audit signed off: no invented metrics, testimonials, or
      logos anywhere on the page.
- [ ] Lighthouse CI ≥ 95 × 4; axe zero criticals; responsive floor verified.
- [ ] `task web:dev|build|test|deploy` documented in `web/README.md`.
- [ ] Swift package build, tests, and existing CI unaffected.

## 11. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Name is provisional** (`DECISIONS.md`: trademark check required before public release) | Rebrand after launch burns the domain/OG/list identity | Launch on `annotkit.gpu-cli.sh` — a disposable subdomain, no purchased asset to burn. If the name changes, the subdomain and OG assets are cheap to re-issue. Keep the name in `copy.ts`/config, never hardcoded per-component. |
| Resend Segments API is newer than Audiences; duplicate-contact semantics uncertain | Broken or duplicate-y signup path | L3 spike first (timeboxed); contract has an explicit `already_subscribed` row; fall back to update-on-conflict. |
| Repo still private when site ships | Primary CTA 404s for visitors | Launch gated on maintainer action 6; until then the GitHub CTA copy reads "Request access"/is de-emphasised — or launch waits. |
| Captures drift as the overlay UI evolves | Stale screenshots undermine the honest-copy stance | Capture late (L4); caption carries the build hash; re-capture is a 15-minute task (demo app exists for exactly this). |
| Bot signups pollute the list | Broadcast bounce/deliverability pain later | Honeypot + validation v1; KV rate limit stretch; Turnstile documented as the next rung; first Broadcast's bounce rate tracked (§3). |
| Sending domain unverified | Can't send a welcome email / first Broadcast | Explicitly deferred; welcome email is not in v1 scope. Domain verification listed as maintainer action 7. |
| GDPR/consent questions on the list | Compliance risk | Email-only single opt-in is proportionate for an OSS updates list; every future Broadcast carries unsubscribe (Resend handles); privacy microcopy on the form states exactly what subscribers get. If the list grows commercial, add double opt-in later. |
| Scope creep into a docs/blog site | Epic never lands | §2 non-goals; any new surface requires a new epic. |

## 12. Open questions — none remaining (all resolved 2026-08-19)

1. ~~**Domain:** buy `annotkit.dev` (or similar) now, or launch on
   `annotkit.pages.dev` until the trademark check clears?~~ **Resolved
   2026-08-19:** launch on **`annotkit.gpu-cli.sh`** — a subdomain of the
   existing `gpu-cli.sh` domain (matches the GitHub org). No purchase needed.
2. ~~**Analytics:** Cloudflare Web Analytics — on or off?~~ **Resolved
   2026-08-19:** **PostHog** — cookieless/memory persistence mode, fixed
   event taxonomy (§3, L5), no PII in event properties, async/`posthog-js-lite`
   loading to protect the performance budget.
3. ~~**Welcome email:** stay out of v1?~~ **Resolved 2026-08-19:** **deferred
   to post-launch.** v1 is capture-only; the on-screen success state is the
   confirmation. A welcome/confirmation email becomes a follow-up task once a
   sending domain is verified in Resend (maintainer action 7). Double opt-in
   stays off the table unless the list turns commercial.
4. ~~**Form fields:** email-only, or optional name?~~ **Resolved 2026-08-19:**
   **email only.** The §8.2 contract and §7 form spec stand as written — no
   name fields, minimal PII, best conversion.
5. ~~**Loop media in §02:** muted screen-recording loop, or three stills?~~
   **Resolved 2026-08-19:** **a mix.** One muted screen-recording loop leads
   the how-it-works run (§02's lead figure, first thing below the hero fold);
   stills carry the sections further down (pin/composer detail in §02, the
   written `AGENTATION_NOTES.md` in §03). Hero stays typography-only.

---

## Appendix A — Copy deck (draft, locked in L4)

Voice: editorial — specific, verbs over adjectives, slightly literary. Every
claim traceable to `README.md` / `DECISIONS.md` / `Package.swift`.

**Masthead dateline:** `Native annotation for AI coding agents · macOS 15 ·
iOS 17 · Swift 6 · MIT`

**Hero display (pick one in L2):**
- *"Point at the view. Hand the agent the map."*
- *"Annotate the app. The agent finds the code."*

**Hero standfirst:** "AnnotKit mounts a floating toolbar in your dev build.
Click a control — or draw a frame around a whole card — type a note, and it
writes an agent-readable annotation: a stable selector, an element path, a
screenshot, and your words. Your coding agent stops guessing."

**CTAs:** `Read the README ↗` (github.com/gpu-cli/annotkit) ·
`Get release notes ↓`

**§01 Install — lead:** "Add the package. Mount the toolbar. Two lines,
dev builds only."

**§02 Annotate — lead:** "A click means *this exact spot*: AnnotKit descends
to the deepest actionable control. A drawn frame means *this whole thing*:
the largest element the frame surrounds wins. One rule, both platforms — the
selector anchors itself to the nearest `accessibilityIdentifier`, so it
round-trips back to code."

**§03 Hand it to the agent — lead:** "Notes land in `AGENTATION_NOTES.md` —
the format the `process-agentation-notes` skill consumes — or on the
clipboard, or as JSON."

**§04 Ask over MCP — lead:** "Run the optional bridge and let the agent ask
what's pending: `annotation_get_pending`, `annotation_resolve`."

**§05 Get updates:**
- Heading: *"One email when it's worth reading."*
- Body: "Releases, design notes, and the 1.0 call. No digest, no drip
  campaign — AnnotKit is 0.x and honest about it."
- Submit label: `Get release notes`
- Loading: `Subscribing…`
- Success (new): `You're on the list.`
- Success (duplicate): `You're already on the list.`
- Error (invalid): `That address doesn't parse — check for typos.`
- Error (rate-limited): `Slow down — try again shortly.`
- Error (upstream): `Something broke on our side. Try again in a minute.`
- Privacy line: `Your address goes to Resend and nowhere else. Every email
  carries an unsubscribe link.`

**Footer colophon:** "MIT licensed. Reimplements the `AGENTATION_NOTES.md`
format clean-room; contains no Agentation source. Set in Fraunces,
Newsreader & IBM Plex Mono."

## Appendix B — Resend setup runbook (maintainer)

1. Create account → Segments → create `annotkit-updates` (production) and
   `annotkit-updates-preview`. Record both IDs.
2. API Keys → create restricted key: permission **Contacts: write** only.
3. `cd web && wrangler pages secret put RESEND_API_KEY` (per environment).
4. Put `RESEND_SEGMENT_ID` in `wrangler.jsonc` `vars` per environment.
5. Smoke test: `curl -X POST <preview>/api/subscribe -d '{"email":"test@example.com"}'`
   → contact appears in the preview segment.
6. (Later, pre-Broadcast) Domains → verify the sending domain (SPF/DKIM
   records); Broadcasts always include the unsubscribe footer.

## Appendix C — Hallmark implementation checklist (for the L1/L2 PRs)

- [ ] Pre-flight scan emitted (fresh project under `web/` — expected output:
      "No pre-flight signals — proceeding with full Hallmark stack").
- [ ] Picks stated before code: macrostructure Specimen · theme Specimen ·
      nav N6 · footer Ft1 · enrichment real-capture figure.
- [ ] `tokens.css` stamped; all values via tokens (gate 48).
- [ ] No italic headers (gate 38a); no re-drawn chrome (gate 47); no invented
      metrics (gate 46); responsive gates 34 & 49–53 at 320/375/414/768.
- [ ] 58-gate slop test run post-build; fails fixed or justified in the PR.
- [ ] Pre-emit self-critique (P/H/E/S/R/V) all ≥ 3, stamped on the artifact.
- [ ] `web/.hallmark/log.json` created with this run's entry.
