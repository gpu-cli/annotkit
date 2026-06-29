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

## 3. AX point query and nearest-identified-ancestor rule (design; live proof in F2.1)

The macOS hit-test will call `AXUIElementCopyElementAtPosition(app, x, y, &el)`,
which returns the deepest element at a screen position (cheaper than walking the
whole tree, important for a hover highlight that tracks the cursor).

Caveat: the deepest element can be finer than the nearest element that carries a
seeded `accessibilityIdentifier` (for example a text glyph inside a labelled
button). Rule: after the point query, walk up `kAXParentAttribute` to the
nearest ancestor that has a non-empty identifier or a stable label, and treat
that as the annotation target; keep the deepest element only for the Element
Path. The overlay window is excluded from this query by marking it
non-accessibility (it must not resolve to itself).

This rule is documented here and implemented + validated live against VirgilHUD
in F2.1 via `hud-inspect`.
