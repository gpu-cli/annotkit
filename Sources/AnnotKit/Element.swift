import CoreGraphics
import Foundation

/// A single addressable UI element, captured from whichever ``ElementSource``
/// is active. This is the public, `Sendable` value type that flows into notes
/// and the overlay. The live platform handle (an `AXUIElement` on macOS, a
/// `UIView` on the view-tree path) is held internally by the adapter and never
/// crosses an actor boundary, mirroring the `AXNode` split that already exists
/// in VirgilHUD's `InspectIntrospection`.
public struct Element: Sendable, Hashable, Identifiable {
    /// Stable identifier: the element's `accessibilityIdentifier` when present,
    /// otherwise a synthesized path-based id. This is the primary selector key.
    public let id: String

    /// Accessibility role, for example `AXButton`, `AXStaticText`.
    public let role: String

    /// Finer type label: the AX subrole when present, or the concrete view
    /// class name when the view-tree source is used (the AX API cannot supply
    /// a class name, which is one reason the view-tree source exists).
    public let type: String

    /// Accessibility label or title.
    public let label: String

    /// Displayed value text, if any.
    public let value: String

    /// Frame in screen coordinates, top-left origin (AX convention).
    public let frame: CGRect

    public let isVisible: Bool

    /// Whether the element exposes a press or edit action.
    public let isActionable: Bool

    /// Ancestor chain from the containing window down to this element,
    /// used to render the human-readable Element Path and to generate a
    /// stable role-path selector. See ``Selector``.
    public let path: [PathComponent]

    /// Child elements. Populated for a tree snapshot (``WindowSnapshot/root``);
    /// empty for a single located element returned by a hit test. Carrying the
    /// subtree lets a consumer map ``Element`` onto a tree node type (for
    /// example VirgilHUD's proto `Node`) without losing structure.
    public let children: [Element]

    public init(
        id: String,
        role: String,
        type: String,
        label: String,
        value: String,
        frame: CGRect,
        isVisible: Bool,
        isActionable: Bool,
        path: [PathComponent],
        children: [Element] = []
    ) {
        self.id = id
        self.role = role
        self.type = type
        self.label = label
        self.value = value
        self.frame = frame
        self.isVisible = isVisible
        self.isActionable = isActionable
        self.path = path
        self.children = children
    }
}

/// One step in an element's ancestor chain. `index` is the element's position
/// among its same-role siblings (not among all siblings), which is the value a
/// role-path selector must encode so it round-trips the resolver.
public struct PathComponent: Sendable, Hashable {
    public let role: String
    public let label: String
    public let identifier: String?
    /// Zero-based index among siblings that share this `role`.
    public let indexAmongRole: Int

    public init(role: String, label: String, identifier: String?, indexAmongRole: Int) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.indexAmongRole = indexAmongRole
    }

    /// Human-readable Element Path segment, for example `AXButton[0]` or
    /// `#Settings.Models`.
    public var pathDescription: String {
        if let identifier, !identifier.isEmpty { return "#\(identifier)" }
        return "\(role)[\(indexAmongRole)]"
    }
}

/// A PNG capture of an element or window. `Sendable` so it can be handed back
/// across the actor boundary from the async screenshot path.
public struct CapturedImage: Sendable, Hashable {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One inspectable window plus its root element, returned by
/// ``ElementSource/snapshot()``.
public struct WindowSnapshot: Sendable, Hashable {
    public let title: String
    public let frame: CGRect
    public let isOnscreen: Bool
    public let root: Element

    public init(title: String, frame: CGRect, isOnscreen: Bool, root: Element) {
        self.title = title
        self.frame = frame
        self.isOnscreen = isOnscreen
        self.root = root
    }
}
