import Foundation

/// The annotation-relevant facts about one node in a hit's ancestor chain, read
/// once by a platform adapter so the target rule stays pure — testable without
/// the AX API or UIKit. Field names mirror ``SelectorMatchable`` where they
/// overlap.
public struct TargetCandidate: Sendable, Hashable {
    public let role: String
    public let identifier: String
    public let label: String
    public let value: String
    /// Exposes a press/edit action, or is one of the actionable roles.
    public let isActionable: Bool
    /// Window chrome (the traffic lights): a real, actionable button, but the
    /// WINDOW's chrome, not app content — its selector locates no app code, so it
    /// is never an annotation target.
    public let isChrome: Bool
    /// The window or application container. A background click must never resolve
    /// to the whole window/app.
    public let isContainerRoot: Bool
    /// A structural, unidentified, content-less group spanning (nearly) the whole
    /// window — an `NSHostingView` root `AXGroup`, the window in disguise.
    public let isWindowGhost: Bool

    public init(
        role: String,
        identifier: String = "",
        label: String = "",
        value: String = "",
        isActionable: Bool = false,
        isChrome: Bool = false,
        isContainerRoot: Bool = false,
        isWindowGhost: Bool = false
    ) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.value = value
        self.isActionable = isActionable
        self.isChrome = isChrome
        self.isContainerRoot = isContainerRoot
        self.isWindowGhost = isWindowGhost
    }

    /// An actionable control eligible to be a target (not chrome, not the
    /// window/app root).
    var isEligibleActionable: Bool {
        isActionable && !isChrome && !isContainerRoot
    }

    /// A meaningful element eligible to be a target: it carries an identifier, a
    /// label, a displayed value, or an action, and is not chrome, a container
    /// root, or a window-spanning ghost group.
    var isEligibleMeaningful: Bool {
        guard !isChrome, !isContainerRoot, !isWindowGhost else { return false }
        return !identifier.isEmpty || !label.isEmpty || !value.isEmpty || isActionable
    }
}

/// The unified annotation target rule (see DECISIONS.md → "Annotation target
/// rule"). Given the hit's ancestor chain, pick which node the annotation binds
/// to. Pure and platform-independent: both the macOS AX adapter and the iOS
/// view-tree adapter build a `[TargetCandidate]` chain and call ``targetIndex``,
/// so they resolve a click identically and the rule is unit-tested on its own.
public enum AnnotationTargetRule {
    /// Index in the root-first `chain` of the annotation target, or nil when
    /// nothing at the point is annotatable.
    ///
    /// The deepest ACTIONABLE control wins — a click inside a button binds to the
    /// button, not the static-text glyph that is its deepest descendant. Failing
    /// that, the deepest MEANINGFUL element — a standalone text/label/value leaf
    /// is annotated in its own right, and the selector engine anchors it to its
    /// nearest identified ancestor.
    public static func targetIndex(in chain: [TargetCandidate]) -> Int? {
        for i in chain.indices.reversed() where chain[i].isEligibleActionable {
            return i
        }
        for i in chain.indices.reversed() where chain[i].isEligibleMeaningful {
            return i
        }
        return nil
    }

    /// The component-widening ladder for `chain`: the target itself first, then
    /// each strictly-shallower identified ancestor, broadest last. Drives
    /// selection widening (a click-again steps up to the enclosing component).
    /// Empty when nothing is annotatable.
    public static func wideningLadder(in chain: [TargetCandidate]) -> [Int] {
        guard let target = targetIndex(in: chain) else { return [] }
        var ladder = [target]
        for i in stride(from: target - 1, through: 0, by: -1) {
            let c = chain[i]
            if c.isContainerRoot { break } // stop at the window; it is never a target
            if !c.identifier.isEmpty, !c.isWindowGhost { ladder.append(i) }
        }
        return ladder
    }
}
