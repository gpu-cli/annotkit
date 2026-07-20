# AnnotKit foundation decisions (F0)

Resolves the open decisions from the plan (planning/annotkit in the cli repo). Provisional items are cheap to change before the public release.

| Decision | Choice | Notes |
|---|---|---|
| Name | AnnotKit (provisional) | Trademark check required before public release. Distinct from Agentation (PolyForm, brand). |
| License | MIT | Maximises adoption. See LICENSE. |
| Repo location | Standalone repo at `~/Development/annotkit` | VirgilHUD consumes it during dev via a local SwiftPM path dependency; public remote created by the maintainer. |
| Versioning | SemVer, 0.x pre-1.0 | Breaking changes allowed while 0.x; 1.0 marks a stable public API. |
| Default element source | Accessibility hierarchy | The only strategy that surfaces SwiftUI `accessibilityIdentifier` values. |
| Annotation target rule | Deepest actionable, else deepest meaningful; anchor the selector to the nearest identifier | One rule on both platforms. Supersedes the earlier macOS "deepest meaningful" and iOS "nearest identified" split. See below. |
| Opt-in element source | View tree (NSView/UIView) | Surfaces concrete view class names; richer for AppKit/UIKit hosts. Collapses to hosting views in pure SwiftUI. |
| `pathname` mapping | Host-supplied route, inferred fallback | A native app has no URL routes; the host sets a route, else infer from the key window title or identifier. |
| Overlay coverage | Primary screen (MVP) | The overlay covers the primary display; SwiftUI-local points map to AX screen coordinates there. Full multi-display placement is deferred (cli-a99qm.4.2). |
| Dev-only gating | `#if DEBUG` default + env override | On in DEBUG unless `ANNOTKIT_DISABLE`; off in release unless `ANNOTKIT_ENABLE`. Mirrors VirgilHUD `InspectMode`. |
| MCP bridge in v1 | Deferred to F6 (optional) | The file and clipboard sinks cover the agent loop; the MCP/HTTP bridge is an optional later target, not part of the 1.0 critical path. |
| Concurrency | Swift 6 language mode, strict | Public `Element`/`CapturedImage`/`AnnotationNote` are `Sendable`; `ElementSource`/`Annotation` are `@MainActor`. |

## Annotation target rule (cli-got28.2)

A click must isolate the component the user meant and produce a selector that
locates its code. One rule, both platforms:

1. Hit-test to the deepest node at the point, then walk its ancestor chain.
2. **Target = the deepest ACTIONABLE control** in the chain (button, link,
   checkbox, popup, slider, menu item, or anything exposing `AXPress`). A click
   anywhere inside a button binds to the button, not the static-text glyph that
   happens to be its deepest descendant.
3. Else **target = the deepest MEANINGFUL element** — one carrying an identifier,
   a label, or a displayed value. A standalone `Text` inside a card is annotated
   in its own right (the card is not actionable, so it does not swallow the
   text); the selector engine then anchors it to the card's identifier.
4. Never a target: the window, the application, window chrome (traffic lights),
   or a structural, unidentified, content-less group that spans (nearly) the
   whole window (an `NSHostingView` root `AXGroup` — the window in disguise).
5. When the point hits nothing annotatable (decoration, dividers, padding beyond
   any frame), a `RegionAnchorSource` anchors the click to the nearest meaningful
   element as a REGION note rather than dropping it.

Why not "prefer the deepest *identified* ancestor"? Because seeding is partial: a
button may be seeded but a standalone text inside a seeded card is usually not.
Preferring the identified container would collapse every click inside a card onto
the card and lose the specific element. Preferring the actionable/meaningful leaf
and letting the SELECTOR anchor to the nearest identifier (`#Card >> text="…"`)
keeps both the specificity and the code-locating anchor. Selection *widening*
(cli-got28.2.3) exists for the times the user does want the enclosing component.

This replaces the earlier asymmetry (macOS "deepest meaningful", iOS "nearest
identified") documented in `docs/spike-ax-pointquery.md`, now corrected. The pure
decision lives in `AnnotationTargetRule` and is unit-tested independent of AX.

### Component containment is GEOMETRIC, not tree-ancestry (cli-got28.2)

"Which component encloses this element" is resolved by frame containment, not by
walking the AX parent chain. A SwiftUI card seeded with `.axCardSurface` (the
dominant VirgilHUD pattern) is a clear `Color.clear` background leaf carrying the
identifier — and `.background` makes it a **sibling of the card's content, not an
ancestor**. So the card's identifier never appears in the content's ancestor
chain, and pure-ancestry anchoring/widening cannot reach it (it only worked for
`.accessibilityElement(children: .contain)` containers, which *are* ancestors).

The macOS `componentLadder` therefore collects every identified element whose
frame **encloses the point** and is larger than the target, smallest-first —
scanning the ancestor chain plus each ancestor's direct children (where those
background surfaces live), so it reaches sibling card surfaces without a full
snapshot. This ladder drives selection widening and the note's `component` field.
Selector *anchoring* (`#Card >> …`) still requires a true ancestor because the
`>>` operator is descendant-based; when the component is a sibling surface the
selector may be positional or text-based while the `component` field still names
the card, so the note locates the right code either way.

## IP hygiene (carried into the F7 legal gate)

- Do not copy original Agentation source (PolyForm Shield 1.0.0, non-compete). Only the `AGENTATION_NOTES.md` file format is reused, reimplemented clean-room.
- The iOS adapter is a clean-room UIKit view-tree walker (`IOSElementSource`), not a vendored dependency. It reuses the shared selector engine, consistent with the one-engine / no-fork design, and carries no third-party code or license obligations.
