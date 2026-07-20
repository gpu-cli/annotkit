import XCTest
@testable import AnnotKit

/// The unified target rule, exercised on synthetic ancestor chains (root-first)
/// so the decision is verified without a live AX tree. The macOS/iOS adapters
/// build the same `[TargetCandidate]` chain from their platform node types.
final class AnnotationTargetRuleTests: XCTestCase {
    private let window = TargetCandidate(role: "AXWindow", isContainerRoot: true)

    /// A click inside a button binds to the button, NOT its deepest descendant
    /// (the static-text glyph that renders its title).
    func testActionableButtonWinsOverItsLabelGlyph() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup", identifier: "Settings.Models"),
            TargetCandidate(role: "AXButton", label: "Save", isActionable: true),
            TargetCandidate(role: "AXStaticText", value: "Save"),
        ]
        XCTAssertEqual(AnnotationTargetRule.targetIndex(in: chain), 2, "the button, not the glyph")
    }

    /// A standalone text leaf inside a seeded card is annotated in its own right —
    /// the card is not actionable, so it must not swallow the text.
    func testStandaloneTextLeafIsTargetedNotItsIdentifiedCard() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup", identifier: "Settings.Header"),
            TargetCandidate(role: "AXStaticText", value: "Welcome"),
        ]
        XCTAssertEqual(AnnotationTargetRule.targetIndex(in: chain), 2, "the text leaf")
    }

    /// A click on a card's padding (the deepest node is an empty background
    /// surface) resolves UP to the seeded card, not to nothing.
    func testPaddingResolvesToTheIdentifiedCard() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup", identifier: "Settings.Models"),
            TargetCandidate(role: "AXUnknown"), // a clear .background accessibility surface
        ]
        XCTAssertEqual(AnnotationTargetRule.targetIndex(in: chain), 1, "the card")
    }

    /// Window chrome (traffic lights) is never a target even though it is an
    /// actionable button.
    func testChromeIsNeverATarget() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup"), // title bar
            TargetCandidate(role: "AXButton", isActionable: true, isChrome: true),
        ]
        XCTAssertNil(AnnotationTargetRule.targetIndex(in: chain))
    }

    /// A window-spanning ghost group (unidentified NSHostingView root) is skipped;
    /// with nothing else meaningful the click is not annotatable.
    func testWindowGhostGroupIsSkipped() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup", isWindowGhost: true),
        ]
        XCTAssertNil(AnnotationTargetRule.targetIndex(in: chain))
    }

    func testWindowOnlyChainIsNotAnnotatable() {
        XCTAssertNil(AnnotationTargetRule.targetIndex(in: [window]))
    }

    /// Widening steps from the target up through each identified ancestor,
    /// broadest last, stopping at the window.
    func testWideningLadderClimbsIdentifiedAncestors() {
        let chain = [
            window,
            TargetCandidate(role: "AXGroup", identifier: "Settings"),
            TargetCandidate(role: "AXGroup", identifier: "Settings.Models"),
            TargetCandidate(role: "AXStaticText", value: "gpt-5"),
        ]
        // Target = the text (index 3); widen to Settings.Models (2), then Settings (1).
        XCTAssertEqual(AnnotationTargetRule.wideningLadder(in: chain), [3, 2, 1])
    }
}
