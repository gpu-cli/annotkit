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
| Selection navigation | Bidirectional Parent/Child over one path; descent replays history and only queries the source at the deepest rung | Replaces the one-way "Widen". Prepending the frontier child shifts every rung, so a note's `component` is the first SEEDED rung above the BOUND one. Whether the parent chain stays seeded-only is OPEN. See below. |
| Frame mode anchoring | The frame the user DREW anchors the overlay until they navigate; the resolved element is NAMED in the composer, not drawn on the canvas | Hover is point-mode-only, gated in the session rather than the view. See below. |
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

## Selection navigation (VRT-mijf.1)

The composer's one-way "Widen" button is replaced by Parent and Child over a
single path: index 0 is the deepest rung known so far, ascending indices are
progressively broader, and one index marks the rung the note is bound to.

The rename is not cosmetic. "Widen" named the MECHANISM — the highlighted area
gets bigger — when the act is choosing which component the note is filed against.
A button that makes things bigger implies no inverse, so a user who overshot, or
whom the target rule bound coarser than they meant, had nothing to press.

**Descent prefers HISTORY over re-querying.** Above the deepest rung, Child just
steps the index back down what the user climbed. Only AT the deepest rung does it
ask the source for children, and it then PREPENDS the one it takes, so index 0
still means "deepest known rung". Re-querying on every press would be less code
and wrong: the source's answer is a heuristic over a LIVE tree, so a hover state
resolving or a list reflowing between two presses makes the same key produce a
different result. Prepending is what makes the round trip hold in BOTH
directions — after descending to child C, Parent returns to the original target
and Child returns to C ITSELF rather than re-running the heuristic against a tree
that has moved on.

**The consequence that bit us.** Prepending shifts every existing rung up one, so
"the note's `component` is the rung above the target" stopped being true: index 1
is now the ORIGINAL target, which is frequently unseeded. `component` is
therefore the first SEEDED rung strictly above the BOUND rung, and it is read
from that rung's IDENTIFIER, never from its `Element.id`. An unseeded element's
`id` is a slash-joined path (`AXWindow[0]/AXGroup[0]/AXStaticText[1]`); exported
as a `component` it hands the consuming agent a grep target that matches nothing
while looking entirely plausible in the note — a silent miss, not a visible one.
The same path is rooted differently depending on which entry point produced the
element (`snapshot()` roots at the window, the hit-test and marquee paths at the
application), so the id is not even stable for one node, which is a second reason
it can never be a code locator.

**Open, pending dogfood: should the parent chain stay seeded-only?** It is today —
every rung above the target is an identified component, so every rung locates
code and no press can bind a note to something that names nothing. The cost is
that it skips structural levels the user can SEE: a row inside an unseeded stack
offers no rung for the stack, so Parent jumps from the row straight to the card
and the level the user was aiming at is unreachable. Admitting unseeded rungs
would fix the navigation and degrade the notes. Which failure is worse is not
decidable from the design; it needs real use, so this is recorded as unresolved
rather than settled.

## Frame mode anchoring (VRT-mijf.2)

When a drawn frame resolves to a real element, the overlay anchors its highlight,
composer and pin to the FRAME the user drew — not to the element — until the user
presses Parent or Child, at which point the bound element becomes the anchor and
the frame stays on screen, dimmed.

**Why the frame outranks the resolved element.** The user drew a box, so the box
is the truth of the selection until they say otherwise. Anchoring to the
resolution instead makes the rectangle vanish the instant the mouse comes up and
the highlight snap to a card that was never swept, which reads as the tool having
ignored the gesture.

**Why the element is NAMED rather than DRAWN.** A note must never be captured
against a target the user could not see, so the binding has to appear somewhere.
But a second rectangle on the canvas is exactly what "show me only the frame I
drew" rules out, and two boxes of different shapes leave it ambiguous which one
the note records. The composer header carries the name behind a `Frame →` prefix,
so it reads as what the frame RESOLVED to rather than as a label for the
rectangle, and the prefix disappears the moment navigation puts a named element
back on the canvas — the name is never qualified in two places at once.

**Why navigating reveals the element.** Pressing Parent or Child IS the question
"which element is this filed against?", so the answer has to become visible;
moving the binding while the highlight stays on the drawn rect would give no
feedback at all. The frame survives, weaker, because it is still what the note
records (`regionRect`) even once it no longer decides the binding.

**Why hover is gated in the SESSION, not the view.** Frame mode selects from a
swept rectangle, so a hover highlight there advertises a click-selection no press
in that mode can produce — the dogfooding report was a whole card lit up with its
name tag while nothing had been drawn. The view keeps its own guard for the
narrower during-the-drag case; the MODE gate belongs one level down because there
it is unit-testable without a window, no future UI path can reintroduce it, and
it removes a cross-process AX hit-test per pointer-motion event. It is a cost
decision as much as a visual one.

## Recallable selection marks (VRT-pm3k)

A captured frame is **recalled, not painted**. Filing a note leaves the surface
exactly as it looked before marks existed; the geometry comes back only while the
user is attending that note — resting the pointer on its numbered pin, or having
its edit card open. "Maintain the highlighted area" is therefore read as *keep it
recoverable*, not *keep it drawn*.

**Why not an always-on marks layer.** It was the first design and hover-recall
beats it on three counts that all show up after the third or fourth note: no stack
of overlapping rectangles, no competition with the live highlight over what the
next press binds to, and no permanent field of stale geometry after a scroll. It
also makes the layer affordable — because exactly one mark is ever on screen, it
can wear the full committed-frame treatment (solid stroke plus the wash) instead
of the thin dimmed strokes stacking would have forced, so a recalled note looks
like the selection it was made from.

**Why the note stores two RECTS and derives nothing.** `anchor` was a POINT, so an
element note had no size at all and could not be redrawn. The only derivation
available — `anchor` + `regionRect.size` — is wrong exactly where it matters:
pressing Parent/Child clears the frame anchor, so the anchor becomes the ELEMENT's
origin while the size is still the swept one, producing a right-sized box in the
wrong place. `anchorRect` (what was highlighted at capture) and `drawnRect` (what
was swept) are stored side by side, which also turns "area or element?" into a
field lookup instead of an equality between rects measured in different spaces.
Both are UI-only and stay out of `CodingKeys`: the JSON, the MCP payload and the
markdown are byte-for-byte unchanged.

**Why recall is GEOMETRIC rather than the pin's own hover.** Pins go inert in
frame mode (below), and a view with `allowsHitTesting(false)` receives no hover —
so the trigger cannot live on the pin. `PinAttentionRule` answers "which note's pin
contains this point?" from the catcher's own hover, in both modes: one mechanism
instead of two that can drift, and "hover reveals mark N" becomes a unit test
rather than something a human checks with a mouse. Its radius is deliberately
LARGER than the pin, and that is load-bearing rather than generous: in point mode
the pin is a live button above the catcher, so the only points near a pin the
catcher ever sees are the ones outside it. Attention is established on the way in
and stands until another point answers differently, which is also why hover-exit
needs no rule of its own.

**Why an open edit card outranks the pointer.** Attended means *hovered or open in
the card*, and when the two disagree the card wins — the opposite of the intuitive
order. A card NAMES its note in words, so a mark belonging to a different note puts
two answers on screen at once; and the hover it overrules is not always current,
because in point mode the pin is a live button above the catcher, so a pointer that
reaches a pin without crossing the surface first (a fast flick, re-entering the
window) leaves the catcher's last answer pointing at the pin it saw before.
Observed exactly that way during the visual check — the card read note 1 while the
canvas drew note 3.

**Why pins are inert in frame mode.** `AnnotationPin` is a `Button` mounted above
the catcher, so a press starting on one never reaches the drag gesture — and every
capture plants one exactly where the next frame is most likely to be drawn. That,
plus hover-to-edit dropping a ~284x172 card under the pointer, is the reported "if
I select an element I cannot also use the frame tool". In frame mode the user is
drawing, not editing, so one condition removes both with no gesture negotiation.
Measured both ways in the probe (11c): the same synthesized press opens the editor
in point mode and does nothing in frame mode.

**The composer covering its own element is ACCEPTED.** A card the user may be
typing into must consume its own clicks; dismissing it or starting the drag from
outside it are the ordinary mitigations. Unlike a pin, it has state to lose.

### The toolbar panel claims its whole frame (measured, VRT-pm3k.7)

The permanently-mounted toolbar panel is 240x104 with the pill in its bottom-right
corner, and it consumes presses across the **whole** rect — so the host's
bottom-right 240x104 is inert to clicks and to the start of a frame drag, in both
modes.

This was listed as candidate (d) on the assumption that per-pixel alpha
pass-through would save it. It does not: measured against a panel whose content
view was a bare `NSView` drawing nothing at all, with `isOpaque = false` and a
clear background, the click was still swallowed. macOS does not route mouse events
through the transparent parts of a window; `ignoresMouseEvents = true` is the only
configuration that lets them through, and it would take the pill's own clicks with
it. `AnnotKitOverlayProbe` phase 11a pins the behaviour with a real posted click,
against a control click on the catcher so a null result means something.

Not fixed here, deliberately: the remedy is to size the panel to the pill, which
changes the design `be624b4` landed (a fixed-size panel whose frame moves for
exactly one reason), and this epic's job was to settle the question. Tracked
separately.

### Recall survives a scroll, best-effort and no further (macOS)

While annotating, the overlay owns every wheel event — `KeyablePanel.scrollWheel`
drives the host scroller's clip itself — so the exact translation applied to the
content is known at the moment it is applied, and the notes over that scroller are
translated with it. The translation is measured as the DIFFERENCE in the document
view's own position rather than computed from the deltas, so it is right for a
flipped or unflipped document and for a scroll clamped at either end.

The limits are stated rather than implied: scrolls the overlay does not originate
— keyboard paging, programmatic `scrollToVisible`, anything at all while the menu
is closed — are not observed, and no AX re-resolution is attempted. Notes are
selected by their rect's CENTRE falling inside the scroller's viewport, so a frame
drawn slightly proud of a card still travels with it while chrome outside the
scroller stays put. macOS-only: `UIScrollView` is not intercepted on iOS.

## IP hygiene (carried into the F7 legal gate)

- Do not copy original Agentation source (PolyForm Shield 1.0.0, non-compete). Only the `AGENTATION_NOTES.md` file format is reused, reimplemented clean-room.
- The iOS adapter is a clean-room UIKit view-tree walker (`IOSElementSource`), not a vendored dependency. It reuses the shared selector engine, consistent with the one-engine / no-fork design, and carries no third-party code or license obligations.
