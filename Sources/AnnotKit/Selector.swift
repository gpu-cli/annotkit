import Foundation

/// A Playwright-style selector, most-stable-first, matched against an element
/// tree. The grammar mirrors VirgilHUD's `hud-inspect` so a selector emitted by
/// AnnotKit and a selector typed into `hud-inspect` mean the same thing:
///
///     #Identifier            id == Identifier
///     @Label                 label == Label
///     @"Label With Spaces"   quoted label
///     Type                   role/type == Type (e.g. AXButton)
///     text="..."             displayed value text == ...
///     Sel[n]                 the n-th match (0-based) of Sel in the search scope
///     A >> B                 B matched among descendants of A
///
/// Generation (``generate(forFirstMatching:in:)``) prefers a globally-unique
/// `#id`, then a globally-unique `@label`. Failing those it ANCHORS to the
/// deepest identified ancestor and scopes a leaf step to that component
/// (`#Settings.Models >> @Save`, `#Settings.Models >> text="…"`,
/// `#Settings.Models >> AXButton[0]` where the index is the position *within the
/// component's subtree*). Anchoring is what keeps a note bound to the right code:
/// the anchor is a seeded `accessibilityIdentifier` the agent can grep, and every
/// index is component-local, so an unrelated same-role change elsewhere in the
/// window cannot silently retarget the selector. Only when nothing in the chain
/// carries an identifier does it fall to a globally-unique `text="…"` and, as a
/// last resort, a global `Type[n]` (round-trips by construction — the index is the
/// resolver's own match position — but fragile across tree changes). The
/// human-readable Element Path, which uses sibling indices, is carried separately
/// on ``Element/path`` for readability and is not what the agent resolves against.
public struct Selector: Sendable, Hashable, CustomStringConvertible {
    public enum Simple: Sendable, Hashable {
        case identifier(String)
        case label(String)
        case type(String)
        case text(String)
    }

    public struct Step: Sendable, Hashable {
        public let simple: Simple
        /// Pick the n-th (0-based) match of `simple` within the search scope.
        public let index: Int?

        public init(simple: Simple, index: Int? = nil) {
            self.simple = simple
            self.index = index
        }
    }

    /// Steps chained by descendant (`>>`). Never empty for a valid selector.
    public let steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    public var description: String { rendered }

    // MARK: - Render

    public var rendered: String {
        steps.map(Self.render).joined(separator: " >> ")
    }

    private static func render(_ step: Step) -> String {
        let base: String
        switch step.simple {
        case .identifier(let v): base = "#\(v)"
        case .label(let v): base = v.contains(" ") ? "@\"\(v)\"" : "@\(v)"
        case .type(let v): base = v
        case .text(let v): base = "text=\"\(v)\""
        }
        if let index = step.index { return "\(base)[\(index)]" }
        return base
    }

    // MARK: - Parse

    public static func parse(_ raw: String) -> Selector {
        let steps = raw
            .components(separatedBy: " >> ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(parseStep)
        return Selector(steps: steps)
    }

    private static func parseStep(_ raw: String) -> Step {
        var token = raw
        var index: Int?

        if !token.hasPrefix("text="),
           token.hasSuffix("]"),
           let open = token.lastIndex(of: "["),
           let parsed = Int(token[token.index(after: open)..<token.index(before: token.endIndex)])
        {
            index = parsed
            token = String(token[token.startIndex..<open])
        }

        if token.hasPrefix("#") {
            return Step(simple: .identifier(String(token.dropFirst())), index: index)
        }
        if token.hasPrefix("@") {
            return Step(simple: .label(unquote(String(token.dropFirst()))), index: index)
        }
        if token.hasPrefix("text=") {
            return Step(simple: .text(unquote(String(token.dropFirst("text=".count)))), index: index)
        }
        return Step(simple: .type(token), index: index)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Path fallback

    /// Best-effort selector derived from an element's captured ancestor ``path``,
    /// used ONLY when live selector generation fails (the element left the tree
    /// between capture and export). It is deliberately never a synthetic
    /// `#a/b/c` identifier — that slash-joined path is not any node's
    /// `accessibilityIdentifier`, so it resolves to nothing and sends the agent
    /// nowhere. Instead: the element's own identifier if it has one, else an
    /// anchor to the deepest identified ancestor plus the element's role, else the
    /// role alone. Every form is a structurally valid, resolvable selector.
    public static func fromPath(of element: Element) -> Selector {
        if let own = element.path.last?.identifier, !own.isEmpty {
            return Selector(steps: [Step(simple: .identifier(own))])
        }
        if let anchor = element.path.dropLast().last(where: { !($0.identifier ?? "").isEmpty }),
           let id = anchor.identifier {
            return Selector(steps: [
                Step(simple: .identifier(id)),
                Step(simple: .type(element.role)),
            ])
        }
        return Selector(steps: [Step(simple: .type(element.role))])
    }
}

/// Anything the selector engine can match against. The macOS and iOS adapters
/// conform their internal node types to this; the same engine then serves both
/// platforms and `hud-inspect`'s extracted core.
public protocol SelectorMatchable {
    var selectorIdentifier: String { get }
    var selectorLabel: String { get }
    var selectorType: String { get }
    var selectorRole: String { get }
    var selectorText: String { get }
    var selectorChildren: [Self] { get }
}

/// The pure selector engine: resolve a selector against a tree, and generate a
/// round-tripping selector for a target. Stateless and platform-independent.
public enum SelectorEngine {
    // MARK: Resolve

    public static func resolve<N: SelectorMatchable>(_ selector: Selector, in roots: [N]) -> [N] {
        guard let first = selector.steps.first else { return [] }
        var matches = collect(first, in: preorderAll(roots))
        for step in selector.steps.dropFirst() {
            var descendants: [N] = []
            for match in matches {
                for child in match.selectorChildren {
                    descendants.append(contentsOf: preorder(child))
                }
            }
            matches = collect(step, in: descendants)
        }
        return matches
    }

    // MARK: Generate

    /// Produce the most-stable, code-locating selector that re-resolves to the
    /// first element satisfying `isTarget`. Returns nil if no element matches.
    ///
    /// The ladder, best first: unique `#id` -> unique `@label` -> anchored to the
    /// deepest identified ancestor (`#anchor >> @label`, `#anchor >> text="…"`,
    /// `#anchor >> Type[n-in-scope]`) -> unique global `text="…"` -> global
    /// `Type[n]`. Each candidate is verified to actually resolve back to the
    /// target before it is returned, so a non-unique anchor or label simply falls
    /// through to the next rung rather than producing a selector that points
    /// elsewhere.
    public static func generate<N: SelectorMatchable>(
        forFirstMatching isTarget: (N) -> Bool,
        in roots: [N]
    ) -> Selector? {
        guard let (target, ancestors) = firstWithAncestors(roots, where: isTarget) else { return nil }

        // 1. A globally-unique identifier: the most stable and most grep-able form.
        if !target.selectorIdentifier.isEmpty {
            let candidate = Selector(steps: [Step(simple: .identifier(target.selectorIdentifier))])
            if resolvesToTarget(candidate, roots, isTarget) { return candidate }
        }
        // 2. A globally-unique label.
        if !target.selectorLabel.isEmpty {
            let candidate = Selector(steps: [Step(simple: .label(target.selectorLabel))])
            if resolvesToTarget(candidate, roots, isTarget) { return candidate }
        }
        // 3. Anchor to an identified ancestor (deepest first) and scope the leaf
        //    step to that component's subtree. Component-local indices survive
        //    unrelated same-role changes elsewhere in the window.
        for anchor in ancestors.reversed() where !anchor.selectorIdentifier.isEmpty {
            let anchorStep = Step(simple: .identifier(anchor.selectorIdentifier))
            // 3a. A label unique within the component.
            if !target.selectorLabel.isEmpty {
                let candidate = Selector(steps: [anchorStep, Step(simple: .label(target.selectorLabel))])
                if resolvesToTarget(candidate, roots, isTarget) { return candidate }
            }
            // 3b. Displayed text unique within the component. Plain SwiftUI `Text`
            //     has no label, only a value, so this is the step that locates it.
            if !target.selectorText.isEmpty {
                let candidate = Selector(steps: [anchorStep, Step(simple: .text(target.selectorText))])
                if resolvesToTarget(candidate, roots, isTarget) { return candidate }
            }
            // 3c. Role index WITHIN the component's subtree (same preorder the
            //     resolver walks for a `>>` step, so it round-trips).
            let typeStep = Selector.Simple.type(target.selectorRole)
            let scope = descendantsPreorder(anchor).filter { matches($0, typeStep) }
            if let k = scope.firstIndex(where: isTarget) {
                let candidate = Selector(steps: [anchorStep, Step(simple: typeStep, index: k)])
                if resolvesToTarget(candidate, roots, isTarget) { return candidate }
            }
        }
        // 4. No identified ancestor anywhere: a globally-unique text still carries
        //    grep signal, so prefer it to a bare positional index.
        if !target.selectorText.isEmpty {
            let candidate = Selector(steps: [Step(simple: .text(target.selectorText))])
            if resolvesToTarget(candidate, roots, isTarget) { return candidate }
        }
        // 5. Last resort: a global role index. Round-trips by construction, but is
        //    fragile — reaching here means the element carries no identity at all.
        let all = preorderAll(roots)
        let typeStep = Selector.Simple.type(target.selectorRole)
        let scope = all.filter { matches($0, typeStep) }
        if let k = scope.firstIndex(where: isTarget) {
            return Selector(steps: [Step(simple: typeStep, index: k)])
        }
        return nil
    }

    private static func resolvesToTarget<N: SelectorMatchable>(
        _ selector: Selector, _ roots: [N], _ isTarget: (N) -> Bool
    ) -> Bool {
        let resolved = resolve(selector, in: roots)
        return resolved.first.map(isTarget) ?? false
    }

    // MARK: Internals

    private static func collect<N: SelectorMatchable>(_ step: Selector.Step, in nodes: [N]) -> [N] {
        let filtered = nodes.filter { matches($0, step.simple) }
        guard let index = step.index else { return filtered }
        return (index >= 0 && index < filtered.count) ? [filtered[index]] : []
    }

    private static func matches<N: SelectorMatchable>(_ node: N, _ simple: Selector.Simple) -> Bool {
        switch simple {
        case .identifier(let v): return node.selectorIdentifier == v
        case .label(let v): return node.selectorLabel == v
        case .type(let v): return node.selectorType == v || node.selectorRole == v
        case .text(let v): return node.selectorText == v
        }
    }

    /// Preorder-first node satisfying `isTarget`, together with its ancestor chain
    /// (root-first, EXCLUDING the node itself). Same node `preorderAll(...).first`
    /// would find; the chain is what lets generation anchor to an identified
    /// ancestor without a parent pointer on ``SelectorMatchable``.
    private static func firstWithAncestors<N: SelectorMatchable>(
        _ roots: [N], where isTarget: (N) -> Bool
    ) -> (node: N, ancestors: [N])? {
        func walk(_ node: N, _ ancestors: [N]) -> (N, [N])? {
            if isTarget(node) { return (node, ancestors) }
            let childAncestors = ancestors + [node]
            for child in node.selectorChildren {
                if let found = walk(child, childAncestors) { return found }
            }
            return nil
        }
        for root in roots {
            if let found = walk(root, []) { return found }
        }
        return nil
    }

    /// Descendants of `node` in the exact preorder the resolver uses for an
    /// `A >> B` step (each child's subtree in order), EXCLUDING `node` itself.
    private static func descendantsPreorder<N: SelectorMatchable>(_ node: N) -> [N] {
        var result: [N] = []
        for child in node.selectorChildren {
            result.append(contentsOf: preorder(child))
        }
        return result
    }

    private static func preorderAll<N: SelectorMatchable>(_ roots: [N]) -> [N] {
        var result: [N] = []
        for root in roots {
            result.append(contentsOf: preorder(root))
        }
        return result
    }

    private static func preorder<N: SelectorMatchable>(_ node: N) -> [N] {
        var result: [N] = [node]
        for child in node.selectorChildren {
            result.append(contentsOf: preorder(child))
        }
        return result
    }

    private typealias Step = Selector.Step
}
