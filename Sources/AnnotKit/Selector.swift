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
/// Generation (``generate(forFirstMatching:in:)``) prefers a unique `#id`, then a
/// unique `@label`, then falls back to a single `Type[n]` step whose index is the
/// element's position among same-role matches in the tree's preorder. That last
/// form round-trips the resolver *by construction*: the index is defined as the
/// resolver's own match position, so re-resolving always lands on the same
/// element. (The human-readable Element Path, which uses sibling indices, is
/// carried separately on ``Element/path`` for readability and is not what the
/// agent resolves against.)
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

    /// Produce the most-stable selector that re-resolves to the first element
    /// satisfying `isTarget`. Returns nil if no element matches.
    public static func generate<N: SelectorMatchable>(
        forFirstMatching isTarget: (N) -> Bool,
        in roots: [N]
    ) -> Selector? {
        let all = preorderAll(roots)
        guard let target = all.first(where: isTarget) else { return nil }

        if !target.selectorIdentifier.isEmpty {
            let candidate = Selector(steps: [Step(simple: .identifier(target.selectorIdentifier))])
            if resolvesToTarget(candidate, roots, isTarget) { return candidate }
        }
        if !target.selectorLabel.isEmpty {
            let candidate = Selector(steps: [Step(simple: .label(target.selectorLabel))])
            if resolvesToTarget(candidate, roots, isTarget) { return candidate }
        }
        // Role + preorder index: index is the position among same-predicate
        // matches in the resolver's own scope, so this always round-trips.
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
