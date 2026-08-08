#if os(macOS)
import AppKit
import CoreGraphics

/// View-hierarchy node for macOS (the opt-in strategy), wrapping an `NSView`.
final class NSViewNode: SelectorMatchable {
    let view: NSView
    let id: String
    let selectorIdentifier: String
    let selectorLabel: String
    let selectorType: String
    let selectorRole: String
    let selectorText: String
    let frame: CGRect
    let isVisible: Bool
    let isActionable: Bool
    let path: [PathComponent]
    let children: [NSViewNode]

    var selectorChildren: [NSViewNode] { children }

    init(
        view: NSView, id: String, selectorIdentifier: String, selectorLabel: String,
        selectorType: String, frame: CGRect, isVisible: Bool, isActionable: Bool,
        path: [PathComponent], children: [NSViewNode]
    ) {
        self.view = view
        self.id = id
        self.selectorIdentifier = selectorIdentifier
        self.selectorLabel = selectorLabel
        self.selectorType = selectorType
        self.selectorRole = selectorType
        self.selectorText = ""
        self.frame = frame
        self.isVisible = isVisible
        self.isActionable = isActionable
        self.path = path
        self.children = children
    }

    func toElement() -> Element {
        Element(
            id: id, role: selectorRole, type: selectorType, label: selectorLabel,
            value: "", frame: frame, isVisible: isVisible, isActionable: isActionable,
            path: path, children: children.map { $0.toElement() }
        )
    }
}

/// The opt-in macOS ``ElementSource`` that walks the `NSView` tree directly. It
/// surfaces concrete view class names (which the AX API cannot provide) and is
/// richer for AppKit-heavy hosts. In a pure-SwiftUI app it collapses to
/// `NSHostingView` wrappers, so the AX source (``MacElementSource``) stays the
/// default. Frames are reported in AX top-left coordinates to match the AX
/// source; screenshots reuse the shared renderer.
@MainActor
public final class MacViewTreeElementSource: ElementSource, ComponentLadderSource {
    public init() {}

    static let maxDepth = 200

    public func snapshot() -> [WindowSnapshot] {
        NSApp.windows.compactMap { window -> WindowSnapshot? in
            guard let content = window.contentView else { return nil }
            let root = Self.buildNode(
                content,
                selfComponent: Self.component(for: content, indexAmongRole: 0),
                parentPath: [],
                depth: 0
            )
            return WindowSnapshot(
                title: window.title,
                frame: Self.screenFrame(of: content),
                isOnscreen: window.isVisible,
                root: root.toElement()
            )
        }
    }

    public func hitTest(_ point: CGPoint) -> Element? {
        guard let chain = Self.resolvedChain(at: point) else { return nil }
        let candidates = chain.map { Self.candidate(for: $0) }
        guard let index = AnnotationTargetRule.targetIndex(in: candidates) else { return nil }
        return Self.element(for: chain[index])
    }

    /// The component-widening ladder at `point` (target, then enclosing identified
    /// views), matching the AX and iOS sources so all three widen identically.
    public func componentLadder(at point: CGPoint) -> [Element] {
        guard let chain = Self.resolvedChain(at: point) else { return [] }
        let candidates = chain.map { Self.candidate(for: $0) }
        return AnnotationTargetRule.wideningLadder(in: candidates).map { Self.element(for: chain[$0]) }
    }

    public func selector(for element: Element) -> String {
        let roots = NSApp.windows.compactMap { $0.contentView }.map {
            Self.buildNode($0, selfComponent: Self.component(for: $0, indexAmongRole: 0), parentPath: [], depth: 0)
        }
        if let selector = SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots) {
            return selector.rendered
        }
        // Never a synthetic `#<slash/path>` id (see ``Selector/fromPath(of:)``).
        return Selector.fromPath(of: element).rendered
    }

    public func screenshot(of element: Element?) async throws -> CapturedImage {
        try AXScreenshot.capture(of: element)
    }

    // MARK: - Tree building

    private static func buildNode(
        _ view: NSView, selfComponent: PathComponent, parentPath: [PathComponent], depth: Int
    ) -> NSViewNode {
        let path = parentPath + [selfComponent]
        let identifier = view.accessibilityIdentifier()
        let type = String(describing: Swift.type(of: view))
        let frame = screenFrame(of: view)
        let displayID = identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier

        var children: [NSViewNode] = []
        if depth < maxDepth {
            var roleCounts: [String: Int] = [:]
            for child in view.subviews {
                let childType = String(describing: Swift.type(of: child))
                let index = roleCounts[childType, default: 0]
                roleCounts[childType] = index + 1
                children.append(buildNode(
                    child,
                    selfComponent: component(for: child, indexAmongRole: index, typeHint: childType),
                    parentPath: path,
                    depth: depth + 1
                ))
            }
        }

        return NSViewNode(
            view: view, id: displayID, selectorIdentifier: identifier,
            selectorLabel: view.accessibilityLabel() ?? "", selectorType: type, frame: frame,
            isVisible: !view.isHidden && view.alphaValue > 0.01 && frame.width > 0 && frame.height > 0,
            isActionable: view is NSControl, path: path, children: children
        )
    }

    private static func component(for view: NSView, indexAmongRole: Int, typeHint: String? = nil) -> PathComponent {
        let identifier = view.accessibilityIdentifier()
        return PathComponent(
            role: typeHint ?? String(describing: Swift.type(of: view)),
            label: view.accessibilityLabel() ?? "",
            identifier: identifier.isEmpty ? nil : identifier,
            indexAmongRole: indexAmongRole
        )
    }

    private static func element(for view: NSView) -> Element {
        var chain: [NSView] = []
        var current: NSView? = view
        var depth = 0
        while let node = current, depth < maxDepth {
            chain.append(node)
            current = node.superview
            depth += 1
        }
        let rootFirst = Array(chain.reversed())

        var path: [PathComponent] = []
        for (index, node) in rootFirst.enumerated() {
            let position = index == 0 ? 0 : indexAmongType(node, in: rootFirst[index - 1].subviews)
            path.append(component(for: node, indexAmongRole: position))
        }

        let identifier = view.accessibilityIdentifier()
        return NSViewNode(
            view: view, id: identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier,
            selectorIdentifier: identifier, selectorLabel: view.accessibilityLabel() ?? "",
            selectorType: String(describing: Swift.type(of: view)), frame: screenFrame(of: view),
            isVisible: !view.isHidden, isActionable: view is NSControl, path: path, children: []
        ).toElement()
    }

    private static func indexAmongType(_ view: NSView, in siblings: [NSView]) -> Int {
        let type = String(describing: Swift.type(of: view))
        var index = 0
        for sibling in siblings {
            if sibling === view { return index }
            if String(describing: Swift.type(of: sibling)) == type { index += 1 }
        }
        return index
    }

    /// Resolve `point` to the deepest hit view's root-first ancestor chain, or nil
    /// when nothing is under the point. Target selection and widening apply the
    /// shared ``AnnotationTargetRule`` to this chain.
    private static func resolvedChain(at point: CGPoint) -> [NSView]? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let content = window.contentView
        else { return nil }
        let cocoaScreen = ScreenSpace.flipPoint(point, primaryHeight: primaryHeight())
        let inWindow = window.convertPoint(fromScreen: cocoaScreen)
        guard let view = content.hitTest(inWindow) else { return nil }
        return ancestorChain(from: view)
    }

    /// Root-first ancestor chain of `view`, climbing `superview`.
    private static func ancestorChain(from view: NSView) -> [NSView] {
        var chain: [NSView] = []
        var current: NSView? = view
        var depth = 0
        while let node = current, depth < maxDepth {
            chain.append(node)
            current = node.superview
            depth += 1
        }
        return chain.reversed()
    }

    /// Read one view's target-relevant facts into a pure ``TargetCandidate``. The
    /// NSView tree has no displayed value text, so `value` is always empty.
    ///
    /// `isContainerRoot` defaults to false because on the POINT path the chain is
    /// an ancestor chain rooted at the hit's window content view, and flagging it
    /// there would change which element a click resolves to. The marquee walk
    /// passes true for the content view: a whole-tree walk offers it as a real
    /// candidate, and without the flag a large drag would surround it and bind the
    /// note to the app's entire content view instead of the card inside it.
    private static func candidate(for view: NSView, isContainerRoot: Bool = false) -> TargetCandidate {
        TargetCandidate(
            role: String(describing: Swift.type(of: view)),
            identifier: view.accessibilityIdentifier(),
            label: view.accessibilityLabel() ?? "",
            value: "",
            isActionable: view is NSControl,
            isContainerRoot: isContainerRoot
        )
    }

    private static func screenFrame(of view: NSView) -> CGRect {
        guard let window = view.window else { return view.frame }
        let inWindow = view.convert(view.bounds, to: nil)
        let cocoaScreen = window.convertToScreen(inWindow)
        return ScreenSpace.axTopLeftRect(fromCocoa: cocoaScreen, primaryHeight: primaryHeight())
    }

    private static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}

// MARK: - Marquee (drawn frame -> view)

extension MacViewTreeElementSource: MarqueeTargetSource {
    /// The ladder for a frame the user DREW, over the `NSView` tree: the view the
    /// frame binds to per ``MarqueeTargetRule`` first, then its enclosing
    /// identified views, broadest last — the same contract as
    /// ``componentLadder(at:)``, so the session's widening works from a framed
    /// selection unchanged.
    ///
    /// Cost: one full walk of the hit window's view tree per drag RELEASE. Never
    /// during the drag and never on hover, which is what makes a whole-tree walk
    /// affordable here where the hover path must stay on the ancestor chain.
    public func marqueeLadder(in rect: CGRect) -> [Element] {
        // Standardize first: a right-to-left / bottom-to-top drag arrives with
        // negative extents, where the window lookup's `contains` degenerates.
        let marquee = rect.standardized
        guard let content = Self.marqueeRoot(containing: CGPoint(x: marquee.midX, y: marquee.midY)) else {
            return []
        }

        // ONE recursive walk from the content view, so every candidate's depth is
        // measured from the SAME root (content view = 0) — depth is the rule's
        // tie-break between geometrically indistinguishable candidates, and mixing
        // differently-rooted numbering would make it noise. The subtree is
        // collected WHOLE, deliberately not pre-filtered to what intersects the
        // frame: the rule's enclosing pass needs the views that CONTAIN the frame,
        // which such a filter is exactly what discards.
        var views: [NSView] = []
        var candidates: [MarqueeCandidate] = []
        Self.collectMarqueeCandidates(content, isRoot: true, depth: 0, views: &views, candidates: &candidates)

        guard let resolution = MarqueeTargetRule.resolve(marquee: marquee, in: candidates) else { return [] }
        let target = views[resolution.index]
        return [Self.element(for: target)]
            + Self.enclosingIdentifiedViews(of: target, upTo: content).map { Self.element(for: $0) }
    }

    /// The content view of the frontmost visible non-overlay window under `point`.
    /// `NSApp.orderedWindows` is front-to-back, mirroring how the AX source reads
    /// `kAXWindows`, so both sources pick the same window for the same drag. The
    /// overlay panel is excluded by the identifier ``OverlayController`` stamps on
    /// it — the drawn frame always lies over the expanded overlay, so without this
    /// every marquee would walk our own hosting view.
    private static func marqueeRoot(containing point: CGPoint) -> NSView? {
        for window in NSApp.orderedWindows {
            guard window.isVisible,
                  window.accessibilityIdentifier() != AXIntrospection.overlayWindowIdentifier,
                  let content = window.contentView,
                  screenFrame(of: content).contains(point)
            else { continue }
            return content
        }
        return nil
    }

    /// Depth-first walk collecting a PARALLEL pair per view — the live `NSView`
    /// and its pure ``MarqueeCandidate`` — so
    /// ``MarqueeTargetRule/Resolution/index`` maps straight back to a view.
    ///
    /// Hidden and fully transparent subtrees are skipped: they keep real frames, so
    /// a marquee would happily "surround" a hidden view the user cannot even see,
    /// and being the largest such frame it would win pass 1 outright. The point
    /// path gets this for free from `NSView.hitTest`, which a whole-tree walk does
    /// not go through.
    private static func collectMarqueeCandidates(
        _ view: NSView,
        isRoot: Bool,
        depth: Int,
        views: inout [NSView],
        candidates: inout [MarqueeCandidate]
    ) {
        views.append(view)
        candidates.append(
            MarqueeCandidate(
                element: candidate(for: view, isContainerRoot: isRoot),
                frame: screenFrame(of: view),
                depth: depth
            )
        )
        guard depth < maxDepth else { return }
        for subview in view.subviews where !subview.isHidden && subview.alphaValue > 0.01 {
            collectMarqueeCandidates(
                subview, isRoot: false, depth: depth + 1, views: &views, candidates: &candidates
            )
        }
    }

    /// The identified superviews of `target`, nearest first (so broadest last),
    /// stopping BEFORE `root` — the content view is the container root and is never
    /// a widening rung, for the same reason it is never a target. Pure ancestry,
    /// matching this source's point ladder; the AX source's extra geometric scan
    /// exists for SwiftUI `.background` surfaces, which are AX-only artifacts with
    /// no counterpart in the `NSView` tree.
    private static func enclosingIdentifiedViews(of target: NSView, upTo root: NSView) -> [NSView] {
        var out: [NSView] = []
        var current = target.superview
        var depth = 0
        while let view = current, view !== root, depth < maxDepth {
            if !view.accessibilityIdentifier().isEmpty { out.append(view) }
            current = view.superview
            depth += 1
        }
        return out
    }
}
#endif
