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
public final class MacViewTreeElementSource: ElementSource {
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
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let content = window.contentView
        else { return nil }
        let cocoaScreen = ScreenSpace.flipPoint(point, primaryHeight: Self.primaryHeight())
        let inWindow = window.convertPoint(fromScreen: cocoaScreen)
        guard let view = content.hitTest(inWindow) else { return nil }
        let target = Self.nearestIdentified(from: view) ?? view
        return Self.element(for: target)
    }

    public func selector(for element: Element) -> String {
        let roots = NSApp.windows.compactMap { $0.contentView }.map {
            Self.buildNode($0, selfComponent: Self.component(for: $0, indexAmongRole: 0), parentPath: [], depth: 0)
        }
        return SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots)?.rendered
            ?? "#\(element.id)"
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

    private static func nearestIdentified(from view: NSView) -> NSView? {
        var current: NSView? = view
        while let node = current {
            if !node.accessibilityIdentifier().isEmpty || !(node.accessibilityLabel() ?? "").isEmpty {
                return node
            }
            current = node.superview
        }
        return nil
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
#endif
