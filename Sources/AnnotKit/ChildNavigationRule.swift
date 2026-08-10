import CoreGraphics
import Foundation

/// One element considered as a CHILD of the currently-bound target: its
/// annotation-relevant facts and its frame in the source's screen space (AX
/// top-left on macOS, view-local on iOS — the same space the hint arrives in, so
/// containment is a plain rect test with no conversion).
///
/// The platform adapter reads these facts once — from the AX tree on macOS, from
/// the view tree on either platform — and hands the rule a flat array, so nothing
/// here is a live platform handle and the ordering is unit-tested without a
/// running app. Deliberately NOT ``MarqueeCandidate``: depth is meaningless for a
/// single generation of siblings, and reusing a struct with a field the rule must
/// ignore invites a future tie-break reading it.
public struct ChildCandidate: Sendable, Hashable {
    public let element: TargetCandidate
    public let frame: CGRect

    public init(element: TargetCandidate, frame: CGRect) {
        self.element = element
        self.frame = frame
    }

    /// Seeded = carries an `accessibilityIdentifier`. The identifier is what
    /// locates source code, so at the same geometric standing it decides whether
    /// descending produces a note an agent can act on.
    fileprivate var isSeeded: Bool { !element.identifier.isEmpty }

    fileprivate var area: CGFloat { frame.width * frame.height }
}

/// The child-navigation ordering rule: given every child the adapter could see
/// under the bound element, decide which one "Select Child" should descend into.
/// Pure and platform-independent, the downward counterpart of
/// ``AnnotationTargetRule`` — all three adapters (macOS AX, macOS view-tree, iOS)
/// build `[ChildCandidate]` from their own node types and call ``order(_:near:)``,
/// so a descent resolves identically everywhere and the decision is tested on its
/// own rather than by three hand-rolled sorts kept in step by hand.
public enum ChildNavigationRule {
    /// Indices into `candidates`, most-likely-intended FIRST; ineligible entries
    /// are dropped entirely, so an empty result means "leaf, nothing to descend
    /// into".
    ///
    /// Ranking, in order:
    ///
    /// 1. **Contains the hint.** `hint` is the gesture's own anchor — the point
    ///    clicked, or the centre of the frame drawn. When one child sits under it
    ///    that child is the one the user was already pointing at, which beats any
    ///    guess made from geometry alone.
    /// 2. **Seeded beats unseeded.** Descending into an unseeded child yields a
    ///    note whose `component` has to be inherited from an ancestor; descending
    ///    into a seeded one names a component directly.
    /// 3. **Larger area.** Going DOWN one level should land on the substantial
    ///    thing inside (the card's content row), not the 8pt chevron that happens
    ///    to be its first sibling — the same "I mean this whole thing" instinct
    ///    ``MarqueeTargetRule``'s surrounded pass encodes, applied one level down.
    /// 4. **Earlier index**, so the same selection always descends the same way.
    ///    `sorted(by:)` is not stable, so this is an explicit key rather than an
    ///    assumption: without it two coextensive children would swap places
    ///    between runs and repeating a descent could land somewhere new.
    ///
    /// Eligibility is ``TargetCandidate/isEligibleMeaningful``, the SAME predicate
    /// the target rule uses, so window chrome, container roots, and window-ghost
    /// groups can never be offered as children — descending into any of them binds
    /// the note to something that names no app code.
    public static func order(_ candidates: [ChildCandidate], near hint: CGPoint?) -> [Int] {
        candidates.indices
            .filter { i in
                // Positive area twice over: a zero-area child is nothing the user
                // could have meant, and it would otherwise sort last-but-present
                // and be offered as a descent target on a leaf.
                candidates[i].element.isEligibleMeaningful
                    && candidates[i].frame.width > 0 && candidates[i].frame.height > 0
            }
            .sorted { lhs, rhs in
                let (l, r) = (candidates[lhs], candidates[rhs])
                let lHit = hint.map(l.frame.contains) ?? false
                let rHit = hint.map(r.frame.contains) ?? false
                if lHit != rHit { return lHit }
                if l.isSeeded != r.isSeeded { return l.isSeeded }
                if l.area != r.area { return l.area > r.area }
                return lhs < rhs
            }
    }
}
