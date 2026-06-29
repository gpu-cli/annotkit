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
public final class IOSElementSource: ElementSource {
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
        guard let window = Self.keyWindow else { return nil }
        let inWindow = window.convert(point, from: nil)
        guard let view = window.hitTest(inWindow, with: nil) else { return nil }
        let target = Self.nearestIdentified(from: view) ?? view
        return Self.element(for: target)
    }

    public func selector(for element: Element) -> String {
        let roots = Self.windows().map {
            Self.buildNode($0, selfComponent: Self.component(for: $0, indexAmongRole: 0), parentPath: [], depth: 0)
        }
        return SelectorEngine.generate(forFirstMatching: { $0.id == element.id }, in: roots)?.rendered
            ?? "#\(element.id)"
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

    private static func nearestIdentified(from view: UIView) -> UIView? {
        var current: UIView? = view
        while let node = current {
            if !(node.accessibilityIdentifier ?? "").isEmpty || !(node.accessibilityLabel ?? "").isEmpty {
                return node
            }
            current = node.superview
        }
        return nil
    }

    // MARK: - Window helpers

    private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
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
#endif
