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
| Marquee target rule | Largest meaningful element ≥85% surrounded; else the tightest element enclosing the drawn frame | Rect selection, the deliberate inverse of the point rule's deepest-wins. See below. |
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

## Marquee target rule (VRT-cne0.5)

The user press-drags a rectangle around what they mean. Given every element the
adapter can see (a flat array, not an ancestor chain — a marquee sweeps across
siblings and unrelated subtrees), the note binds by two passes over the
*standardized* rect, using the same eligibility as the point rule (never the
window, the application, chrome, or a window-spanning ghost group, and never a
zero-area frame):

1. **Surrounded** — every eligible element the frame covers to ≥85% of that
   element's OWN area; the **largest** wins.
2. **Enclosing** — nothing was surrounded, so the frame was drawn inside
   something: every eligible element whose frame contains the whole rect; the
   **smallest** wins.
3. Neither — nil, and the session falls back to a region note anchored near the
   frame, exactly as a point that hit-tests to nothing does.

Ties inside a pass: seeded beats unseeded, then shallower (surrounded) / deeper
(enclosing), then lowest index. Areas compare with exact `==`, no epsilon.

**Why largest-wins**, when the point rule is deepest-wins? Because the gestures
mean opposite things. A click means "this exact spot", so it descends. Drawing a
box around a card means "I mean this *whole* thing", so it must ascend past the
labels and buttons the box also swallowed. Same tree, opposite intent — hence a
separate rule rather than a mode flag on `AnnotationTargetRule`.

**Why 0.85 and not strict containment.** A hand-drawn rect clips edges. Users
drag roughly around a card and routinely shave a corner or slice through a
trailing chevron; at 1.0 that silently demotes to the enclosing fallback and
binds the note to the panel instead of the card — the exact failure marquee
exists to remove. 0.85 absorbs that sloppiness and still sits far above the
coverage a neighbouring card picks up when a drag merely overlaps its edge.

**Why seeded-beats-unseeded exists at all.** It is not a general preference for
identified elements (that is the mistake the point rule documents above). It is
narrowly for the coextensive case: `.axCardSurface(id)` hangs the card's
identifier on a clear `Color.clear` background leaf that is *exactly* the same
frame as the card's content group. Both are surrounded identically, and only the
seeded one carries the identifier that locates code. `AXIntrospection.deepestChild`
already resolves this same pattern by exact equal-area comparison, which is why
no epsilon is used here — the two frames come from one layout computation, so the
arithmetic is bit-identical, and an epsilon would instead start collapsing
genuinely different elements into a seeding decision.

**Why the enclosing fallback.** It is the rect generalization of the point-region
note (rule 5 above): a scribble over a card's padding surrounds nothing, and
dropping it would be the same lost-click bug `RegionAnchorSource` was added to
fix. Smallest-wins there because the tightest enclosure is the most specific — a
scribble inside a card must not resolve to the window-spanning panel that also
contains it.

Depth and index are determinism-only tie-breaks; they exist so the same drag
always resolves to the same element. The pure decision lives in
`MarqueeTargetRule` and is unit-tested independent of AX; adapters expose it via
the optional `MarqueeTargetSource` capability, which returns a component-widening
ladder identical in contract to `ComponentLadderSource`, so widening and the
note's `component` field work unchanged.

## IP hygiene (carried into the F7 legal gate)

- Do not copy original Agentation source (PolyForm Shield 1.0.0, non-compete). Only the `AGENTATION_NOTES.md` file format is reused, reimplemented clean-room.
- The iOS adapter is a clean-room UIKit view-tree walker (`IOSElementSource`), not a vendored dependency. It reuses the shared selector engine, consistent with the one-engine / no-fork design, and carries no third-party code or license obligations.
