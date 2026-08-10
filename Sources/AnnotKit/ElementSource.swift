import CoreGraphics

/// The strategy that discovers UI elements and turns a click point into an
/// ``Element``. Two adapters implement it (the design's central fork, see
/// DECISIONS.md):
///
/// - the macOS accessibility source (default), which queries the app's own AX
///   tree and is the only strategy that surfaces SwiftUI `accessibilityIdentifier`
///   values, and
/// - the view-tree source (opt in), which walks `NSView`/`UIView` directly and
///   surfaces concrete view class names, richer for AppKit/UIKit hosts.
///
/// All members are main-actor isolated because AX and view-hierarchy access must
/// run on the main thread. `screenshot(of:)` is async because the macOS capture
/// path awaits ScreenCaptureKit. Returned types are all `Sendable`, so no live
/// platform handle escapes the adapter.
@MainActor
public protocol ElementSource {
    /// Snapshot every inspectable window and its element tree.
    func snapshot() -> [WindowSnapshot]

    /// Resolve a screen point (AX top-left coordinates) to the annotation target
    /// under it, per the unified target rule (see DECISIONS.md): the deepest
    /// ACTIONABLE control at the point, else the deepest MEANINGFUL element
    /// (identifier / label / value / action), never the window, application,
    /// chrome, or a structural window-spanning group. Returns nil when nothing
    /// resolves (a `RegionAnchorSource` can then anchor the click to a nearby
    /// element instead of dropping it). The returned element's ``Element/path``
    /// carries its identified ancestors, which the selector engine anchors to.
    func hitTest(_ point: CGPoint) -> Element?

    /// Generate the most-stable, round-tripping selector string for an element.
    func selector(for element: Element) -> String

    /// Capture a PNG of an element, or the key window when `element` is nil.
    func screenshot(of element: Element?) async throws -> CapturedImage
}

/// Optional element-source capability: resolve the nearest MEANINGFUL element
/// to a point that hit-tests to NOTHING (decoration, dividers, gaps beyond any
/// container's frame), so the session can capture a REGION note anchored to
/// that element instead of dropping the click. Sources that cannot offer this
/// simply don't conform; the session degrades to the old drop-the-click
/// behavior.
@MainActor
public protocol RegionAnchorSource {
    func regionAnchor(at point: CGPoint) -> Element?
}

/// Optional element-source capability: the component-widening ladder at a point —
/// the annotation target first (same element ``ElementSource/hitTest(_:)``
/// returns), then each enclosing identified component, broadest last. Lets the
/// session step a selection UP to a parent component for a coarser-grained note
/// (the composer's Select Parent control) without re-hit-testing. Sources that
/// cannot offer it simply don't conform; the session then has a single-rung
/// selection path and Select Parent stays disabled.
@MainActor
public protocol ComponentLadderSource {
    func componentLadder(at point: CGPoint) -> [Element]
}

/// Optional element-source capability: the meaningful children of an element —
/// the DOWNWARD counterpart of ``ComponentLadderSource``. Lets the session step a
/// selection INTO a component (the row inside the card, rather than the card) when
/// the user overshot, or when the target rule bound coarser than they meant.
/// Sources that cannot offer it simply don't conform; the session then leaves the
/// composer's Child control permanently disabled, and only upward navigation (and
/// downward navigation back through already-visited rungs) is available.
@MainActor
public protocol ChildNavigationSource {
    /// Meaningful children of `element`, most-likely-intended FIRST. `hint` is the
    /// gesture's anchor (the click point, or the drawn frame's centre) when there
    /// is one. Empty when the element is a leaf.
    ///
    /// Ordering is the shared, pure ``ChildNavigationRule`` on every adapter, so
    /// the same layout descends the same way on macOS and iOS. Implementations
    /// MUST NOT snapshot the whole tree per call: this runs on every selection
    /// change, and the bound element's frame centre gives a cheap descent path from
    /// the containing window (the same trick the hit-test uses).
    func children(of element: Element, near hint: CGPoint?) -> [Element]
}

/// Optional element-source capability: resolve a frame the user DREW (a marquee
/// press-drag) to an annotation target, per ``MarqueeTargetRule`` — the largest
/// meaningful element the frame surrounds, else the tightest element the frame
/// was drawn inside. Lets the user say "I mean this whole card" by circling it
/// rather than hunting for the one pixel that hit-tests to the card. Sources that
/// cannot offer it simply don't conform; the session then leaves marquee
/// selection off and only point selection is available.
@MainActor
public protocol MarqueeTargetSource {
    /// The annotation target for a frame the user DREW (AX top-left screen
    /// coordinates), with its component-widening ladder: the target first, then
    /// each enclosing identified component, broadest last — the SAME contract as
    /// ``ComponentLadderSource/componentLadder(at:)``, so the session's existing
    /// ladder handling (widening, and the note's `component` field) works
    /// unchanged. Empty when nothing in the frame is annotatable; the session
    /// then falls back to a region note anchored near the frame.
    func marqueeLadder(in rect: CGRect) -> [Element]
}
