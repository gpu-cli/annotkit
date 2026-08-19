# Slop test — AnnotKit landing page

Run against the built page at 320 / 375 / 414 / 768 / 1280 px, 2026-08-19.
Every gate must answer **no**. Where a gate is answered with a justification
rather than a plain no, the justification is written out — a silent pass on a
gate that fired is the thing this file exists to prevent.

**Result: 58 / 58 pass.** Four gates carry a justification (21, 30, 37/38, 54).

Automated backing:

| Check | Command | Result |
|---|---|---|
| Contrast (gates 40–41) | `node scripts/contrast.mjs` | 14 / 14 pairs pass WCAG AA |
| Responsive floor (34, 49, 50) | `node scripts/responsive-check.mjs` | PASS at 320 / 375 / 414 / 768 / 1280 |
| a11y | `npx vitest run` (`tests/a11y.dom.test.tsx`) | axe: 0 violations |
| Performance / a11y / BP / SEO | `npx lhci autorun` | 100 / 100 / 100 / 100 · LCP 0.4 s · CLS 0 |

---

## Visual · 1–7

1. **Display font a banned default?** No — Fraunces (display), Newsreader (body).
2. **Purple/cyan gradient, gradient headline?** No gradients anywhere. Solid ink.
3. **3-equal-column icon-tile grid?** No. Content pairs are 5 : 7 and 7 : 5 asymmetric spans; term lists are typographic, no icons, no cards.
4. **Card in card?** No cards at all. Hairlines and plates only.
5. **Side-stripe card?** No.
6. **Hero centred-everything?** No. The hero is left-biased with no eyebrow; `min-height` is unset and the hero is the height of its content. The masthead above it is centred *because N6 is a masthead* — that is the archetype's shape, not the hero's.
7. **Pure `#000` / `#fff`?** No. Paper `oklch(96.5% 0.010 78)`, ink `oklch(22% 0.018 48)`; every neutral carries ≥ 0.010 chroma.

## Structural · 8–9

8. **Reused structure?** No. First Hallmark run in this project (`.hallmark/log.json` was created by it). The shape is masthead → hero → §01–§05 → footer, not hero → 3 features → CTA → footer.
9. **Sections separated only by whitespace?** No. A hairline rule opens each section and draws itself in once; §02 and §05 carry heavier top padding than §01/§03/§04, so the rhythm is uneven on purpose.

## Microinteractions · 10–19

10. **`transition: all`?** No — every transition names its properties.
11. **Uniform `hover:scale-105`?** No scale hovers anywhere.
12. **Bouncy / overshoot easing?** No. Three named easings only.
13. **More than one hover effect at once?** No. Links shift colour; the submit shifts fill; the copy button shifts colour. One signal each.
14. **Animating layout properties?** No — `opacity` and `transform` only.
15. **Focus ring transitions in?** No. `:focus-visible` sets `outline-color` with no transition on `outline`.
16. **Celebratory success toast?** No toasts. The copy button swaps its own label; the form is replaced by its confirmation.
17. **Equal tooltip hover/focus delay?** No tooltips.
18. **Auto-rotating content without pause?** None.
19. **Placeholder name / startup cliché?** No. The one sample address is `you@example.com` (a reserved documentation domain), and the note sample uses the demo app's real identifiers.

## Variety · 20–21

20. **Stamp missing?** No — `src/styles/tokens.css` line 1, mirrored in `src/styles/base.css`.
21. **Specimen fall-through?** **Justified.** Specimen was named by the maintainer in `docs/epic-landing-page.md` §6.1 ("the user named the specimen tone explicitly"), which is exactly the condition the gate carves out. It was requested, not defaulted to.

## Implementation · 22–27

22. **Zero-chroma neutral?** No. Lowest chroma on the page is 0.010.
23. **Accent over ~5 % of a viewport?** No. The accent fills exactly one surface — the submit button — plus hairline underlines, the §-numbers, and the focus ring. Measured well under 3 % at every width.
24. **Off-scale spacing?** No. Every gap, pad, and margin comes from `--space-*`; the only bare values are the 4 px double-rule height and 1 px hairlines, both tokenised as `--rule-*`.
25. **Measure outside 45–75 ch?** No. `--measure: 66ch`, `--measure-narrow: 52ch`.
26. **Interactive element missing focus-visible / active / disabled?** No. The copy button, the input, and the submit each ship all eight states; typographic links ship default, hover, focus-visible, active, and a disabled variant used when the repo is private.
27. **Motion without a reduced-motion fallback?** No. The hero reveal collapses to a 150 ms opacity fade, the rule draw collapses to an opacity fade, and the §02 loop renders its poster with controls instead of autoplaying.

## Hero enrichment · 28–31

28. **Demo video autoplays with sound / lacks poster / lazy LCP?** No. The one `<video>` is `muted playsInline`, carries a `poster`, and is well below the fold with `preload="none"` — the LCP element is the hero text. The video is not yet recorded; `src/captures.ts` holds its shape and `Figure.tsx` enforces the attributes.
29. **Abstract background?** None.
30. **Icon tells (mixed libraries / emoji icons)?** **Justified.** The page ships no icon library at all. The only glyphs are the typographic arrows `↗` and `↓` inside CTA labels — U+2197 / U+2193, set in the body face, `aria-hidden`, and part of the Specimen typographic-CTA voice. They are not emoji and they are not standing in for an icon set.
31. **Lottie where CSS would do?** No animation libraries.

## Diversification · 32–33

32. **Same archetype as a previous output without knob deltas?** No previous output exists.
33. **Decorative SVG without `aria-label` / `aria-hidden`?** No. The favicon is an external asset with `role="img"` and a label; the hairline `<hr>`s are `aria-hidden="true"`; the CTA arrows are `aria-hidden="true"`.

## Layout safety · 34–36

34. **Horizontal scroll between 320 and 1920 px?** No. `overflow-x: clip` on both `html` and `body`; `scripts/responsive-check.mjs` measures `scrollWidth − innerWidth` at five widths and reports 0 at all of them.
35. **Decorative text effect mispositioned?** No highlighter bands. Link underlines are a 2 px `border-block-end` on the affordance itself; prose links use `text-decoration` at 1 px with a 2 px offset.
36. **Interactive bar not vertically centred?** No. The masthead nav, the hero CTA row, the code bar, the field row, and the footer link strip all declare `align-items: center`.

## Typography · 37–38a

37. **More than three families?** No — three: Fraunces, Newsreader, IBM Plex Mono.
38. **Outlier in more than two slots?** **Justified.** IBM Plex Mono carries one role — *machine text* — and every instance is that role: code blocks, the note-format sample, selector and API names in the term lists, section numbers, the masthead dateline, figure captions, and field labels. The rule the gate protects is "the outlier must not become a third body font"; the mono face never sets a sentence of prose here. Collapsing the dateline and the §-numbers into Newsreader would make the machine facts read as editorial voice, which is the opposite of what they are.
38a. **Italic heading or display type?** No. `h1, h2, h3` declare `font-style: normal` explicitly, the display face is loaded roman-only (no italic file is shipped), and `tests/a11y.dom.test.tsx` fails the build if an `<em>` or `<i>` appears inside a heading.

## Input states · 39

39. **Input state failures?** No, on all five sub-checks: border stays 1 px in every state; the focus ring is an `outline` reserved at `2px solid transparent` at rest; the input and the submit share `--control-height` (44 px); the helper slot reserves `min-height: 1lh` so an appearing error cannot push the page down; disabled uses opacity **and** `cursor: not-allowed` **and** the native attribute.

## Contrast · 40–41

40. **Any pair under threshold?** No. `node scripts/contrast.mjs` computes WCAG 2.1 for all 14 rendered pairs: body ink 15.69:1, muted 7.35:1, accent 5.52:1, error 6.78:1, focus ring 7.16:1, field border 3.04:1. All pass.
41. **Button text ≈ fill / missing `--color-accent-ink` / ink-on-ink?** No. `--color-accent-ink` is defined, verified at 5.69:1 against the accent, and applied on the only accent fill. No surface on the page flips dark.

## Nav · footer · hero · 42–45

42. **AI nav fingerprint?** No — N6 newspaper masthead: centred wordmark, dateline row of platform facts, two links, double rule. Not wordmark-left + link row + button-right.
43. **AI footer fingerprint?** No — Ft1 mast-headed: wordmark band, tagline, three inline links, colophon. No four-column sitemap, no social row.
44. **Hero fit?** No failure. (a) `padding-block: 4rem 6rem` — bottom is 1.5× top. (b) Verified at 1280 × 800: dateline, wordmark, nav, headline, standfirst, and both CTAs are all above the fold.
45. **Unmotivated decoration?** No. There is none — the hero is type and two links.

## Honest copy · 46

46. **Invented metric?** No. The page carries no numbers except the platform facts from `Package.swift` (macOS 15, iOS 17, Swift 6) and the version posture from `DECISIONS.md` (0.x, MIT). No testimonials, no logos, no proof bar. Where proof would normally sit, the page shows the code, the note format, and the captures.

## Re-drawn chrome · 47

47. **Fake browser / phone / code-window / IDE chrome?** No. Code blocks are a caption row, a hairline, a bare `<pre>`, a hairline — no title bar, no traffic lights. Figures are a hairline `<figure>` around a real capture. Un-recorded captures render a labelled empty plate that names the shot it is waiting for; that plate is explicitly *not* a drawn stand-in, and it is what keeps gate 46 honest while L4 is outstanding.

## Token discipline · 48

48. **Mid-render improvisation?** No. Every colour and every `font-family` on the page resolves through a token in `tokens.css`. The only sRGB literals in the repo are in `public/favicon.svg` (an external asset that cannot read custom properties — the file says so) and in `scripts/contrast.mjs` (which exists to compute those very values).

## Responsive · 49–57

49. **Two-line clickable text?** No. Every affordance carries `white-space: nowrap`; `responsive-check.mjs` measures the stacked rect height of each one at five widths and reports none wrapped.
50. **Image-bearing `1fr` track?** No. Every content grid uses `minmax(0, 1fr)`; `.figure` and `.figure__frame` carry `min-width: 0`.
51. **Display header without long-word wrap?** No. `h1, h2, h3` declare `overflow-wrap: anywhere; min-width: 0`.
52. **Section head that keeps two columns on mobile?** No. `.section__head` is `grid-template-columns: minmax(0, 1fr)` at every width — there is no per-theme override to collapse.
53. **Radio-tab scroll-jump?** No radio tabs.
54. **Eyebrow beside the heading?** **Justified — and the gate won.** The Specimen macrostructure's own sketch hangs the numbered label in a left margin, and the epic's §5 describes them as "numbered left-margin labels". Gate 54 bans that head outright and states it is not bypassable by parity instructions, so the label was flattened: `§01` sits directly above its heading in a single column. The numbering survives; the two-column head does not. The numbers themselves are permitted under the gate's carve-out (a) — the maintainer asked for section numbering explicitly — and (b) the content is genuinely ordinal: install → annotate → hand over → query → subscribe.
55. **All-caps display head below `line-height: 1.0`?** No. Nothing at display size is uppercase; the uppercase labels are `--text-xs` at `line-height: 1.3`.
56. **Two sticky elements at `top: 0`?** No sticky positioning anywhere.
57. **Studied DNA discarded?** No `study` run.

---

## Pre-emit self-critique

| Axis | Score | Note |
|---|---|---|
| **Philosophy** | 5 | The page argues one thing — show the real artefact instead of a claim about it — and every section is that argument: real snippets, the real note format, real captures, and a labelled hole where a capture is missing. |
| **Hierarchy** | 5 | One h1, five numbered sections, one accent-filled surface on the whole page. The two CTAs are the only things competing, and they are meant to. |
| **Execution** | 4 | Contrast, responsive, and a11y are machine-verified rather than eyeballed. Held back from 5 by the capture placeholders and by the initial JS sitting over the epic's budget (see below). |
| **Specificity** | 5 | Nothing here transfers to another product: the copy names `accessibilityIdentifier`, `AnnotationFormatter`, `annotation_get_pending`; the dateline is `Package.swift`'s platform floor. |
| **Restraint** | 4 | Three motion primitives, no icons, no cards, no shadows. The asymmetric spans leave large voids where a right column is short — deliberate, but at the edge of what the whitespace can carry. |
| **Variety** | 4 | First run in the project, so there is nothing to differ from; scored on structural distance from the AI default rather than from a sibling. |

No axis scored below 3; no revision pass was required on the scores.

## Known open items

Neither is a gate failure; both are recorded so they are not mistaken for finished work.

- **Captures are placeholders.** The §02 loop and the two stills are `pending` in `src/captures.ts` and render labelled plates. L4 records them from `task demo`.
- **Initial JS is 67.4 KB gzip against the epic's ~60 KB budget** (§8.5). React 19 + react-dom is 65 KB of that; the app itself is under 3 KB. Lighthouse still scores 100 for performance (LCP 0.4 s, TBT 0 ms), so this is a budget-line question, not a user-facing one. Aliasing `react`/`react-dom` to `preact/compat` was measured at **14.5 KB gzip** — a 53 KB saving with no source changes — but the epic locks React, so the swap is the maintainer's call, not a silent substitution.
