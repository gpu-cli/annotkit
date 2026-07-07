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

    /// Resolve a screen point (AX top-left coordinates) to the deepest element
    /// under it, walked up to the nearest ancestor that carries a stable
    /// identity. Returns nil when nothing resolves.
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
