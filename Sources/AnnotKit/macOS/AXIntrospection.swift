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

    /// Our own application AX element, with `AXEnhancedUserInterface` set so
    /// AppKit/SwiftUI materializes the full semantic tree for us. Self-query
    /// needs no accessibility-trust prompt.
    private static func appElement() -> AXUIElement {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
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
        // Pure positional specificity: the DEEPEST meaningful node at the point
        // is the answer. Never the window or application container — escalating
        // to AXWindow is what made a background click resolve to the whole app.
        guard let target = deepestMeaningful(in: chain) else {
            return nil
        }
        return element(for: target, ancestorChain: chain)
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
    /// never offer them as annotation targets. Checked in BOTH resolvers below:
    /// `deepestNonContainer` is the fallback path, so filtering only
    /// `nearestIdentified` would just hand the rejected button back via the
    /// fallback.
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

    /// The MOST SPECIFIC annotation target at the hit: walk the chain
    /// deepest-first and return the first MEANINGFUL node (pure positional
    /// specificity — the button on a card wins at the button, the card's
    /// surface at the card's padding, the section at the section's padding;
    /// there is deliberately NO depth-walking UI).
    ///
    /// A meaningless wrapper between content and its meaningful ancestor is
    /// passed through: by containment, that ancestor is still the most
    /// specific meaningful node at the point. Skipped entirely: the window and
    /// application containers (a background click must never resolve to the
    /// whole app) and structural, unidentified, content-less groups spanning
    /// (nearly) the whole window — NSHostingView's root AXGroup is the window
    /// in disguise, detected geometrically because its frame swallows the
    /// window's frame minus a small inset.
    private static func deepestMeaningful(in rootFirstChain: [AXUIElement]) -> AXUIElement? {
        let windowFrame = rootFirstChain.first { string($0, kAXRoleAttribute) == "AXWindow" }
            .map(frameScreen(of:))
        for element in rootFirstChain.reversed() {
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXApplication" { continue }
            if role == "AXGroup",
               (string(element, kAXIdentifierAttribute) ?? "").isEmpty,
               labelText(element).isEmpty,
               let windowFrame,
               frameScreen(of: element).contains(windowFrame.insetBy(dx: 8, dy: 8)) {
                continue
            }
            if isMeaningful(element, role: role) { return element }
        }
        return nil
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
    /// a fresh snapshot of the tree. Falls back to `#displayID` if generation
    /// somehow fails (it should not for a snapshotted element).
    static func selector(for element: Element) -> String {
        let roots = snapshotNodes()
        let selector = SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots)
        return selector?.rendered ?? "#\(element.id)"
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
