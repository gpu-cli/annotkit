import CoreGraphics
import XCTest
@testable import AnnotKit

final class SelectionGestureTests: XCTestCase {
    private let start = CGPoint(x: 100, y: 100)

    // MARK: - Tool routing

    func testPointToolResolvesAZeroTravelPressToTheStartPoint() {
        // The default tool's contract: a press always selects something. Routing it
        // anywhere else makes clicking do nothing at all in annotate mode, which
        // reads as a broken feature rather than a mode.
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .point, from: start, to: start, axOrigin: .zero),
            .point(CGPoint(x: 100, y: 100))
        )
    }

    func testPointToolResolvesEvenALargeDragToTheStartPointNotAFrame() {
        // THE regression this whole feature exists to prevent: a long press-drag in
        // point mode must never become a frame. The old implicit design branched on
        // travel alone, so a user who dragged while clicking silently got a framed
        // note bound to whatever the sweep covered.
        let far = CGPoint(x: start.x + 400, y: start.y + 300)
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .point, from: start, to: far, axOrigin: .zero),
            .point(CGPoint(x: 100, y: 100)) // the PRESS point, not the release point
        )
    }

    func testPointToolAppliesTheAXOriginToTheStartPoint() {
        // Secondary-display case: the gesture is window-local, the AX query is in
        // screen space, so the origin is ADDED — the same transform the frame path
        // and the highlight use.
        XCTAssertEqual(
            SelectionGesture.resolve(
                tool: .point,
                from: start,
                to: CGPoint(x: 180, y: 160),
                axOrigin: CGPoint(x: 1512, y: 30)
            ),
            .point(CGPoint(x: 1612, y: 130))
        )
    }

    func testFrameToolResolvesAZeroTravelPressToNothing() {
        // Strict separation: in frame mode a plain click does NOT fall back to point
        // selection. It also could not usefully: `select(inAXRect:)` returns nil for
        // a zero-area rect, so there is nothing to resolve either way.
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .frame, from: start, to: start, axOrigin: .zero),
            .none
        )
    }

    func testFrameToolResolvesABelowThresholdJitterToNothing() {
        // The dangerous case, and why the threshold survived the redesign: a 3-point
        // wobble is NOT zero-area, so nothing downstream rejects it. It would resolve
        // to whatever container the pointer sat in and plant a plausible-looking note
        // the user never framed — worse than no note, because nobody re-checks it.
        let below = CGPoint(x: start.x + SelectionGesture.minimumTravel - 0.5, y: start.y)
        XCTAssertEqual(SelectionGesture.resolve(tool: .frame, from: start, to: below, axOrigin: .zero), .none)
    }

    func testFrameToolResolvesExactlyTheThresholdToNothing() {
        // The boundary belongs to the branch that does NOTHING. Between "a doubtful
        // press plants a note" and "a doubtful press costs a second drag", the second
        // is recoverable and the first is not — and the crosshair already tells the
        // user this mode wants a real drag.
        let exact = CGPoint(x: start.x + SelectionGesture.minimumTravel, y: start.y)
        XCTAssertEqual(SelectionGesture.resolve(tool: .frame, from: start, to: exact, axOrigin: .zero), .none)
    }

    func testFrameToolResolvesARealDragToTheAXRect() {
        // Non-zero origin included deliberately: with `axOrigin == .zero` (the
        // primary display at the global origin) a missing transform is invisible.
        XCTAssertEqual(
            SelectionGesture.resolve(
                tool: .frame,
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 180, y: 160),
                axOrigin: CGPoint(x: 1512, y: 30)
            ),
            .frame(CGRect(x: 1612, y: 130, width: 80, height: 60))
        )
    }

    func testFrameToolNormalizesABackwardsDrag() {
        // Users drag up-left as readily as down-right; a negative-extent rect would
        // hit the session's degenerate guard and resolve to nothing.
        XCTAssertEqual(
            SelectionGesture.resolve(
                tool: .frame,
                from: CGPoint(x: 180, y: 160),
                to: CGPoint(x: 100, y: 100),
                axOrigin: .zero
            ),
            .frame(CGRect(x: 100, y: 100, width: 80, height: 60))
        )
    }

    // MARK: - Travel threshold

    func testZeroTravelIsNotFarEnough() {
        XCTAssertFalse(SelectionGesture.travelledFarEnough(from: start, to: start))
        XCTAssertEqual(
            SelectionGesture.localRect(from: start, to: start),
            CGRect(x: 100, y: 100, width: 0, height: 0)
        )
    }

    func testTravelJustBelowThresholdIsNotFarEnough() {
        let below = CGPoint(x: start.x + SelectionGesture.minimumTravel - 0.5, y: start.y)
        XCTAssertFalse(SelectionGesture.travelledFarEnough(from: start, to: below))
    }

    func testTravelExactlyAtThresholdIsNotFarEnough() {
        let exact = CGPoint(x: start.x + SelectionGesture.minimumTravel, y: start.y)
        XCTAssertFalse(SelectionGesture.travelledFarEnough(from: start, to: exact))
    }

    func testTravelJustAboveThresholdIsFarEnough() {
        let above = CGPoint(x: start.x + SelectionGesture.minimumTravel + 0.5, y: start.y)
        XCTAssertTrue(SelectionGesture.travelledFarEnough(from: start, to: above))
    }

    func testDiagonalTravelIsMeasuredAsHypotenuseNotPerAxis() {
        // Each axis alone is under the threshold; together they are over it. A
        // per-axis test would call this deliberate diagonal drag too short.
        let leg = SelectionGesture.minimumTravel * 0.8 // hypotenuse = 1.131 * threshold
        let diagonal = CGPoint(x: start.x + leg, y: start.y + leg)
        XCTAssertLessThan(leg, SelectionGesture.minimumTravel)
        XCTAssertTrue(SelectionGesture.travelledFarEnough(from: start, to: diagonal))

        // And the converse: a diagonal whose hypotenuse is under the threshold is
        // still a wobble even though it moved on both axes.
        let short = SelectionGesture.minimumTravel * 0.5 // hypotenuse = 0.707 * threshold
        XCTAssertFalse(
            SelectionGesture.travelledFarEnough(from: start, to: CGPoint(x: start.x + short, y: start.y + short))
        )
    }

    func testThresholdIsLargerOnTouchThanCursor() {
        // A finger rolls several points on a deliberate tap, so a mouse-tuned
        // threshold on iOS would turn ordinary frame-mode taps into tiny accidental
        // frames.
        #if os(iOS)
        XCTAssertEqual(SelectionGesture.minimumTravel, 10)
        #else
        XCTAssertEqual(SelectionGesture.minimumTravel, 6)
        #endif
    }

    // MARK: - Geometry

    func testAllFourDragDirectionsNormalizeToTheSameRect() {
        // Users drag up-left as readily as down-right. Without normalization the
        // three "backwards" directions arrive with negative extents, which the
        // session's degenerate guard treats as a non-drag — the marquee would work
        // in exactly one direction.
        let expected = CGRect(x: 100, y: 100, width: 80, height: 60)
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 180, y: 160)
        XCTAssertEqual(SelectionGesture.localRect(from: a, to: b), expected)                              // down-right
        XCTAssertEqual(SelectionGesture.localRect(from: b, to: a), expected)                              // up-left
        XCTAssertEqual(SelectionGesture.localRect(from: CGPoint(x: 180, y: 100), to: CGPoint(x: 100, y: 160)), expected) // down-left
        XCTAssertEqual(SelectionGesture.localRect(from: CGPoint(x: 100, y: 160), to: CGPoint(x: 180, y: 100)), expected) // up-right
    }

    func testAXRectIsWindowLocalRectAtOriginOnPrimaryDisplay() {
        // `axOrigin == .zero` on the primary display at the global origin, so the
        // AX rect and the drawn band coincide there — which is why an origin bug
        // hides until someone uses a second display.
        XCTAssertEqual(
            SelectionGesture.axRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 160), axOrigin: .zero),
            CGRect(x: 100, y: 100, width: 80, height: 60)
        )
    }

    func testAXRectAppliesANonZeroOriginExactly() {
        // Secondary-display case: gesture coordinates are window-local, the AX
        // queries are in screen space, so the origin is ADDED (the mirror of the
        // highlight's subtraction).
        XCTAssertEqual(
            SelectionGesture.axRect(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 180, y: 160),
                axOrigin: CGPoint(x: 1512, y: 30)
            ),
            CGRect(x: 1612, y: 130, width: 80, height: 60)
        )
    }

    func testAXRectNormalizesBeforeShiftingSoABackwardsDragIsStillOnScreen() {
        // A up-left drag shifted by the origin must land at the frame's top-left,
        // not at the press point with negative extents (which would resolve to
        // nothing at all).
        XCTAssertEqual(
            SelectionGesture.axRect(
                from: CGPoint(x: 180, y: 160),
                to: CGPoint(x: 100, y: 100),
                axOrigin: CGPoint(x: 1512, y: 30)
            ),
            CGRect(x: 1612, y: 130, width: 80, height: 60)
        )
    }

    // MARK: - Clicking an existing pin (VRT-u209)

    /// The pin of a note captured at window-local (100, 100) — the same point these
    /// tests press from, so a press at `start` is a press dead on the pin.
    private func pinnedNote(id: String = "n1", at origin: CGPoint = CGPoint(x: 100, y: 100)) -> AnnotationNote {
        AnnotationNote(
            id: id,
            selector: "#SaveButton",
            elementPath: "AXWindow > AXButton",
            comment: "c",
            timestamp: "t",
            anchorRect: CGRect(origin: origin, size: CGSize(width: 40, height: 20))
        )
    }

    /// THE ASK: a comment can be re-opened by clicking its number. In point mode the
    /// pin's own `Button` already answered this; the rule has to agree with it, or
    /// the two routes would resolve the same press differently.
    func testAClickOnAPinEditsThatNoteInPointMode() {
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .point, from: start, to: start, axOrigin: .zero, pins: [pinnedNote()]),
            .editNote("n1")
        )
    }

    /// THE DEFECT THIS CLOSES. In frame mode the pin view is hit-test-inert, so the
    /// press arrives at the catcher and nothing downstream knew what it had landed
    /// on: measured as `editingNoteID=nil` by the probe's phase 11c, reported as "I
    /// hover the numbers and nothing happens". A note written with the frame tool
    /// could be read and never edited.
    func testAClickOnAPinEditsThatNoteInFrameModeToo() {
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .frame, from: start, to: start, axOrigin: .zero, pins: [pinnedNote()]),
            .editNote("n1"),
            "a click on a pin means the same thing in both tools — the tool governs what a press binds to, not whether an existing note can be re-opened"
        )
    }

    /// THE `VRT-dp47` REGRESSION GUARD, and the reason the rule gates on TRAVEL
    /// rather than on the tool. Every capture plants a pin exactly where the user is
    /// most likely to draw the next frame — on the thing they just annotated — so if
    /// a press starting on a pin were an edit unconditionally, frame mode would lose
    /// its main gesture precisely where it is most used.
    func testADragThatStartsOnAPinStillDrawsItsFrame() {
        let farEnough = CGPoint(x: start.x + 200, y: start.y + 150)
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .frame, from: start, to: farEnough, axOrigin: .zero, pins: [pinnedNote()]),
            .frame(CGRect(x: 100, y: 100, width: 200, height: 150))
        )
    }

    /// The point-mode mirror: point mode calls ANY travel a sloppy click, so a press
    /// that drifted off a pin is not an edit either — it binds to where the user
    /// aimed, exactly as it did before pins were clickable.
    func testADragInPointModeFromAPinIsAStillASelectionNotAnEdit() {
        let farEnough = CGPoint(x: start.x + 200, y: start.y + 150)
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .point, from: start, to: farEnough, axOrigin: .zero, pins: [pinnedNote()]),
            .point(CGPoint(x: 100, y: 100))
        )
    }

    /// A click that missed every pin routes exactly as it always has — the empty-set
    /// default and a populated-but-missed set must agree, or notes on screen would
    /// quietly change what a click on the app means.
    func testAClickAwayFromEveryPinRoutesAsBefore() {
        let elsewhere = CGPoint(x: 600, y: 600)
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .point, from: elsewhere, to: elsewhere, axOrigin: .zero, pins: [pinnedNote()]),
            .point(elsewhere)
        )
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .frame, from: elsewhere, to: elsewhere, axOrigin: .zero, pins: [pinnedNote()]),
            .none,
            "frame mode's too-short press still does nothing — a pin miss must not become a selection"
        )
    }

    /// COORDINATES, as an assertion. The pin test consumes the WINDOW-LOCAL press
    /// point, while the selection payloads are shifted into AX screen space by
    /// `axOrigin`. Shifting the pin test too would look symmetrical and test every
    /// pin against a point off by the window's screen origin — invisible on the
    /// primary display at the global origin, wrong on every other one.
    func testThePinTestUsesWindowLocalCoordinatesNotAXScreenSpace() {
        let axOrigin = CGPoint(x: 1512, y: 30)
        XCTAssertEqual(
            SelectionGesture.resolve(tool: .frame, from: start, to: start, axOrigin: axOrigin, pins: [pinnedNote()]),
            .editNote("n1"),
            "the pin is stored window-local, so a secondary display must not move its hit target"
        )
        // ...and the note whose pin sits where the AX-SHIFTED point would land is NOT
        // the one that opens.
        XCTAssertEqual(
            SelectionGesture.resolve(
                tool: .frame, from: start, to: start, axOrigin: axOrigin,
                pins: [pinnedNote(id: "shifted", at: CGPoint(x: 1612, y: 130)), pinnedNote()]
            ),
            .editNote("n1")
        )
    }
}
