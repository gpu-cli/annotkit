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
}
