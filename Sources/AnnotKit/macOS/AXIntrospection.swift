#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Handle-carrying AX tree node. A plain (non-isolated, non-Sendable) reference
/// type so the live `AXUIElement` stays put and the immutable matchable fields
/// satisfy ``SelectorMatchable`` without any actor hop. Built on the main actor
/// by ``AXIntrospection``; the engine reads it synchronously on the same actor,
/// so no live handle ever crosses a boundary.
final class AXElementNode: SelectorMatchable {
    let axElement: AXUIElement
    /// Display id: the accessibilityIdentifier when present, else a stable
    /// path-derived string. Used to match an ``Element`` back to its node.
    let id: String
    let selectorIdentifier: String
    let selectorLabel: String
    let selectorType: String
    let selectorRole: String
    let selectorText: String
    let frame: CGRect
    let isActionable: Bool
    let isVisible: Bool
    let path: [PathComponent]
    let children: [AXElementNode]

    var selectorChildren: [AXElementNode] { children }

    init(
        axElement: AXUIElement,
        id: String,
        selectorIdentifier: String,
        selectorLabel: String,
        selectorType: String,
        selectorRole: String,
        selectorText: String,
        frame: CGRect,
        isActionable: Bool,
        isVisible: Bool,
        path: [PathComponent],
        children: [AXElementNode]
    ) {
        self.axElement = axElement
        self.id = id
        self.selectorIdentifier = selectorIdentifier
        self.selectorLabel = selectorLabel
        self.selectorType = selectorType
        self.selectorRole = selectorRole
        self.selectorText = selectorText
        self.frame = frame
        self.isActionable = isActionable
        self.isVisible = isVisible
        self.path = path
        self.children = children
    }

    /// Project to the public, Sendable ``Element``.
    func toElement() -> Element {
        Element(
            id: id,
            role: selectorRole,
            type: selectorType,
            label: selectorLabel,
            value: selectorText,
            frame: frame,
            isVisible: isVisible,
            isActionable: isActionable,
            path: path,
            children: children.map { $0.toElement() }
        )
    }
}

/// In-process AX introspection of the host app: a tree walker, a point-query
/// hit-test with the nearest-identified-ancestor rule, and selector generation.
/// Adapted from VirgilHUD's `InspectIntrospection`; the proto coupling is gone
/// and the selector engine is the shared ``SelectorEngine``. Main-actor isolated
/// because AX access must run on the main thread.
@MainActor
enum AXIntrospection {
    static let maxDepth = 200

    /// AX identifier that ``OverlayController`` stamps on its overlay panel
    /// window (`panel.setAccessibilityIdentifier(_:)`). The point query and the
    /// snapshot both skip any window carrying it, so our own overlay never
    /// shadows the host. This is required in addition to the SwiftUI content
    /// being `accessibilityHidden`: when the panel expands to the host's full
    /// frame it is a live `AXWindow` that `AXUIElementCopyElementAtPosition`
    /// hit-tests first, so without excluding the panel WINDOW every hover/click
    /// resolves to the overlay's own hosting view instead of the control beneath.
    static let overlayWindowIdentifier = "com.annotkit.overlay-window"

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXSlider"
    ]

    // MARK: - Application element

    /// The process's application AX element, cached, with `AXEnhancedUserInterface`
    /// set EXACTLY ONCE so AppKit/SwiftUI materializes the full semantic tree for us.
    /// Self-query needs no accessibility-trust prompt.
    ///
    /// Setting that attribute once is load-bearing, not an optimization. It was
    /// previously re-set on every call — and this is called from the HOVER hit-test,
    /// which the catcher runs at up to 60Hz while the pointer moves. Writing
    /// `AXEnhancedUserInterface` tells AppKit an assistive client just attached, and
    /// AppKit responds by re-evaluating (and, on SwiftUI hosts, relaying out) its
    /// windows; doing that 60 times a second drove a resize storm in the host, each
    /// resize firing `didResize` -> `syncFrameAndOrigin()` -> a fresh SwiftUI root
    /// view, which is what made the toolbar pill visibly vanish.
    ///
    /// The reported trigger pinpointed it: hovering ONTO the pill stops the storm
    /// (the pill consumes hover, so the catcher sees `.ended` and queries nothing)
    /// and moving OFF it restarts them. It showed up on scrollable screens because a
    /// large scroll view is a large AX tree, so materializing it is far more likely
    /// to cost a real layout pass.
    ///
    /// The element itself is stable for the life of the process, so caching it also
    /// drops an `AXUIElementCreateApplication` per query.
    private static var cachedAppElement: AXUIElement?
    /// How many times `AXEnhancedUserInterface` has been written. Must never exceed 1;
    /// the probe asserts it across a hover storm so the regression cannot come back
    /// silently.
    private(set) static var enhancedUserInterfaceWrites = 0

    private static func appElement() -> AXUIElement {
        if let cachedAppElement { return cachedAppElement }
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        enhancedUserInterfaceWrites += 1
        cachedAppElement = app
        return app
    }

    // MARK: - Snapshot

    /// Snapshot every window of the host app as an ``AXElementNode`` tree,
    /// excluding our own overlay panel window(s) so the overlay never appears as
    /// a phantom window shadowing the host.
    static func snapshotNodes() -> [AXElementNode] {
        let app = appElement()
        return elementArray(app, kAXWindowsAttribute)
            .filter { !isOverlayWindow($0) }
            .map { window in
                buildNode(window, selfComponent: component(for: window, indexAmongRole: 0), parentPath: [], depth: 0)
            }
    }

    /// True when `window` is one of our own overlay panels, tagged by
    /// ``OverlayController`` with ``overlayWindowIdentifier``.
    private static func isOverlayWindow(_ window: AXUIElement) -> Bool {
        string(window, kAXIdentifierAttribute) == overlayWindowIdentifier
    }

    /// True when `element` lives inside one of our overlay panel windows. Used to
    /// reject a point-query hit that resolved into the overlay so we never return
    /// the overlay's own hosting view instead of the host control.
    private static func belongsToOverlayWindow(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < maxDepth {
            if string(node, kAXRoleAttribute) == "AXWindow" { return isOverlayWindow(node) }
            current = copyValue(node, kAXParentAttribute).map { unsafeDowncast($0, to: AXUIElement.self) }
            depth += 1
        }
        return false
    }

    /// Public snapshot in terms of ``WindowSnapshot``.
    static func snapshot() -> [WindowSnapshot] {
        snapshotNodes().map { root in
            WindowSnapshot(
                title: root.selectorLabel,
                frame: root.frame,
                isOnscreen: root.isVisible,
                root: root.toElement()
            )
        }
    }

    private static func buildNode(
        _ element: AXUIElement,
        selfComponent: PathComponent,
        parentPath: [PathComponent],
        depth: Int
    ) -> AXElementNode {
        let path = parentPath + [selfComponent]
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let identifier = string(element, kAXIdentifierAttribute) ?? ""
        let label = labelText(element)
        let value = string(element, kAXValueAttribute) ?? ""
        let frame = frameScreen(of: element)
        let displayID = identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier

        var children: [AXElementNode] = []
        if depth < maxDepth {
            var roleCounts: [String: Int] = [:]
            for child in elementArray(element, kAXChildrenAttribute) {
                let childRole = string(child, kAXRoleAttribute) ?? "AXUnknown"
                let index = roleCounts[childRole, default: 0]
                roleCounts[childRole] = index + 1
                children.append(
                    buildNode(
                        child,
                        selfComponent: component(for: child, indexAmongRole: index, roleHint: childRole),
                        parentPath: path,
                        depth: depth + 1
                    )
                )
            }
        }

        return AXElementNode(
            axElement: element,
            id: displayID,
            selectorIdentifier: identifier,
            selectorLabel: label,
            selectorType: subrole.isEmpty ? role : subrole,
            selectorRole: role,
            selectorText: value,
            frame: frame,
            isActionable: actionNames(element).contains(kAXPressAction as String)
                || actionableRoles.contains(role),
            isVisible: frame.width > 0 && frame.height > 0,
            path: path,
            children: children
        )
    }

    private static func component(
        for element: AXUIElement,
        indexAmongRole: Int,
        roleHint: String? = nil
    ) -> PathComponent {
        let role = roleHint ?? (string(element, kAXRoleAttribute) ?? "AXUnknown")
        let identifier = string(element, kAXIdentifierAttribute) ?? ""
        return PathComponent(
            role: role,
            label: labelText(element),
            identifier: identifier.isEmpty ? nil : identifier,
            indexAmongRole: indexAmongRole
        )
    }

    // MARK: - Hit test (point -> element)

    /// Resolve a screen point (AX top-left coordinates) to an annotation target.
    /// Uses the native `AXUIElementCopyElementAtPosition` for the deepest
    /// element, then walks up to the nearest ancestor carrying a stable identity
    /// (identifier or label), per docs/spike-ax-pointquery.md.
    ///
    /// The native app-level query is the fast path: when it lands on a real host
    /// element (idle corner overlay, or any point the overlay does not cover) it
    /// is the most accurate hit-test, so it is kept. But the expanded overlay is
    /// a full-window `AXWindow` sitting above the host, so while annotating the
    /// native query hits the overlay's own hosting-view group instead of the
    /// control beneath — that is the "everything resolves to the whole app" bug.
    /// When the native hit belongs to our overlay we discard it and resolve the
    /// point by descending the frontmost non-overlay window's AX subtree directly
    /// (``hitBeneathOverlay(_:)``), which is what "queries beneath" the overlay.
    /// (`AXUIElementCopyElementAtPosition` only hit-tests when given the
    /// application element, so we cannot simply re-target it at the host window.)
    static func hitTest(_ point: CGPoint) -> Element? {
        guard let chain = resolvedChain(at: point) else { return nil }
        // The unified target rule (DECISIONS.md): the deepest ACTIONABLE control,
        // else the deepest MEANINGFUL element. Never the window/application — that
        // is what made a background click resolve to the whole app.
        guard let target = annotationTarget(in: chain) else {
            return nil
        }
        return element(for: target, ancestorChain: chain)
    }

    /// The component-widening ladder at `point`: the annotation target first, then
    /// each enclosing identified component, smallest-first. Empty when the point is
    /// not annotatable. Reuses the same resolved chain as ``hitTest(_:)`` so the
    /// first entry equals what `hitTest` returns.
    ///
    /// Containment is GEOMETRIC, not tree-ancestry: a SwiftUI card seeded with
    /// `.axCardSurface` is a clear background leaf that is a SIBLING of the card's
    /// content (so it never appears in the content's ancestor chain) yet whose
    /// frame spans the whole card. To reach it we collect every identified element
    /// whose frame encloses the point and is larger than the target. Those
    /// surfaces live as direct children of an ancestor (the background of the card
    /// view), so scanning the ancestor chain plus each ancestor's direct children
    /// finds them without a full-tree snapshot.
    static func componentLadder(for point: CGPoint) -> [Element] {
        guard let chain = resolvedChain(at: point) else { return [] }
        let windowFrame = chain.first { string($0, kAXRoleAttribute) == "AXWindow" }.map(frameScreen(of:))
        let candidates = chain.map { candidate(for: $0, windowFrame: windowFrame) }
        guard let targetIndex = AnnotationTargetRule.targetIndex(in: candidates) else { return [] }
        let target = chain[targetIndex]

        return [element(for: target, ancestorChain: chain)]
            + enclosingComponents(of: target, containing: point, in: chain)
                .map { element(for: $0, ancestorChain: ancestorChain(from: $0)) }
    }

    /// The identified components that geometrically ENCLOSE `target` at `point`,
    /// smallest-first — the widening rungs above a bound target. Shared verbatim
    /// by the point path (``componentLadder(for:)``) and the frame path
    /// (``marqueeLadder(for:)``) so a click and a drag onto the same element can
    /// never widen through different components; duplicating this scan is exactly
    /// how the two paths would silently drift apart.
    ///
    /// The scan is GEOMETRIC (DECISIONS.md): a `.axCardSurface` card hangs its
    /// identifier on a clear background leaf that is a SIBLING of the card's
    /// content, so it never appears in an ancestor chain. Scanning each ancestor
    /// PLUS its direct children reaches those surfaces without a full-tree walk.
    /// Deduped by identifier (the same surface is reachable from several
    /// ancestors), and the `>= targetArea` floor keeps a smaller identified
    /// sibling that merely happens to cover the point out of the widening ladder.
    ///
    /// Container ROOTS are excluded, matching ``AnnotationTargetRule/wideningLadder(in:)``
    /// stopping at the window. Load-bearing, not tidiness: the chain climbs to
    /// `AXApplication`, whose direct children are the app's WINDOWS — including our
    /// own overlay panel, which carries ``overlayWindowIdentifier`` and encloses
    /// every point in the host. Without this the top rung of every ladder is
    /// AnnotKit's own overlay, so widening would bind the user's note to our UI.
    private static func enclosingComponents(
        of target: AXUIElement,
        containing point: CGPoint,
        in rootFirstChain: [AXUIElement]
    ) -> [AXUIElement] {
        let targetArea = area(of: target)
        var containers: [(node: AXUIElement, area: CGFloat)] = []
        var seen = Set<String>()
        for ancestor in rootFirstChain {
            for node in [ancestor] + elementArray(ancestor, kAXChildrenAttribute) {
                let role = string(node, kAXRoleAttribute) ?? ""
                guard role != "AXWindow", role != "AXApplication" else { continue }
                let id = string(node, kAXIdentifierAttribute) ?? ""
                guard !id.isEmpty, !seen.contains(id), !CFEqual(node, target) else { continue }
                let frame = frameScreen(of: node)
                guard frame.width > 0, frame.height > 0, frame.contains(point), area(of: node) >= targetArea else {
                    continue
                }
                seen.insert(id)
                containers.append((node, area(of: node)))
            }
        }
        containers.sort { $0.area < $1.area }
        return containers.map(\.node)
    }

    // MARK: - Marquee (drawn frame -> element)

    /// The component-widening ladder for a frame the user DREW: the element the
    /// frame binds to per ``MarqueeTargetRule`` first, then each enclosing
    /// identified component, broadest last. Same shape as
    /// ``componentLadder(for:)``, because the session reuses its ladder machinery
    /// verbatim — widening and the note's `component` field both assume
    /// `ladder[0]` is the bound target. Empty when the frame resolves to nothing
    /// (the session then captures a region note instead).
    ///
    /// Cost: this walks the whole window subtree ONCE, on drag RELEASE only —
    /// never during the drag and never on hover. A full walk is affordable at that
    /// rate; it would not be on the hover path, which is why the point path still
    /// uses the ancestor-chain scan instead.
    static func marqueeLadder(for rect: CGRect) -> [Element] {
        // Standardize before anything geometric: a right-to-left / bottom-to-top
        // drag arrives with negative extents, where `contains` degenerates and the
        // window lookup below would silently find nothing.
        let marquee = rect.standardized
        let center = CGPoint(x: marquee.midX, y: marquee.midY)
        let app = appElement()
        // Same window pick as ``regionAnchor(for:)`` / ``hitBeneathOverlay(_:)``:
        // `kAXWindows` is front-to-back, so the first non-overlay window containing
        // the frame's center is the frontmost real target.
        let windows = elementArray(app, kAXWindowsAttribute).filter { !isOverlayWindow($0) }
        guard let window = windows.first(where: { frameScreen(of: $0).contains(center) }) else { return [] }
        let windowFrame = frameScreen(of: window)

        // ONE recursive walk, so every candidate's depth is measured from the SAME
        // root (window = 0). Depth is the rule's tie-break between geometrically
        // indistinguishable candidates; assembling the array from several
        // differently-rooted traversals would turn that tie-break into noise.
        //
        // The subtree is collected WHOLE — deliberately not pre-filtered to what
        // intersects the drawn frame. The rule's second pass needs the candidates
        // whose frames CONTAIN the frame (the user drew inside something), and an
        // intersects-the-marquee filter is precisely what discards them.
        var nodes: [AXUIElement] = []
        var candidates: [MarqueeCandidate] = []
        collectMarqueeCandidates(
            window, windowFrame: windowFrame, depth: 0, nodes: &nodes, candidates: &candidates
        )

        guard let resolution = MarqueeTargetRule.resolve(marquee: marquee, in: candidates) else { return [] }
        let target = nodes[resolution.index]
        let chain = ancestorChain(from: target)

        // The widening rungs are anchored at the TARGET's frame center, not the
        // drawn frame's: a sloppy marquee can spill outside the element it bound
        // to, and a container that does not contain the target is not a component
        // the user could widen to. This is also the value the point path passes.
        let targetFrame = frameScreen(of: target)
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        return [element(for: target, ancestorChain: chain)]
            + enclosingComponents(of: target, containing: targetCenter, in: chain)
                .map { element(for: $0, ancestorChain: ancestorChain(from: $0)) }
    }

    /// Depth-first walk collecting a PARALLEL pair per node: the live
    /// `AXUIElement` and its pure ``MarqueeCandidate``, so
    /// ``MarqueeTargetRule/Resolution/index`` maps straight back to a live handle.
    ///
    /// The candidate is built with the same ``candidate(for:windowFrame:)`` the
    /// point path uses, so chrome / container-root / window-ghost classification —
    /// which is what the rule's eligibility filter reads — is identical for a click
    /// and a drag by construction.
    private static func collectMarqueeCandidates(
        _ element: AXUIElement,
        windowFrame: CGRect,
        depth: Int,
        nodes: inout [AXUIElement],
        candidates: inout [MarqueeCandidate]
    ) {
        nodes.append(element)
        candidates.append(
            MarqueeCandidate(
                element: candidate(for: element, windowFrame: windowFrame),
                frame: frameScreen(of: element),
                depth: depth
            )
        )
        guard depth < maxDepth else { return }
        for child in elementArray(element, kAXChildrenAttribute) {
            // Starting from a non-overlay window should already put the overlay out
            // of reach, but AppKit exposes an attached child PANEL through some
            // parents' `kAXChildren`, so verify rather than assume: a marquee that
            // swept the overlay's own hosting view would bind the note to our UI.
            if isOverlayWindow(child) { continue }
            // Chrome's whole subtree is skipped, not just the button: the traffic
            // lights' inner glyph groups carry no chrome subrole of their own, so
            // the rule's `isChrome` filter alone would let a marquee over the title
            // bar bind to a glyph. The point path rejects chrome geometrically for
            // the same reason.
            if isChrome(child) { continue }
            collectMarqueeCandidates(
                child, windowFrame: windowFrame, depth: depth + 1, nodes: &nodes, candidates: &candidates
            )
        }
    }

    // MARK: - Child navigation (element -> the component inside it)

    /// The meaningful children of `element`, most-likely-intended first — the
    /// DOWNWARD counterpart of ``componentLadder(for:)``. Ordering is the shared
    /// pure ``ChildNavigationRule``, so macOS and iOS descend identically.
    ///
    /// Cost: deliberately NOT a snapshot. `selector(for:)` walks the entire app via
    /// ``snapshotNodes()``, which is affordable once per CAPTURE but not here —
    /// this runs on every selection change, including each step of a rapid
    /// Parent/Child exploration. Instead the bound element's frame CENTRE gives a
    /// containment descent from its window (the same trick ``hitBeneathOverlay(_:)``
    /// uses) to find the live handle, then only that element's own subtree is
    /// visited, and each branch of it stops at the first meaningful node.
    static func children(of target: Element, near hint: CGPoint?) -> [Element] {
        let centre = CGPoint(x: target.frame.midX, y: target.frame.midY)
        guard let node = locate(target, at: centre) else { return [] }
        let windowFrame = ancestorChain(from: node)
            .first { string($0, kAXRoleAttribute) == "AXWindow" }
            .map(frameScreen(of:))

        var found: [AXUIElement] = []
        collectNearestMeaningful(under: node, windowFrame: windowFrame, depth: 0, into: &found)
        let candidates = found.map {
            ChildCandidate(element: candidate(for: $0, windowFrame: windowFrame), frame: frameScreen(of: $0))
        }
        return ChildNavigationRule.order(candidates, near: hint).map {
            element(for: found[$0], ancestorChain: ancestorChain(from: found[$0]))
        }
    }

    /// The live AX handle behind a public ``Element``, found by descending the
    /// containing window along frames that contain the element's own centre.
    /// Bounded by tree DEPTH rather than tree size, which is the whole point: an
    /// identity map would have to be rebuilt from a full snapshot every time the
    /// tree changed.
    ///
    /// Returns nil when the element has left the tree, or when a clipping ancestor
    /// does not contain the element's centre. Both degrade the same benign way —
    /// no children, so the composer's Child control stays disabled — rather than
    /// offering a descent into something that is not the bound element.
    private static func locate(_ element: Element, at centre: CGPoint) -> AXUIElement? {
        let app = appElement()
        let windows = elementArray(app, kAXWindowsAttribute).filter { !isOverlayWindow($0) }
        guard let window = windows.first(where: { frameScreen(of: $0).contains(centre) }) else { return nil }
        return descend(window, matching: element, containing: centre, depth: 0)
    }

    private static func descend(
        _ node: AXUIElement,
        matching element: Element,
        containing point: CGPoint,
        depth: Int
    ) -> AXUIElement? {
        if matches(node, element) { return node }
        guard depth < maxDepth else { return nil }
        for child in elementArray(node, kAXChildrenAttribute) {
            if isOverlayWindow(child) || isChrome(child) { continue }
            let frame = frameScreen(of: child)
            guard frame.width > 0, frame.height > 0, frame.contains(point) else { continue }
            if let found = descend(child, matching: element, containing: point, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Identity test for re-finding a captured ``Element``. Identifier AND role AND
    /// frame, because none alone is enough: identifiers are absent on the unseeded
    /// elements this feature exists to navigate around, roles repeat everywhere,
    /// and a coextensive background surface shares a frame with the content group
    /// in front of it (the `.axCardSurface` pattern) — matching on frame alone would
    /// silently list the wrong node's children.
    private static func matches(_ node: AXUIElement, _ element: Element) -> Bool {
        guard (string(node, kAXIdentifierAttribute) ?? "") == (element.path.last?.identifier ?? "") else {
            return false
        }
        guard (string(node, kAXRoleAttribute) ?? "") == element.role else { return false }
        let frame = frameScreen(of: node)
        // Half a point of slack: AX geometry round-trips through CGFloat conversions
        // and a strict `==` would make re-finding fail on a fractional layout.
        return abs(frame.minX - element.frame.minX) < 0.5 && abs(frame.minY - element.frame.minY) < 0.5
            && abs(frame.width - element.frame.width) < 0.5 && abs(frame.height - element.frame.height) < 0.5
    }

    /// The nearest MEANINGFUL descendants of `node`: each direct child that is a
    /// target in its own right, and for each child that is not, the meaningful
    /// nodes beneath it.
    ///
    /// Descending through unmeaningful wrappers is load-bearing, not thoroughness:
    /// a SwiftUI `VStack` materializes as an unidentified, label-less `AXGroup`, so
    /// a strict direct-children rule would find one ineligible group under most
    /// cards, filter it out, and report every card as a leaf — the Child control
    /// would be permanently disabled on exactly the UI it was built for. Each
    /// branch stops at its first meaningful node, so this is not a subtree
    /// enumeration.
    private static func collectNearestMeaningful(
        under node: AXUIElement,
        windowFrame: CGRect?,
        depth: Int,
        into found: inout [AXUIElement]
    ) {
        guard depth < maxDepth else { return }
        for child in elementArray(node, kAXChildrenAttribute) {
            // Chrome and our own overlay are rejected here as well as by
            // ``TargetCandidate/isEligibleMeaningful``: skipping the whole SUBTREE
            // matters, because a traffic light's inner glyph groups carry no chrome
            // subrole of their own and would otherwise be collected as children.
            if isOverlayWindow(child) || isChrome(child) { continue }
            let frame = frameScreen(of: child)
            let isTarget = frame.width > 0 && frame.height > 0
                && candidate(for: child, windowFrame: windowFrame).isEligibleMeaningful
            if isTarget {
                found.append(child)
            } else {
                collectNearestMeaningful(under: child, windowFrame: windowFrame, depth: depth + 1, into: &found)
            }
        }
    }

    /// Resolve `point` to a root-first ancestor chain of the deepest host element
    /// beneath the overlay, or nil when nothing is annotatable (no hit, or a hit
    /// through window chrome). Shared by ``hitTest(_:)`` and ``componentLadder(for:)``.
    private static func resolvedChain(at point: CGPoint) -> [AXUIElement]? {
        let app = appElement()
        var hit: AXUIElement?
        let deepest: AXUIElement
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
           let native = hit, !belongsToOverlayWindow(native) {
            deepest = native
        } else if let beneath = hitBeneathOverlay(point) {
            deepest = beneath
        } else {
            return nil
        }

        let chain = ancestorChain(from: deepest)
        guard !chain.isEmpty else { return nil }
        // A hit through window CHROME (the traffic lights) is not annotatable at
        // ANY level: the hit itself may be the button or one of its inner glyph
        // groups, and everything above it is the title bar / window. Two checks,
        // because the glyph groups report the WINDOW (not the button) as their
        // AX parent, so the chain scan alone can miss them — the geometric
        // backstop catches any query point inside a chrome button's frame.
        if chain.contains(where: isChrome) { return nil }
        if let window = chain.first(where: { string($0, kAXRoleAttribute) == "AXWindow" }),
           elementArray(window, kAXChildrenAttribute)
               .contains(where: { isChrome($0) && frameScreen(of: $0).contains(point) }) {
            return nil
        }
        return chain
    }

    /// REGION anchor (cli-vtrvt.2): the nearest MEANINGFUL element to a point
    /// that hit-tests to nothing (decoration, dividers, gaps beyond any
    /// container's frame). Walks the containing window's tree collecting
    /// meaningful nodes (same predicate as the hit-test, chrome and
    /// window-ghost groups excluded) and returns the one whose frame is
    /// closest to the point — smaller frame wins a distance tie, mirroring the
    /// specificity rule.
    static func regionAnchor(for point: CGPoint) -> Element? {
        let app = appElement()
        let windows = elementArray(app, kAXWindowsAttribute).filter { !isOverlayWindow($0) }
        guard let window = windows.first(where: { frameScreen(of: $0).contains(point) }) else {
            return nil
        }
        let windowFrame = frameScreen(of: window)
        var best: (element: AXUIElement, distance: CGFloat, area: CGFloat)?
        collectMeaningful(in: window, windowFrame: windowFrame, depth: 0) { candidate in
            let frame = frameScreen(of: candidate)
            let d = distance(from: point, to: frame)
            let a = frame.width * frame.height
            if best == nil || d < best!.distance || (d == best!.distance && a < best!.area) {
                best = (candidate, d, a)
            }
        }
        guard let best else { return nil }
        return element(for: best.element, ancestorChain: ancestorChain(from: best.element))
    }

    private static func collectMeaningful(
        in element: AXUIElement,
        windowFrame: CGRect,
        depth: Int,
        _ visit: (AXUIElement) -> Void
    ) {
        guard depth < maxDepth else { return }
        for child in elementArray(element, kAXChildrenAttribute) {
            if isChrome(child) { continue }
            let role = string(child, kAXRoleAttribute) ?? ""
            let ghost = role == "AXGroup"
                && (string(child, kAXIdentifierAttribute) ?? "").isEmpty
                && labelText(child).isEmpty
                && frameScreen(of: child).contains(windowFrame.insetBy(dx: 8, dy: 8))
            if !ghost, isMeaningful(child, role: role) {
                let frame = frameScreen(of: child)
                if frame.width > 0, frame.height > 0 { visit(child) }
            }
            collectMeaningful(in: child, windowFrame: windowFrame, depth: depth + 1, visit)
        }
    }

    /// Euclidean distance from `point` to the nearest edge of `rect` (0 when
    /// the rect contains the point).
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Geometric hit-test beneath the overlay. The native point query cannot see
    /// past our own full-window overlay panel, so descend the frontmost
    /// non-overlay window whose frame contains `point` to the deepest descendant
    /// that still contains it, walking `kAXChildren` by frame. `kAXWindows` is
    /// front-to-back, so the first matching window is the frontmost real target.
    private static func hitBeneathOverlay(_ point: CGPoint) -> AXUIElement? {
        let app = appElement()
        let windows = elementArray(app, kAXWindowsAttribute).filter { !isOverlayWindow($0) }
        guard let window = windows.first(where: { frameScreen(of: $0).contains(point) }) else {
            return nil
        }
        return deepestChild(of: window, containing: point, depth: 0)
    }

    /// Deepest descendant of `element` whose (non-empty) frame contains `point`.
    /// Among children containing the point, descend into the SMALLEST (most
    /// specific) one: AX child order does not reliably encode z-order, so a
    /// full-size sibling layer (a window's title-bar strip, or a card's clear
    /// accessibility surface in `.background`) must not swallow the more
    /// specific content that visually sits above it. Returns `element` itself
    /// when no child contains the point.
    private static func deepestChild(of element: AXUIElement, containing point: CGPoint, depth: Int) -> AXUIElement {
        guard depth < maxDepth else { return element }
        let candidate = elementArray(element, kAXChildrenAttribute)
            .filter {
                let frame = frameScreen(of: $0)
                return frame.width > 0 && frame.height > 0 && frame.contains(point)
            }
            .min { lhs, rhs in
                let (lhsArea, rhsArea) = (area(of: lhs), area(of: rhs))
                guard lhsArea == rhsArea else { return lhsArea < rhsArea }
                // Equal-area tie (e.g. a materialized region coextensive with a
                // card's seeded surface): CONTENT beats the surface — seeded
                // surfaces present as AXUnknown leaves and are by construction
                // the LEAST specific thing at their level.
                return surfaceRank(of: lhs) < surfaceRank(of: rhs)
            }
        guard let candidate else { return element }
        return deepestChild(of: candidate, containing: point, depth: depth + 1)
    }

    private static func area(of element: AXUIElement) -> CGFloat {
        let frame = frameScreen(of: element)
        return frame.width * frame.height
    }

    private static func surfaceRank(of element: AXUIElement) -> Int {
        string(element, kAXRoleAttribute) == "AXUnknown" ? 1 : 0
    }

    /// Climb `kAXParentAttribute` from `element` up to the window, returning the
    /// chain ordered root-first.
    private static func ancestorChain(from element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < maxDepth {
            chain.append(node)
            current = copyValue(node, kAXParentAttribute).map { unsafeDowncast($0, to: AXUIElement.self) }
            depth += 1
        }
        return chain.reversed()
    }

    /// The deepest element in the chain (closest to the hit) that is a real
    /// annotation target: actionable, or carrying an identifier, or a
    /// non-structural element with a label. Never the window or application —
    /// escalating to `AXWindow` is what made a padding/background click resolve
    /// to the whole window (and show its title in the composer header). Structural
    /// `AXGroup`s are skipped unless they are actionable or identified, so a
    /// near-miss lands on the nearest meaningful control rather than a wrapper.
    /// Window-chrome subroles: the traffic lights (+ the full-screen affordance).
    /// They are real, actionable `AXButton`s, but they are the WINDOW's chrome,
    /// not app content — their selectors locate no app code, so the hit-test must
    /// never offer them as annotation targets. `TargetCandidate.isChrome` carries
    /// this into the shared ``AnnotationTargetRule``, which excludes chrome from
    /// both the actionable and the meaningful pass; the geometric backstop in
    /// ``resolvedChain(at:)`` catches any query point inside a chrome button's
    /// frame even when the AX parent chain hides it.
    static let chromeSubroles: Set<String> = [
        kAXCloseButtonSubrole as String,
        kAXMinimizeButtonSubrole as String,
        kAXZoomButtonSubrole as String,
        kAXFullScreenButtonSubrole as String,
    ]

    /// True when `subrole` marks window chrome (see ``chromeSubroles``).
    static func isWindowChrome(subrole: String) -> Bool {
        chromeSubroles.contains(subrole)
    }

    private static func isChrome(_ element: AXUIElement) -> Bool {
        isWindowChrome(subrole: string(element, kAXSubroleAttribute) ?? "")
    }

    /// The annotation target at the hit, per the shared ``AnnotationTargetRule``:
    /// the deepest ACTIONABLE control (a click inside a button binds to the
    /// button, not its label glyph), else the deepest MEANINGFUL element (a
    /// standalone text/label/value leaf, which the selector engine then anchors to
    /// its nearest identified ancestor). The AX attributes are read once into a
    /// pure ``TargetCandidate`` chain so the decision itself is unit-tested
    /// independent of the AX API.
    private static func annotationTarget(in rootFirstChain: [AXUIElement]) -> AXUIElement? {
        let windowFrame = rootFirstChain.first { string($0, kAXRoleAttribute) == "AXWindow" }
            .map(frameScreen(of:))
        let candidates = rootFirstChain.map { candidate(for: $0, windowFrame: windowFrame) }
        guard let index = AnnotationTargetRule.targetIndex(in: candidates) else { return nil }
        return rootFirstChain[index]
    }

    /// Read one AX element's target-relevant facts into a pure ``TargetCandidate``.
    private static func candidate(for element: AXUIElement, windowFrame: CGRect?) -> TargetCandidate {
        let role = string(element, kAXRoleAttribute) ?? ""
        let identifier = string(element, kAXIdentifierAttribute) ?? ""
        let label = labelText(element)
        let value = string(element, kAXValueAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let isGhost = role == "AXGroup" && identifier.isEmpty && label.isEmpty
            && (windowFrame.map { frameScreen(of: element).contains($0.insetBy(dx: 8, dy: 8)) } ?? false)
        return TargetCandidate(
            role: role,
            identifier: identifier,
            label: label,
            value: value,
            isActionable: actionNames(element).contains(kAXPressAction as String) || actionableRoles.contains(role),
            isChrome: isWindowChrome(subrole: subrole),
            isContainerRoot: role == "AXWindow" || role == "AXApplication",
            isWindowGhost: isGhost
        )
    }

    /// Whether a node is an annotation target in its own right: an identifier,
    /// a title/description label, a string VALUE, or an action. Counting
    /// AXValue is load-bearing: plain SwiftUI `Text` materializes AXStaticText
    /// with the string in AXValue and EMPTY title/description, so a
    /// title-only notion of "labeled" walks straight past every text leaf and
    /// resolves its identified ancestor (the whole page) instead.
    private static func isMeaningful(_ element: AXUIElement, role: String) -> Bool {
        if !(string(element, kAXIdentifierAttribute) ?? "").isEmpty { return true }
        if !labelText(element).isEmpty { return true }
        if !(string(element, kAXValueAttribute) ?? "").isEmpty { return true }
        return actionNames(element).contains(kAXPressAction as String)
            || actionableRoles.contains(role)
    }

    /// Build a public ``Element`` for `target`, computing its path from the
    /// supplied root-first ancestor chain (with same-role sibling indices).
    private static func element(for target: AXUIElement, ancestorChain rootFirst: [AXUIElement]) -> Element {
        var path: [PathComponent] = []
        for (depth, element) in rootFirst.enumerated() {
            let role = string(element, kAXRoleAttribute) ?? "AXUnknown"
            let index: Int
            if depth == 0 {
                index = 0
            } else {
                let siblings = elementArray(rootFirst[depth - 1], kAXChildrenAttribute)
                index = indexAmongRole(element, in: siblings, role: role)
            }
            path.append(component(for: element, indexAmongRole: index, roleHint: role))
            if CFEqual(element, target) { break }
        }

        let identifier = string(target, kAXIdentifierAttribute) ?? ""
        let role = string(target, kAXRoleAttribute) ?? ""
        let subrole = string(target, kAXSubroleAttribute) ?? ""
        let frame = frameScreen(of: target)
        return Element(
            id: identifier.isEmpty ? path.map(\.pathDescription).joined(separator: "/") : identifier,
            role: role,
            type: subrole.isEmpty ? role : subrole,
            label: labelText(target),
            value: string(target, kAXValueAttribute) ?? "",
            frame: frame,
            isVisible: frame.width > 0 && frame.height > 0,
            isActionable: actionNames(target).contains(kAXPressAction as String) || actionableRoles.contains(role),
            path: path
        )
    }

    private static func indexAmongRole(_ element: AXUIElement, in siblings: [AXUIElement], role: String) -> Int {
        var index = 0
        for sibling in siblings {
            if CFEqual(sibling, element) { return index }
            if (string(sibling, kAXRoleAttribute) ?? "AXUnknown") == role { index += 1 }
        }
        return index
    }

    // MARK: - Selector generation

    /// Generate a round-tripping selector string for `element`, resolved against
    /// a fresh snapshot of the tree. When generation fails — the element left the
    /// tree between capture and export — fall back to the path-derived selector
    /// (``Selector/fromPath(of:)``), never a synthetic `#displayID` slash-path
    /// that no node's `accessibilityIdentifier` carries.
    static func selector(for element: Element) -> String {
        let roots = snapshotNodes()
        if let selector = SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots) {
            return selector.rendered
        }
        return Selector.fromPath(of: element).rendered
    }

    // MARK: - AX readers

    private static func labelText(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyValue(element, attribute) as? [AXUIElement] ?? []
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var result = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &result) ? result : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var result = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &result) ? result : nil
    }

    private static func frameScreen(of element: AXUIElement) -> CGRect {
        let origin = point(element, kAXPositionAttribute) ?? .zero
        let dimensions = size(element, kAXSizeAttribute) ?? .zero
        return CGRect(origin: origin, size: dimensions)
    }
}
#endif
