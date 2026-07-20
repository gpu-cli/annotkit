# Spike: AX point-query fidelity and selector round-trip (F0.5)

De-risks the two assumptions the macOS adapter rests on. Status: the
code-level pieces are implemented and unit-tested in F0; the live AX
point-query validation against VirgilHUD is tracked in F2.1 (it needs the
macOS adapter, which does not exist until F2).

## 1. Selector round-trip (proven in F0)

Concern from review: a generated role-path selector must encode indices the
resolver actually uses, or it will not re-resolve to the same element.

Resolution: `SelectorEngine.generate` never emits sibling-indexed role paths.
It prefers a unique `#id`, then a unique `@label`, then a single `Type[n]`
step whose `n` is the element's position among same-predicate matches in the
resolver's own preorder scope. Because `n` is defined as the resolver's match
position, re-resolving always lands on the same element. Proven by
`SelectorEngineTests.testEveryNodeRoundTrips` and the role-index case
`testGenerateRolePreorderIndexRoundTrips`.

The human-readable Element Path (sibling indices, on `Element.path`) is carried
separately for readability and is not what the agent resolves against.

## 2. Coordinate conversion (proven in F0)

The overlay captures clicks in Cocoa (bottom-left) coordinates; the AX point
query and AX frames are top-left. `ScreenSpace.flipPoint` performs the
point flip (its own inverse), and `ScreenSpace.cocoaRect(fromAXTopLeft:)`
mirrors VirgilHUD's existing rect conversion. Both spaces are in points, so no
HiDPI scaling is applied. Proven by `CoordinatesTests`.

## 3. AX point query and the annotation target rule (superseded — see DECISIONS.md)

The macOS hit-test calls `AXUIElementCopyElementAtPosition(app, x, y, &el)`,
which returns the deepest element at a screen position (cheaper than walking the
whole tree, important for a hover highlight that tracks the cursor).

> **Superseded (cli-got28.2).** This section originally specified a
> *nearest-identified-ancestor* rule: walk up to the nearest ancestor with an
> identifier or label and treat that as the target. In practice seeding is
> partial, so that rule collapsed clicks onto whichever coarse ancestor happened
> to be seeded and lost the specific element. The shipped rule is now
> **deepest actionable, else deepest meaningful**, with the *selector* (not the
> target choice) anchoring a non-identified element to its nearest identified
> ancestor. See `DECISIONS.md` → "Annotation target rule" for the authoritative
> statement, `AnnotationTargetRule` for the pure implementation, and
> `AnnotationTargetRuleTests` for the invariants. The overlay window is still
> excluded from the point query by marking it non-accessibility (it must not
> resolve to itself).
