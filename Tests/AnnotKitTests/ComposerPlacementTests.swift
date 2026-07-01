import CoreGraphics
import XCTest
@testable import AnnotKit

final class ComposerPlacementTests: XCTestCase {
    private let surface = CGSize(width: 1512, height: 982)
    private let size = CGSize(width: 284, height: 172)

    func testPlacesBelowElementOnPrimaryDisplay() {
        // The everyday case: room below, so the card sits just under the element
        // and the caret points up, aligned with the element's center.
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 100, y: 100, width: 120, height: 40),
            axOrigin: .zero,
            surfaceSize: surface,
            composerSize: size
        )
        XCTAssertEqual(placement.origin, CGPoint(x: 100, y: 148)) // 100 + 40 + 8
        XCTAssertTrue(placement.caretPointsUp)
        // elementCenter 160 - cardCenter (100 + 142) = -82, within the ±124 clamp.
        XCTAssertEqual(placement.caretDX, -82, accuracy: 0.001)
    }

    func testFlipsAboveWhenItWouldSpillOffTheBottom() {
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 100, y: 900, width: 120, height: 40),
            axOrigin: .zero,
            surfaceSize: surface,
            composerSize: size
        )
        // 900 + 40 + 8 + 172 > 982 - 8, so flip: 900 - 172 - 8 = 720.
        XCTAssertEqual(placement.origin.y, 720, accuracy: 0.001)
        XCTAssertFalse(placement.caretPointsUp)
    }

    func testWindowSelectionStaysFullyOnScreen() {
        // The diagnosis's regression: selecting the whole window put the composer
        // at AX (640, 790), spilling off an 982-tall screen. It must now clamp
        // fully on-screen (flip above, top clamped to the gap).
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            axOrigin: .zero,
            surfaceSize: surface,
            composerSize: size
        )
        XCTAssertEqual(placement.origin, CGPoint(x: 8, y: 8))
        XCTAssertFalse(placement.caretPointsUp)
        XCTAssertLessThanOrEqual(placement.origin.y + size.height, surface.height)
    }

    func testClampsHorizontallyAtRightEdge() {
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 1450, y: 100, width: 40, height: 40),
            axOrigin: .zero,
            surfaceSize: surface,
            composerSize: size
        )
        // maxX = 1512 - 284 - 8 = 1220, so the card is pinned to the right edge.
        XCTAssertEqual(placement.origin.x, 1220, accuracy: 0.001)
        // Caret still points at the element center (1470 - 1362 = 108, within clamp).
        XCTAssertEqual(placement.caretDX, 108, accuracy: 0.001)
    }

    func testSubtractsAXOriginOnSecondaryDisplay() {
        // Element on the display to the right of the primary: the AX-screen frame
        // is offset by axOrigin, which must be subtracted back to window-local.
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 1612, y: 200, width: 120, height: 40),
            axOrigin: CGPoint(x: 1512, y: 0),
            surfaceSize: surface,
            composerSize: size
        )
        XCTAssertEqual(placement.origin, CGPoint(x: 100, y: 248)) // (1612-1512), (200+40+8)
        XCTAssertTrue(placement.caretPointsUp)
    }

    func testCaretClampsToCardWhenElementIsFarToTheSide() {
        // A tiny element pinned at the far left: the caret cannot reach the
        // element center, so it clamps to the card's inset edge.
        let placement = ComposerPlacement.resolve(
            elementFrame: CGRect(x: 0, y: 100, width: 10, height: 10),
            axOrigin: .zero,
            surfaceSize: surface,
            composerSize: size
        )
        XCTAssertEqual(placement.origin.x, 8, accuracy: 0.001)
        // Clamped to -(284/2 - 18) = -124.
        XCTAssertEqual(placement.caretDX, -124, accuracy: 0.001)
    }
}
