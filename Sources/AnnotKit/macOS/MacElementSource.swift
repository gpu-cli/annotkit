#if os(macOS)
import CoreGraphics

/// The default macOS ``ElementSource``: the accessibility-hierarchy strategy.
/// Queries the host app's own AX tree (the only strategy that surfaces SwiftUI
/// `accessibilityIdentifier` values), resolves a click to an element via the AX
/// point query, generates a round-tripping selector with the shared
/// ``SelectorEngine``, and captures element screenshots. The view-tree opt-in
/// strategy is a separate source (F2.5).
@MainActor
public final class MacElementSource: ElementSource {
    public init() {}

    public func snapshot() -> [WindowSnapshot] {
        AXIntrospection.snapshot()
    }

    public func hitTest(_ point: CGPoint) -> Element? {
        AXIntrospection.hitTest(point)
    }

    public func selector(for element: Element) -> String {
        AXIntrospection.selector(for: element)
    }

    public func screenshot(of element: Element?) async throws -> CapturedImage {
        try AXScreenshot.capture(of: element)
    }
}

extension MacElementSource: RegionAnchorSource {
    public func regionAnchor(at point: CGPoint) -> Element? {
        AXIntrospection.regionAnchor(for: point)
    }
}

extension MacElementSource: ComponentLadderSource {
    public func componentLadder(at point: CGPoint) -> [Element] {
        AXIntrospection.componentLadder(for: point)
    }
}

extension MacElementSource: ChildNavigationSource {
    public func children(of element: Element, near hint: CGPoint?) -> [Element] {
        AXIntrospection.children(of: element, near: hint)
    }
}

extension MacElementSource: MarqueeTargetSource {
    public func marqueeLadder(in rect: CGRect) -> [Element] {
        AXIntrospection.marqueeLadder(for: rect)
    }
}
#endif
