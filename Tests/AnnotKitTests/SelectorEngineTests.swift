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

    /// With no identifier and no unique label, generation uses `Role[n]` where
    /// n is the preorder index among same-role matches. This is the case the
    /// review flagged: the generated index must equal the resolver's own match
    /// position, so it round-trips.
    func testGenerateRolePreorderIndexRoundTrips() {
        // Three buttons, no ids/labels, distinguished only by text.
        let b0 = TestNode(selectorRole: "AXButton", selectorText: "b0")
        let b1 = TestNode(selectorRole: "AXButton", selectorText: "b1")
        let b2 = TestNode(selectorRole: "AXButton", selectorText: "b2")
        let left = TestNode(selectorRole: "AXGroup", selectorChildren: [b0, b1])
        let right = TestNode(selectorRole: "AXGroup", selectorChildren: [b2])
        let window = TestNode(selectorRole: "AXWindow", selectorChildren: [left, right])

        let selector = SelectorEngine.generate(
            forFirstMatching: { $0.selectorText == "b2" }, in: [window]
        )
        // b2 is the 3rd AXButton in preorder -> index 2.
        XCTAssertEqual(selector?.rendered, "AXButton[2]")

        let resolved = SelectorEngine.resolve(selector!, in: [window])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.selectorText, "b2")
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
