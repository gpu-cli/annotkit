import CoreGraphics
import Foundation

/// One element considered for a marquee selection: its annotation-relevant
/// facts, its frame in AX screen coordinates (top-left origin), and its depth in
/// the source's tree (a tie-break only).
///
/// The platform adapter reads these facts once — from the AX tree on macOS, from
/// the view tree on iOS — and hands the rule a flat array. Nothing here is a live
/// platform handle, so the rule stays pure and is unit-tested without a running
/// app. Unlike ``AnnotationTargetRule``, the array is NOT an ancestor chain: a
/// marquee sweeps across siblings and unrelated subtrees, so order carries no
/// meaning beyond being the final, stability-only tie-break.
public struct MarqueeCandidate: Sendable, Hashable {
    public let element: TargetCandidate
    /// AX screen coordinates, top-left origin — the same space the drawn frame
    /// arrives in, so containment is a plain rect comparison with no conversion.
    public let frame: CGRect
    /// Distance from the source's root. Used ONLY to break ties between elements
    /// that are geometrically indistinguishable; it never outranks area, because
    /// tree depth is not a reliable proxy for "what the user drew around" (a
    /// `.background` surface is a sibling leaf, not an ancestor — see
    /// DECISIONS.md → "Component containment is GEOMETRIC").
    public let depth: Int

    public init(element: TargetCandidate, frame: CGRect, depth: Int) {
        self.element = element
        self.frame = frame
        self.depth = depth
    }

    /// Seeded = carries an `accessibilityIdentifier`. The identifier is the thing
    /// that locates source code, so at equal geometry it is the tie-break that
    /// decides whether the note is actionable for an agent.
    fileprivate var isSeeded: Bool { !element.identifier.isEmpty }

    fileprivate var area: CGFloat { frame.width * frame.height }
}

/// The marquee selection rule (see DECISIONS.md → "Marquee target rule"). The
/// user press-drags a rectangle around what they mean; given every element the
/// adapter could see, decide which one the note binds to. Pure and
/// platform-independent, the rect generalization of ``AnnotationTargetRule``:
/// adapters build `[MarqueeCandidate]` from their own node types and call
/// ``resolve(marquee:in:)``, so macOS and iOS resolve an identical drag
/// identically and the decision is unit-tested on its own.
public enum MarqueeTargetRule {
    /// How the drawn frame related to the element it resolved to. The session
    /// records it so the note can say whether the user framed a thing or framed a
    /// spot inside a thing.
    public enum Match: Sendable, Hashable {
        /// The drawn frame SURROUNDS the element.
        case surrounded
        /// The frame was drawn INSIDE this element (nothing was surrounded).
        case enclosing
    }

    public struct Resolution: Sendable, Hashable {
        /// Index into the `candidates` array passed to ``resolve(marquee:in:)``.
        public let index: Int
        public let match: Match

        public init(index: Int, match: Match) {
            self.index = index
            self.match = match
        }
    }

    /// Fraction of a candidate's own area that the drawn frame must cover for the
    /// frame to count as surrounding it.
    ///
    /// Not 1.0: a hand-drawn rect clips edges. Users drag roughly around a card
    /// and routinely shave a few points off a corner or slice through the
    /// trailing chevron, and a strict-containment rule would silently demote that
    /// to the enclosing fallback — the exact failure the feature exists to avoid.
    /// 0.85 tolerates that sloppiness while still being far above the coverage a
    /// neighbouring card picks up when a drag merely overlaps its edge.
    public static let containmentThreshold: CGFloat = 0.85

    /// The candidate a drawn frame binds to, or nil when the frame contains
    /// nothing annotatable and does not sit inside anything annotatable — the
    /// caller then falls back to a region note anchored near the frame, the same
    /// way a point that hit-tests to nothing does.
    ///
    /// Two passes, in order:
    ///
    /// 1. **Surrounded.** Every eligible candidate the frame covers to at least
    ///    ``containmentThreshold`` of its own area; the LARGEST wins. Largest-wins
    ///    IS the feature: framing something means "I mean this whole thing", so
    ///    the card must beat the labels and buttons drawn inside it. (The point
    ///    rule does the opposite — deepest-wins — because a click means "I mean
    ///    this exact spot". Same tree, opposite intent, hence a separate rule.)
    /// 2. **Enclosing.** Nothing was surrounded, so the user drew INSIDE
    ///    something: keep the eligible candidates whose frame contains the whole
    ///    drawn rect and take the SMALLEST, the tightest enclosure being the most
    ///    specific. This is the rect generalization of the point-region path — a
    ///    scribble over a card's padding binds to the card, not to the
    ///    window-spanning panel that also contains it.
    ///
    /// Ties inside each pass are broken by seeding, then depth, then index; see
    /// ``isStrictlyBetterSurrounded(_:than:)``.
    public static func resolve(marquee: CGRect, in candidates: [MarqueeCandidate]) -> Resolution? {
        // A right-to-left or bottom-to-top drag arrives with negative width or
        // height, where `contains`/`intersection` degenerate. Normalize once and
        // use only the normalized rect below, so drag direction cannot change the
        // answer.
        let rect = marquee.standardized
        // A click that never moved, or a drag along a single axis, is not a
        // marquee. Rejecting it here keeps the caller from binding a note to
        // whatever happens to enclose a zero-area rect (which is everything).
        guard rect.width > 0, rect.height > 0 else { return nil }

        let eligible = candidates.indices.filter { i in
            let candidate = candidates[i]
            // The positive-area check is load-bearing twice over: it keeps a
            // degenerate frame out of the coverage ratio's DENOMINATOR (0/0 is
            // NaN, and every NaN comparison is false, so such a candidate would
            // poison the fold in ways that depend on iteration order), and a
            // zero-area element is nothing the user could have aimed at anyway.
            return candidate.element.isEligibleMeaningful && candidate.frame.width > 0 && candidate.frame.height > 0
        }

        if let winner = fold(eligible, in: candidates, keeping: { candidate in
            let overlap = candidate.frame.intersection(rect)
            // Disjoint rects intersect to `.null`, whose size is zero — so the
            // ratio is 0 and the candidate falls out, no special case needed.
            return (overlap.width * overlap.height) / candidate.area >= containmentThreshold
        }, preferring: isStrictlyBetterSurrounded) {
            return Resolution(index: winner, match: .surrounded)
        }

        if let winner = fold(eligible, in: candidates, keeping: { $0.frame.contains(rect) },
                             preferring: isStrictlyBetterEnclosing) {
            return Resolution(index: winner, match: .enclosing)
        }

        return nil
    }

    /// Ascending-index fold that replaces the incumbent ONLY on a strict
    /// improvement — which is what makes "earlier index" the final tie-break.
    /// `max(by:)`/`min(by:)` are deliberately not used: for elements the predicate
    /// calls equal they make no first-wins guarantee, so a total tie between two
    /// coextensive candidates would resolve by implementation detail and the same
    /// drag could bind to different elements on different runs.
    private static func fold(
        _ indices: [Int],
        in candidates: [MarqueeCandidate],
        keeping isKept: (MarqueeCandidate) -> Bool,
        preferring isStrictlyBetter: (MarqueeCandidate, MarqueeCandidate) -> Bool
    ) -> Int? {
        var best: Int?
        for i in indices where isKept(candidates[i]) {
            guard let incumbent = best else {
                best = i
                continue
            }
            if isStrictlyBetter(candidates[i], candidates[incumbent]) { best = i }
        }
        return best
    }

    /// Strict weak ordering for pass 1 — true only when `lhs` is genuinely better,
    /// never for equivalent candidates:
    ///
    /// 1. **Larger area.** See ``resolve(marquee:in:)``: framing means "this whole
    ///    thing".
    /// 2. **Seeded beats unseeded**, at EXACTLY equal area. This exists for the
    ///    dominant VirgilHUD pattern: `.axCardSurface(id)` hangs the card's
    ///    `accessibilityIdentifier` on a clear `Color.clear` background leaf that
    ///    is exactly coextensive with the card's content group. A frame drawn
    ///    around the card surrounds both equally, and only the seeded one carries
    ///    the identifier that locates the code.
    /// 3. **Shallower**, then 4. **earlier index** (the fold's replace-on-strict
    ///    -improvement rule): geometry and seeding have run out, and these exist
    ///    only so the same drag always resolves to the same element.
    ///
    /// Areas are compared with exact `==`, no epsilon. The equal-area case that
    /// matters is a background surface and its content group computed from the
    /// SAME layout frame, so the arithmetic is bit-identical;
    /// `AXIntrospection.deepestChild` already relies on exact equal-area
    /// comparison for precisely this pattern and shipped after dogfooding. An
    /// epsilon would instead start collapsing genuinely different, merely
    /// similar-sized elements into a tie decided by seeding.
    private static func isStrictlyBetterSurrounded(_ lhs: MarqueeCandidate, than rhs: MarqueeCandidate) -> Bool {
        if lhs.area != rhs.area { return lhs.area > rhs.area }
        if lhs.isSeeded != rhs.isSeeded { return lhs.isSeeded }
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        return false
    }

    /// Strict weak ordering for pass 2, the mirror of
    /// ``isStrictlyBetterSurrounded(_:than:)``: smaller wins (the tightest
    /// enclosure is the most specific), then seeded, then DEEPER — deeper being
    /// the tightest-enclosure tie-break, consistent with preferring the smaller
    /// frame — then earlier index. Seeding still outranks depth for the same
    /// coextensive-surface reason: the surface leaf and the content group enclose
    /// the drawn rect identically, and the identifier is what the agent needs.
    private static func isStrictlyBetterEnclosing(_ lhs: MarqueeCandidate, than rhs: MarqueeCandidate) -> Bool {
        if lhs.area != rhs.area { return lhs.area < rhs.area }
        if lhs.isSeeded != rhs.isSeeded { return lhs.isSeeded }
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
        return false
    }
}
