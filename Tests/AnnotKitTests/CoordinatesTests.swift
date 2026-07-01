import CoreGraphics
import XCTest
@testable import AnnotKit

final class CoordinatesTests: XCTestCase {
    func testFlipPointIsItsOwnInverse() {
        let h: CGFloat = 1080
        let p = CGPoint(x: 120, y: 300)
        let flipped = ScreenSpace.flipPoint(p, primaryHeight: h)
        XCTAssertEqual(flipped, CGPoint(x: 120, y: 780))
        XCTAssertEqual(ScreenSpace.flipPoint(flipped, primaryHeight: h), p)
    }

    func testAXRectToCocoaRect() {
        let h: CGFloat = 1000
        let ax = CGRect(x: 10, y: 20, width: 30, height: 40)
        let cocoa = ScreenSpace.cocoaRect(fromAXTopLeft: ax, primaryHeight: h)
        // y = 1000 - 20 - 40 = 940; x/size unchanged.
        XCTAssertEqual(cocoa, CGRect(x: 10, y: 940, width: 30, height: 40))
    }

    func testRectConversionRoundTrips() {
        let h: CGFloat = 1440
        let ax = CGRect(x: 5, y: 55, width: 200, height: 120)
        let cocoa = ScreenSpace.cocoaRect(fromAXTopLeft: ax, primaryHeight: h)
        let back = ScreenSpace.axTopLeftRect(fromCocoa: cocoa, primaryHeight: h)
        XCTAssertEqual(back, ax)
    }

    func testWindowAXOriginPrimaryAtOriginIsZero() {
        // The currently-working case: a window filling the primary display at the
        // global origin has a zero AX offset, so the transform is a no-op there.
        let primary: CGFloat = 982
        let origin = ScreenSpace.windowAXOrigin(
            cocoaFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            primaryHeight: primary
        )
        XCTAssertEqual(origin, CGPoint(x: 0, y: 0))
    }

    func testWindowAXOriginRightDisplay() {
        // A window on the display to the right of the primary keeps y == 0 but
        // carries the horizontal offset.
        let primary: CGFloat = 982
        let origin = ScreenSpace.windowAXOrigin(
            cocoaFrame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
            primaryHeight: primary
        )
        XCTAssertEqual(origin, CGPoint(x: 1512, y: 0))
    }

    func testWindowAXOriginDisplayAbove() {
        // A window on a display stacked above the primary has a negative AX y
        // (AX grows downward from the primary's top edge).
        let primary: CGFloat = 982
        let origin = ScreenSpace.windowAXOrigin(
            cocoaFrame: CGRect(x: 0, y: 982, width: 1512, height: 900),
            primaryHeight: primary
        )
        XCTAssertEqual(origin, CGPoint(x: 0, y: -900))
    }
}
