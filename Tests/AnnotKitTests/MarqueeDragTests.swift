import CoreGraphics
import XCTest
@testable import AnnotKit

final class MarqueeDragTests: XCTestCase {
    private let start = CGPoint(x: 100, y: 100)

    func testZeroTravelPressIsAClick() {
        // The regression this threshold exists for: `select(inAXRect:)` returns nil
        // for a zero-area rect, so a press routed into the marquee path makes
        // clicking do nothing at all in annotate mode.
        XCTAssertFalse(MarqueeDrag.isFrame(from: start, to: start))
        XCTAssertEqual(MarqueeDrag.localRect(from: start, to: start), CGRect(x: 100, y: 100, width: 0, height: 0))
    }

    func testTravelJustBelowThresholdIsAClick() {
        // A jitter-drag is NOT zero-area, so nothing downstream rejects it: it would
        // resolve to whatever container the pointer sat in and plant a note the user
        // never framed.
        let below = CGPoint(x: start.x + MarqueeDrag.minimumTravel - 0.5, y: start.y)
        XCTAssertFalse(MarqueeDrag.isFrame(from: start, to: below))
    }

    func testTravelExactlyAtThresholdIsStillAClick() {
        // The boundary belongs to the safer branch: a click misread as a frame
        // plants a wrong note, a frame misread as a click just selects the press.
        let exact = CGPoint(x: start.x + MarqueeDrag.minimumTravel, y: start.y)
        XCTAssertFalse(MarqueeDrag.isFrame(from: start, to: exact))
    }

    func testTravelJustAboveThresholdIsAFrame() {
        let above = CGPoint(x: start.x + MarqueeDrag.minimumTravel + 0.5, y: start.y)
        XCTAssertTrue(MarqueeDrag.isFrame(from: start, to: above))
    }

    func testDiagonalTravelIsMeasuredAsHypotenuseNotPerAxis() {
        // Each axis alone is under the threshold; together they are over it. A
        // per-axis test would call this deliberate diagonal drag a click.
        let leg = MarqueeDrag.minimumTravel * 0.8 // hypotenuse = 1.131 * threshold
        let diagonal = CGPoint(x: start.x + leg, y: start.y + leg)
        XCTAssertLessThan(leg, MarqueeDrag.minimumTravel)
        XCTAssertTrue(MarqueeDrag.isFrame(from: start, to: diagonal))

        // And the converse: a diagonal whose hypotenuse is under the threshold is a
        // click even though it moved on both axes.
        let short = MarqueeDrag.minimumTravel * 0.5 // hypotenuse = 0.707 * threshold
        XCTAssertFalse(MarqueeDrag.isFrame(from: start, to: CGPoint(x: start.x + short, y: start.y + short)))
    }

    func testAllFourDragDirectionsNormalizeToTheSameRect() {
        // Users drag up-left as readily as down-right. Without normalization the
        // three "backwards" directions arrive with negative extents, which the
        // session's degenerate guard treats as a non-drag — the marquee would work
        // in exactly one direction.
        let expected = CGRect(x: 100, y: 100, width: 80, height: 60)
        let a = CGPoint(x: 100, y: 100), b = CGPoint(x: 180, y: 160)
        XCTAssertEqual(MarqueeDrag.localRect(from: a, to: b), expected)                              // down-right
        XCTAssertEqual(MarqueeDrag.localRect(from: b, to: a), expected)                              // up-left
        XCTAssertEqual(MarqueeDrag.localRect(from: CGPoint(x: 180, y: 100), to: CGPoint(x: 100, y: 160)), expected) // down-left
        XCTAssertEqual(MarqueeDrag.localRect(from: CGPoint(x: 100, y: 160), to: CGPoint(x: 180, y: 100)), expected) // up-right
    }

    func testAXRectIsWindowLocalRectAtOriginOnPrimaryDisplay() {
        // `axOrigin == .zero` on the primary display at the global origin, so the
        // AX rect and the drawn band coincide there — which is why an origin bug
        // hides until someone uses a second display.
        XCTAssertEqual(
            MarqueeDrag.axRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 160), axOrigin: .zero),
            CGRect(x: 100, y: 100, width: 80, height: 60)
        )
    }

    func testAXRectAppliesANonZeroOriginExactly() {
        // Secondary-display case: gesture coordinates are window-local, the AX
        // queries are in screen space, so the origin is ADDED (the mirror of the
        // highlight's subtraction).
        XCTAssertEqual(
            MarqueeDrag.axRect(
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
            MarqueeDrag.axRect(
                from: CGPoint(x: 180, y: 160),
                to: CGPoint(x: 100, y: 100),
                axOrigin: CGPoint(x: 1512, y: 30)
            ),
            CGRect(x: 1612, y: 130, width: 80, height: 60)
        )
    }

    func testThresholdIsLargerOnTouchThanCursor() {
        // A finger rolls several points on a deliberate tap, so a mouse-tuned
        // threshold on iOS turns ordinary taps into accidental marquees.
        #if os(iOS)
        XCTAssertEqual(MarqueeDrag.minimumTravel, 10)
        #else
        XCTAssertEqual(MarqueeDrag.minimumTravel, 6)
        #endif
    }
}
