import XCTest
@testable import AnnotKit

/// A value-type node for exercising the selector engine without any platform
/// dependency. The macOS/iOS adapters conform their real node types the same way.
private struct TestNode: SelectorMatchable {
    var selectorIdentifier: String = ""
    var selectorLabel: String = ""
    var selectorType: String = ""
    var selectorRole: String = ""
    var selectorText: String = ""
    var selectorChildren: [TestNode] = []
}

final class SelectorEngineTests: XCTestCase {
    /// A button with an accessibilityIdentifier generates `#id` and round-trips.
    func testGeneratePrefersIdentifierAndRoundTrips() {
        let button = TestNode(selectorIdentifier: "Save", selectorRole: "AXButton")
        let group = TestNode(selectorRole: "AXGroup", selectorChildren: [button])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [group])

        let selector = SelectorEngine.generate(
            forFirstMatching: { $0.selectorIdentifier == "Save" }, in: [window]
        )
        XCTAssertEqual(selector?.rendered, "#Save")

        let resolved = SelectorEngine.resolve(selector!, in: [window])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.selectorIdentifier, "Save")
    }

    /// A uniquely-labelled element with no identifier generates `@label`.
    func testGenerateFallsBackToLabelAndRoundTrips() {
        let target = TestNode(selectorLabel: "Upgrade to Pro", selectorRole: "AXButton")
        let other = TestNode(selectorLabel: "Cancel", selectorRole: "AXButton")
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [other, target])

        let selector = SelectorEngine.generate(
            forFirstMatching: { $0.selectorLabel == "Upgrade to Pro" }, in: [window]
        )
        XCTAssertEqual(selector?.rendered, "@\"Upgrade to Pro\"")

        let resolved = SelectorEngine.resolve(selector!, in: [window])
        XCTAssertEqual(resolved.first?.selectorLabel, "Upgrade to Pro")
    }

    /// With no identifier, no unique label, and no identified ancestor, a
    /// globally-unique displayed text is preferred to a bare positional index — it
    /// still lets the agent grep for the string. (Superseded the old
    /// `AXButton[2]` expectation: text carries code-locating signal that a global
    /// role index does not.)
    func testGeneratePrefersUniqueTextToGlobalRoleIndex() {
        let b0 = TestNode(selectorRole: "AXButton", selectorText: "b0")
        let b1 = TestNode(selectorRole: "AXButton", selectorText: "b1")
        let b2 = TestNode(selectorRole: "AXButton", selectorText: "b2")
        let left = TestNode(selectorRole: "AXGroup", selectorChildren: [b0, b1])
        let right = TestNode(selectorRole: "AXGroup", selectorChildren: [b2])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [left, right])

        let selector = SelectorEngine.generate(
            forFirstMatching: { $0.selectorText == "b2" }, in: [window]
        )
        XCTAssertEqual(selector?.rendered, "text=\"b2\"")

        let resolved = SelectorEngine.resolve(selector!, in: [window])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.selectorText, "b2")
    }

    /// Only when an element carries NO identity of any kind (no id, no label, no
    /// unique text, no identified ancestor) does generation fall to a global
    /// `Role[n]`, whose index is the resolver's own preorder match position.
    func testGenerateFallsToGlobalRoleIndexAsLastResort() {
        let a = TestNode(selectorType: "a", selectorRole: "AXButton")
        let b = TestNode(selectorType: "b", selectorRole: "AXButton")
        let c = TestNode(selectorType: "c", selectorRole: "AXButton")
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [a, b, c])

        let selector = SelectorEngine.generate(forFirstMatching: { $0.selectorType == "c" }, in: [window])
        XCTAssertEqual(selector?.rendered, "AXButton[2]")
        XCTAssertEqual(SelectorEngine.resolve(selector!, in: [window]).first?.selectorType, "c")
    }

    /// A leaf with no identifier of its own is ANCHORED to its nearest identified
    /// ancestor via a label unique WITHIN that component, even when the same label
    /// occurs in another component (so a bare `@label` would be ambiguous).
    func testAnchorsLeafToIdentifiedAncestorByLabel() {
        // "Save" appears in two seeded cards; the target is the second one, so a
        // bare @Save resolves to the FIRST and must fall through to the anchor.
        let decoy = TestNode(selectorLabel: "Save", selectorType: "decoy", selectorRole: "AXButton")
        let target = TestNode(selectorLabel: "Save", selectorType: "target", selectorRole: "AXButton")
        let cardA = TestNode(selectorIdentifier: "Settings.Models", selectorRole: "AXGroup", selectorChildren: [decoy])
        let cardB = TestNode(selectorIdentifier: "Settings.Other", selectorRole: "AXGroup", selectorChildren: [target])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [cardA, cardB])

        let selector = SelectorEngine.generate(forFirstMatching: { $0.selectorType == "target" }, in: [window])
        XCTAssertEqual(selector?.rendered, "#Settings.Other >> @Save")
        XCTAssertEqual(SelectorEngine.resolve(selector!, in: [window]).first?.selectorType, "target")
    }

    /// A plain-text leaf (no label, only a displayed value) anchors to its
    /// identified ancestor via `text="…"` when that text is not globally unique.
    func testAnchorsTextLeafToIdentifiedAncestor() {
        let decoy = TestNode(selectorType: "decoy", selectorRole: "AXStaticText", selectorText: "Hello")
        let target = TestNode(selectorType: "target", selectorRole: "AXStaticText", selectorText: "Hello")
        let cardA = TestNode(selectorIdentifier: "Card.A", selectorRole: "AXGroup", selectorChildren: [decoy])
        let cardB = TestNode(selectorIdentifier: "Card.B", selectorRole: "AXGroup", selectorChildren: [target])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [cardA, cardB])

        let selector = SelectorEngine.generate(forFirstMatching: { $0.selectorType == "target" }, in: [window])
        XCTAssertEqual(selector?.rendered, "#Card.B >> text=\"Hello\"")
        XCTAssertEqual(SelectorEngine.resolve(selector!, in: [window]).first?.selectorType, "target")
    }

    /// When a leaf has neither label nor text, the role index is scoped to the
    /// identified ancestor's subtree — NOT a global preorder index. A same-role
    /// element outside the component must not shift the index.
    func testAnchoredRoleIndexIsScopedToComponent() {
        let pre = TestNode(selectorType: "pre", selectorRole: "AXButton") // outside the card
        let b0 = TestNode(selectorType: "b0", selectorRole: "AXButton")
        let b1 = TestNode(selectorType: "b1", selectorRole: "AXButton")
        let b2 = TestNode(selectorType: "b2", selectorRole: "AXButton")
        let card = TestNode(selectorIdentifier: "Card", selectorRole: "AXGroup", selectorChildren: [b0, b1, b2])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [pre, card])

        let selector = SelectorEngine.generate(forFirstMatching: { $0.selectorType == "b1" }, in: [window])
        // Component-local index 1, NOT the global preorder index 2 (pre=0,b0=1,b1=2).
        XCTAssertEqual(selector?.rendered, "#Card >> AXButton[1]")
        XCTAssertEqual(SelectorEngine.resolve(selector!, in: [window]).first?.selectorType, "b1")
    }

    /// The stability property the old global `Role[n]` lacked: an anchored,
    /// component-scoped selector survives an unrelated same-role insertion
    /// elsewhere in the window, and a GLOBAL index would not.
    func testAnchoredSelectorSurvivesOutOfScopeMutation() {
        func window(withInjected injected: Bool) -> TestNode {
            let b0 = TestNode(selectorType: "b0", selectorRole: "AXButton")
            let b1 = TestNode(selectorType: "b1", selectorRole: "AXButton")
            let card = TestNode(selectorIdentifier: "Card", selectorRole: "AXGroup", selectorChildren: [b0, b1])
            var outside: [TestNode] = [TestNode(selectorType: "pre", selectorRole: "AXButton")]
            if injected { outside.append(TestNode(selectorType: "injected", selectorRole: "AXButton")) }
            return TestNode(selectorRole: "AXWindow", selectorChildren: outside + [card])
        }

        let selector = SelectorEngine.generate(
            forFirstMatching: { $0.selectorType == "b1" }, in: [window(withInjected: false)]
        )
        XCTAssertEqual(selector?.rendered, "#Card >> AXButton[1]")

        // Insert an unrelated AXButton OUTSIDE the card: the anchored selector must
        // still resolve to b1 (a global AXButton[n] would now be off by one).
        let resolved = SelectorEngine.resolve(selector!, in: [window(withInjected: true)])
        XCTAssertEqual(resolved.first?.selectorType, "b1", "out-of-scope change must not retarget an anchored selector")
    }

    /// Ambiguous overlapping siblings (same role, no id/label/text) must still
    /// each generate a distinct, round-tripping selector rather than crashing or
    /// collapsing onto one another.
    func testAmbiguousSiblingsEachRoundTrip() {
        let a = TestNode(selectorType: "a", selectorRole: "AXButton")
        let b = TestNode(selectorType: "b", selectorRole: "AXButton")
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [a, b])

        for marker in ["a", "b"] {
            let selector = SelectorEngine.generate(forFirstMatching: { $0.selectorType == marker }, in: [window])
            XCTAssertNotNil(selector, "no selector for \(marker)")
            XCTAssertEqual(SelectorEngine.resolve(selector!, in: [window]).first?.selectorType, marker)
        }
    }

    /// The path fallback (used when live generation fails) never emits a synthetic
    /// slash-path `#id`; it anchors to the deepest identified path component.
    func testPathFallbackAnchorsAndNeverEmitsSlashPath() {
        // Own identifier -> `#id`.
        let seeded = Element(
            id: "Settings.Save", role: "AXButton", type: "AXButton", label: "Save", value: "",
            frame: .zero, isVisible: true, isActionable: true,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXButton", label: "Save", identifier: "Settings.Save", indexAmongRole: 0),
            ]
        )
        XCTAssertEqual(Selector.fromPath(of: seeded).rendered, "#Settings.Save")

        // No own id, identified ancestor -> `#ancestor >> role`.
        let child = Element(
            id: "AXWindow[0]/#Settings.Models/AXStaticText[0]", role: "AXStaticText", type: "AXStaticText",
            label: "", value: "Hello", frame: .zero, isVisible: true, isActionable: false,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXGroup", label: "", identifier: "Settings.Models", indexAmongRole: 0),
                PathComponent(role: "AXStaticText", label: "", identifier: nil, indexAmongRole: 0),
            ]
        )
        let fallback = Selector.fromPath(of: child).rendered
        XCTAssertEqual(fallback, "#Settings.Models >> AXStaticText")
        XCTAssertFalse(fallback.contains("/"), "fallback must never emit a slash-joined path id")
    }

    /// Every node in a mixed tree must round-trip: generate then resolve lands
    /// back on the same node. This is the core correctness property.
    func testEveryNodeRoundTrips() {
        let nodes = (0..<4).map { TestNode(selectorRole: "AXButton", selectorText: "t\($0)") }
        let labelled = TestNode(selectorLabel: "Unique", selectorRole: "AXStaticText", selectorText: "lbl")
        let ided = TestNode(selectorIdentifier: "Pill", selectorRole: "AXImage", selectorText: "pill")
        let window = TestNode(
            selectorRole: "AXWindow",
            selectorChildren: nodes + [labelled, ided]
        )

        for marker in ["t0", "t1", "t2", "t3", "lbl", "pill"] {
            let selector = SelectorEngine.generate(
                forFirstMatching: { $0.selectorText == marker }, in: [window]
            )
            XCTAssertNotNil(selector, "no selector generated for \(marker)")
            let resolved = SelectorEngine.resolve(selector!, in: [window])
            XCTAssertEqual(resolved.first?.selectorText, marker, "round-trip failed for \(marker)")
        }
    }

    func testParseRenderSymmetry() {
        for raw in ["#Pill", "@Settings", "@\"Label With Spaces\"", "AXButton", "AXButton[2]",
                    "#Nav.Settings >> AXButton", "text=\"hello\""] {
            XCTAssertEqual(Selector.parse(raw).rendered, raw, "round-trip failed for \(raw)")
        }
    }

    func testDescendantChainResolves() {
        let target = TestNode(selectorRole: "AXButton", selectorText: "deep")
        let inner = TestNode(selectorIdentifier: "Panel", selectorRole: "AXGroup", selectorChildren: [target])
        let outerButton = TestNode(selectorRole: "AXButton", selectorText: "shallow")
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [outerButton, inner])

        // "#Panel >> AXButton" must select only the button inside Panel.
        let selector = Selector.parse("#Panel >> AXButton")
        let resolved = SelectorEngine.resolve(selector, in: [window])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.selectorText, "deep")
    }
}
