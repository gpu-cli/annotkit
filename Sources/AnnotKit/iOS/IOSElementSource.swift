#if os(iOS)
import CoreGraphics
import UIKit

/// View-hierarchy node for iOS. Like the macOS ``AXElementNode`` but wrapping a
/// `UIView`; the immutable matchable fields satisfy ``SelectorMatchable`` so the
/// shared ``SelectorEngine`` serves both platforms.
final class UIViewNode: SelectorMatchable {
    let view: UIView
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
    let children: [UIViewNode]

    var selectorChildren: [UIViewNode] { children }

    init(
        view: UIView, id: String, selectorIdentifier: String, selectorLabel: String,
        selectorType: String, selectorText: String, frame: CGRect, isVisible: Bool,
        isActionable: Bool, path: [PathComponent], children: [UIViewNode]
    ) {
        self.view = view
        self.id = id
        self.selectorIdentifier = selectorIdentifier
        self.selectorLabel = selectorLabel
        self.selectorType = selectorType
        self.selectorRole = selectorType
        self.selectorText = selectorText
        self.frame = frame
        self.isVisible = isVisible
        self.isActionable = isActionable
        self.path = path
        self.children = children
    }

    func toElement() -> Element {
        Element(
            id: id, role: selectorRole, type: selectorType, label: selectorLabel,
            value: selectorText, frame: frame, isVisible: isVisible, isActionable: isActionable,
            path: path, children: children.map { $0.toElement() }
        )
    }
}

/// The default iOS ``ElementSource``: walks the app's `UIView` hierarchy.
/// UIKit is already top-left, so no coordinate flip is needed (see PARITY.md).
@MainActor
public final class IOSElementSource: ElementSource, ComponentLadderSource {
    public init() {}

    static let maxDepth = 200

    public func snapshot() -> [WindowSnapshot] {
        Self.windows().map { window in
            let root = Self.buildNode(
                window,
                selfComponent: Self.component(for: window, indexAmongRole: 0),
                parentPath: [],
                depth: 0
            )
            return WindowSnapshot(
                title: window.accessibilityLabel ?? "Window",
                frame: Self.screenFrame(of: window),
                isOnscreen: !window.isHidden,
                root: root.toElement()
            )
        }
    }

    public func hitTest(_ point: CGPoint) -> Element? {
        guard let (chain, index) = Self.resolveTarget(at: point) else { return nil }
        return Self.element(for: chain[index])
    }

    /// The component-widening ladder at `point`: the target view first, then each
    /// enclosing identified view, broadest last. Mirrors the macOS ladder so both
    /// platforms widen identically. Empty when nothing is annotatable.
    public func componentLadder(at point: CGPoint) -> [Element] {
        guard let window = Self.keyWindow else { return [] }
        let inWindow = window.convert(point, from: nil)
        guard let view = window.hitTest(inWindow, with: nil) else { return [] }
        let chain = Self.ancestorChain(from: view)
        let candidates = chain.map(Self.candidate(for:))
        return AnnotationTargetRule.wideningLadder(in: candidates).map { Self.element(for: chain[$0]) }
    }

    public func selector(for element: Element) -> String {
        let roots = Self.windows().map {
            Self.buildNode($0, selfComponent: Self.component(for: $0, indexAmongRole: 0), parentPath: [], depth: 0)
        }
        if let selector = SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots) {
            return selector.rendered
        }
        // Never a synthetic `#<slash/path>` id — fall back to the anchored,
        // resolvable path selector (see ``Selector/fromPath(of:)``).
        return Selector.fromPath(of: element).rendered
    }

    public func screenshot(of element: Element?) async throws -> CapturedImage {
        let bounds: CGRect
        let source: UIView
        if let element, let window = Self.keyWindow {
            source = window
            bounds = window.convert(element.frame, from: nil)
        } else if let window = Self.keyWindow {
            source = window
            bounds = window.bounds
        } else {
            throw CaptureError.noWindow
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { _ in
            source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }
        guard let data = image.pngData() else { throw CaptureError.encodeFailed }
        return CapturedImage(
            pngData: data,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale)
        )
    }

    enum CaptureError: Error { case noWindow, encodeFailed }

    // MARK: - Tree building

    private static func buildNode(
        _ view: UIView, selfComponent: PathComponent, parentPath: [PathComponent], depth: Int
    ) -> UIViewNode {
        let path = parentPath + [selfComponent]
        let identifier = view.accessibilityIdentifier ?? ""
        let type = String(describing: Swift.type(of: view))
        let frame = screenFrame(of: view)
        let displayID = identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier

        var children: [UIViewNode] = []
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

        return UIViewNode(
            view: view, id: displayID, selectorIdentifier: identifier,
            selectorLabel: view.accessibilityLabel ?? "", selectorType: type,
            selectorText: (view.accessibilityValue ?? ""), frame: frame,
            isVisible: !view.isHidden && view.alpha > 0.01 && frame.width > 0 && frame.height > 0,
            isActionable: view is UIControl, path: path, children: children
        )
    }

    private static func component(for view: UIView, indexAmongRole: Int, typeHint: String? = nil) -> PathComponent {
        let identifier = view.accessibilityIdentifier ?? ""
        return PathComponent(
            role: typeHint ?? String(describing: Swift.type(of: view)),
            label: view.accessibilityLabel ?? "",
            identifier: identifier.isEmpty ? nil : identifier,
            indexAmongRole: indexAmongRole
        )
    }

    private static func element(for view: UIView) -> Element {
        var chain: [UIView] = []
        var current: UIView? = view
        var depth = 0
        while let node = current, depth < maxDepth {
            chain.append(node)
            current = node.superview
            depth += 1
        }
        let rootFirst = Array(chain.reversed())

        var path: [PathComponent] = []
        for (index, node) in rootFirst.enumerated() {
            let position: Int
            if index == 0 {
                position = 0
            } else {
                position = indexAmongType(node, in: rootFirst[index - 1].subviews)
            }
            path.append(component(for: node, indexAmongRole: position))
        }

        let identifier = view.accessibilityIdentifier ?? ""
        return UIViewNode(
            view: view, id: identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier,
            selectorIdentifier: identifier, selectorLabel: view.accessibilityLabel ?? "",
            selectorType: String(describing: Swift.type(of: view)), selectorText: view.accessibilityValue ?? "",
            frame: screenFrame(of: view), isVisible: !view.isHidden,
            isActionable: view is UIControl, path: path, children: []
        ).toElement()
    }

    private static func indexAmongType(_ view: UIView, in siblings: [UIView]) -> Int {
        let type = String(describing: Swift.type(of: view))
        var index = 0
        for sibling in siblings {
            if sibling === view { return index }
            if String(describing: Swift.type(of: sibling)) == type { index += 1 }
        }
        return index
    }

    /// Resolve `point` to the target view's ancestor chain (root-first) and the
    /// target's index within it, per the shared ``AnnotationTargetRule`` — the
    /// same rule the macOS AX adapter uses, so a click resolves identically on
    /// both platforms. Returns nil when nothing at the point is annotatable.
    private static func resolveTarget(at point: CGPoint) -> (chain: [UIView], index: Int)? {
        guard let window = keyWindow else { return nil }
        let inWindow = window.convert(point, from: nil)
        guard let view = window.hitTest(inWindow, with: nil) else { return nil }
        let chain = ancestorChain(from: view)
        let candidates = chain.map(candidate(for:))
        guard let index = AnnotationTargetRule.targetIndex(in: candidates) else { return nil }
        return (chain, index)
    }

    /// Root-first ancestor chain of `view`, climbing `superview` to the window.
    private static func ancestorChain(from view: UIView) -> [UIView] {
        var chain: [UIView] = []
        var current: UIView? = view
        var depth = 0
        while let node = current, depth < maxDepth {
            chain.append(node)
            current = node.superview
            depth += 1
        }
        return chain.reversed()
    }

    /// Read one view's target-relevant facts into a pure ``TargetCandidate``.
    /// UIKit has no window chrome or window-spanning ghost groups, so only the
    /// window itself is a container root.
    private static func candidate(for view: UIView) -> TargetCandidate {
        TargetCandidate(
            role: String(describing: Swift.type(of: view)),
            identifier: view.accessibilityIdentifier ?? "",
            label: view.accessibilityLabel ?? "",
            value: view.accessibilityValue ?? "",
            isActionable: view is UIControl,
            isContainerRoot: view is UIWindow
        )
    }

    // MARK: - Window helpers

    /// Every inspectable HOST window — AnnotKit's own overlay is never one.
    ///
    /// On macOS the overlay is a separate `NSPanel` filtered out of `kAXWindows`
    /// by identifier; on iOS the risk is live rather than theoretical, because
    /// ``PassThroughWindow`` sits in the SAME scene as the host and is returned by
    /// `UIWindowScene.windows` like any other window. Its chrome is genuinely
    /// identified and genuinely meaningful, so it passes
    /// ``TargetCandidate/isEligibleMeaningful`` cleanly: leave it in and a marquee
    /// (which by construction spans screen area the overlay draws across) can bind
    /// the user's note to AnnotKit's own UI, and a snapshot/selector lists our
    /// toolbar as if it were app content.
    ///
    /// Excluded by TYPE identity, not by name, identifier, or window level: the
    /// type is internal to this module so the check cannot be defeated by a naming
    /// convention drifting, and a pid filter is useless here because AnnotKit runs
    /// in the host's process. Filtering in this ONE helper is what makes
    /// ``snapshot()``, ``keyWindow``, `hitTest`, `componentLadder(at:)`, and the
    /// marquee path agree — matching the macOS side, which excludes the overlay in
    /// every window lookup rather than only in the one that motivated it.
    private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !($0 is PassThroughWindow) }
    }

    static var keyWindow: UIWindow? {
        windows().first(where: \.isKeyWindow) ?? windows().first
    }

    private static func screenFrame(of view: UIView) -> CGRect {
        guard let window = view.window else { return view.frame }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convert(inWindow, to: nil)
    }
}

// MARK: - Marquee (drawn frame -> view)

extension IOSElementSource: MarqueeTargetSource {
    /// The ladder for a frame the user DREW, over the `UIView` tree: the view the
    /// frame binds to per ``MarqueeTargetRule`` first, then each enclosing
    /// identified component, broadest last — the SAME target-first contract as
    /// ``componentLadder(at:)``, because the session assumes `ladder[0]` IS the
    /// bound target for both widening and the note's `component` field.
    ///
    /// Structurally identical to the macOS path (`AXIntrospection.marqueeLadder`):
    /// both platforms only differ in how they read candidates out of their tree,
    /// and the decision itself is the one shared pure rule, so an identical drag
    /// over an identical layout resolves identically by construction rather than
    /// by two implementations being kept in step by hand.
    ///
    /// Cost: one full walk of the hit window's view tree per drag RELEASE — never
    /// during the drag and never on touch-move. That rate is what makes a
    /// whole-tree walk affordable here, where the point path must stay on the
    /// ancestor chain.
    public func marqueeLadder(in rect: CGRect) -> [Element] {
        // Standardize before anything geometric: a right-to-left / bottom-to-top
        // drag arrives with negative extents, where `contains` degenerates and the
        // window lookup below would silently find nothing.
        let marquee = rect.standardized
        guard let root = Self.marqueeRoot(containing: CGPoint(x: marquee.midX, y: marquee.midY)) else { return [] }

        // ONE recursive walk from that single root, so every candidate's depth is
        // measured from the SAME origin (window = 0, its children = 1, …). Depth is
        // the rule's tie-break between geometrically indistinguishable candidates;
        // numbering assembled from several differently-rooted traversals would turn
        // that tie-break into noise.
        //
        // The subtree is collected WHOLE — deliberately not pre-filtered to views
        // intersecting the drawn frame. The rule's second pass needs the candidates
        // whose frames CONTAIN the frame (the user drew INSIDE something), and an
        // intersects-the-marquee filter is exactly what discards them.
        var views: [UIView] = []
        var candidates: [MarqueeCandidate] = []
        Self.collectMarqueeCandidates(root, depth: 0, views: &views, candidates: &candidates)

        guard let resolution = MarqueeTargetRule.resolve(marquee: marquee, in: candidates) else { return [] }
        let target = views[resolution.index]

        // The widening rungs are anchored at the TARGET's frame centre, not the
        // drawn frame's: a sloppy marquee can spill outside the element it bound
        // to, and a container that does not contain the target is not a component
        // the user could widen to. Same value the point path passes.
        let targetFrame = Self.screenFrame(of: target)
        let targetCentre = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        return [Self.element(for: target)]
            + Self.enclosingComponents(of: target, containing: targetCentre).map { Self.element(for: $0) }
    }

    /// The frontmost visible non-overlay window containing `point`, or nil when the
    /// drag happened over nothing of ours.
    ///
    /// `UIWindowScene.windows` has no documented front-to-back order, so the
    /// frontmost is derived rather than assumed: highest `windowLevel` first, ties
    /// broken by the LATER array position, which is UIKit's own within-level
    /// ordering. Getting this wrong on a host that presents an alert or
    /// share-sheet window would walk the window BEHIND the one the user is looking
    /// at and bind the note to an element they cannot see.
    ///
    /// AnnotKit's own overlay cannot be picked here because ``windows()`` never
    /// returns it — see that helper for why the exclusion lives there and not in
    /// this method.
    private static func marqueeRoot(containing point: CGPoint) -> UIWindow? {
        windows()
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.windowLevel.rawValue == rhs.element.windowLevel.rawValue
                    ? lhs.offset > rhs.offset
                    : lhs.element.windowLevel.rawValue > rhs.element.windowLevel.rawValue
            }
            .first { screenFrame(of: $0.element).contains(point) }?
            .element
    }

    /// Depth-first walk collecting a PARALLEL pair per view — the live `UIView` and
    /// its pure ``MarqueeCandidate`` — so ``MarqueeTargetRule/Resolution/index``
    /// maps straight back to a live view.
    ///
    /// The candidate is built with the same ``candidate(for:)`` the point path
    /// uses, so container-root classification — which is what the rule's
    /// eligibility filter reads — is identical for a tap and a drag by
    /// construction, not by two call sites agreeing today.
    ///
    /// Hidden and effectively transparent subtrees are skipped WHOLE: they keep
    /// real frames, so a marquee would happily "surround" a view the user cannot
    /// see, and being a large such frame it could win pass 1 outright. The point
    /// path gets this filtering free from `UIView.hitTest`, which a whole-tree walk
    /// never goes through.
    private static func collectMarqueeCandidates(
        _ view: UIView,
        depth: Int,
        views: inout [UIView],
        candidates: inout [MarqueeCandidate]
    ) {
        views.append(view)
        candidates.append(
            MarqueeCandidate(element: candidate(for: view), frame: screenFrame(of: view), depth: depth)
        )
        guard depth < maxDepth else { return }
        for subview in view.subviews where !subview.isHidden && subview.alpha > 0.01 {
            collectMarqueeCandidates(subview, depth: depth + 1, views: &views, candidates: &candidates)
        }
    }

    /// The identified components that geometrically ENCLOSE `target` at `point`,
    /// smallest-first — the widening rungs above a bound target, mirroring the
    /// macOS `enclosingComponents(of:containing:in:)` so a drag widens through the
    /// same kind of components on both platforms.
    ///
    /// The scan is GEOMETRIC, not pure ancestry (DECISIONS.md → "Component
    /// containment is GEOMETRIC"): a card's identified background surface is
    /// routinely a SIBLING of the card's content rather than its ancestor, so it
    /// never appears in an ancestor chain. Scanning each ancestor PLUS its direct
    /// subviews reaches those surfaces without a second whole-tree walk. Deduped by
    /// identifier because the same surface is reachable from several ancestors, and
    /// the `>= targetArea` floor keeps a SMALLER identified sibling that merely
    /// happens to cover the target's centre out of a ladder that is supposed to
    /// only ever widen.
    ///
    /// Container roots are excluded, matching
    /// ``AnnotationTargetRule/wideningLadder(in:)`` stopping at the window: the
    /// window encloses everything, so it would be the top rung of every ladder
    /// while naming no component an agent could act on.
    private static func enclosingComponents(of target: UIView, containing point: CGPoint) -> [UIView] {
        let targetFrame = screenFrame(of: target)
        let targetArea = targetFrame.width * targetFrame.height
        var containers: [(view: UIView, area: CGFloat)] = []
        var seen = Set<String>()
        for ancestor in ancestorChain(from: target) {
            for view in [ancestor] + ancestor.subviews {
                guard !(view is UIWindow), view !== target else { continue }
                guard !view.isHidden, view.alpha > 0.01 else { continue }
                let identifier = view.accessibilityIdentifier ?? ""
                guard !identifier.isEmpty, !seen.contains(identifier) else { continue }
                let frame = screenFrame(of: view)
                let area = frame.width * frame.height
                guard frame.width > 0, frame.height > 0, frame.contains(point), area >= targetArea else { continue }
                seen.insert(identifier)
                containers.append((view, area))
            }
        }
        containers.sort { $0.area < $1.area }
        return containers.map(\.view)
    }
}
#endif
