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
            path: path
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

    /// Snapshot every window of the host app as an ``AXElementNode`` tree.
    static func snapshotNodes() -> [AXElementNode] {
        let app = appElement()
        return elementArray(app, kAXWindowsAttribute).map { window in
            buildNode(window, selfComponent: component(for: window, indexAmongRole: 0), parentPath: [], depth: 0)
        }
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
    /// (identifier or label), per docs/spike-ax-pointquery.md. The overlay window
    /// must be excluded by the caller (marked non-accessibility) so it never
    /// resolves to itself.
    static func hitTest(_ point: CGPoint) -> Element? {
        let app = appElement()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let deepest = hit
        else { return nil }

        let chain = ancestorChain(from: deepest)
        guard !chain.isEmpty else { return nil }
        let target = nearestIdentified(in: chain) ?? deepest
        return element(for: target, ancestorChain: chain)
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

    /// The deepest element in the chain (closest to the hit) that carries a
    /// non-empty identifier or label.
    private static func nearestIdentified(in rootFirstChain: [AXUIElement]) -> AXUIElement? {
        for element in rootFirstChain.reversed() {
            let identifier = string(element, kAXIdentifierAttribute) ?? ""
            let label = labelText(element)
            if !identifier.isEmpty || !label.isEmpty { return element }
        }
        return nil
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
