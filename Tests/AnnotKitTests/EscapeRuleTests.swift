import XCTest
@testable import AnnotKit

/// Pins the Escape precedence and the swallow contract. Both are things a human
/// tester can only check by getting into four different UI states with a keyboard,
/// and one of them (drag WITH a composer open) is easy to forget exists at all.
final class EscapeRuleTests: XCTestCase {
    // MARK: - Every state combination

    func testIdlePassesThroughWhateverElseIsTrue() {
        // The host's Escape must behave exactly as it did before AnnotKit was
        // installed. This is checked with the other two flags in every combination
        // because "not annotating" outranks them ABSOLUTELY — a leftover flag from a
        // previous session must not resurrect a handler after the mode is gone.
        for drawing in [false, true] {
            for card in [false, true] {
                XCTAssertEqual(
                    EscapeRule.resolve(isAnnotating: false, isDrawingFrame: drawing, hasOpenCard: card),
                    .passThrough,
                    "idle must never claim Escape (drawing: \(drawing), card: \(card))"
                )
            }
        }
    }

    func testAnnotatingWithNothingOpenExitsTheMode() {
        XCTAssertEqual(
            EscapeRule.resolve(isAnnotating: true, isDrawingFrame: false, hasOpenCard: false),
            .exitAnnotateMode
        )
    }

    func testAnOpenCardIsDismissedBeforeTheModeIsLeft() {
        // The half-typed comment is the only irreversible thing in the flow: a mode
        // is one click to re-enter, a draft cannot be retyped from anywhere.
        XCTAssertEqual(
            EscapeRule.resolve(isAnnotating: true, isDrawingFrame: false, hasOpenCard: true),
            .dismissCard
        )
    }

    func testAnInFlightDragIsCancelledBeforeTheModeIsLeft() {
        XCTAssertEqual(
            EscapeRule.resolve(isAnnotating: true, isDrawingFrame: true, hasOpenCard: false),
            .cancelDrag
        )
    }

    func testADragBeatsAnOpenCard() {
        // THE ordering that is easy to get backwards, and the reason the two are
        // tested together: the catcher stays live BEHIND an open composer, so a user
        // can start framing a second note while the first is still being typed. Card
        // first would throw away the draft they never touched and leave the band they
        // are actively dragging on screen.
        XCTAssertEqual(
            EscapeRule.resolve(isAnnotating: true, isDrawingFrame: true, hasOpenCard: true),
            .cancelDrag
        )
    }

    // MARK: - The swallow contract

    func testOnlyPassThroughForwardsTheEvent() {
        // AnnotKit is in-process with its host, so a handled-and-forwarded Escape is
        // delivered TWICE: the overlay leaves annotate mode while the host closes its
        // own sheet, from one press. Only the action that deliberately did nothing
        // may forward.
        XCTAssertFalse(EscapeAction.passThrough.consumesEvent)
        XCTAssertTrue(EscapeAction.cancelDrag.consumesEvent)
        XCTAssertTrue(EscapeAction.dismissCard.consumesEvent)
        XCTAssertTrue(EscapeAction.exitAnnotateMode.consumesEvent)
    }

    func testEveryResolvedActionInAnnotateModeIsConsumed() {
        // Restates the above against the RULE rather than the enum, so a future
        // action that resolves in annotate mode cannot quietly start leaking
        // keystrokes to the host.
        for drawing in [false, true] {
            for card in [false, true] {
                let action = EscapeRule.resolve(isAnnotating: true, isDrawingFrame: drawing, hasOpenCard: card)
                XCTAssertTrue(
                    action.consumesEvent,
                    "annotate mode always acts, so it must always swallow (drawing: \(drawing), card: \(card))"
                )
            }
        }
    }
}
