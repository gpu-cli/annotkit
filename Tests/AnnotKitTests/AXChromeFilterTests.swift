#if os(macOS)
import ApplicationServices
import XCTest
@testable import AnnotKit

/// The hit-test's window-chrome rejection predicate (traffic lights must never
/// be annotation targets). The end-to-end path is covered by the
/// AnnotKitOverlayProbe chrome phase; this pins the predicate itself.
@MainActor
final class AXChromeFilterTests: XCTestCase {
    func testTrafficLightSubrolesAreChrome() {
        for subrole in [
            kAXCloseButtonSubrole as String,
            kAXMinimizeButtonSubrole as String,
            kAXZoomButtonSubrole as String,
            kAXFullScreenButtonSubrole as String,
        ] {
            XCTAssertTrue(AXIntrospection.isWindowChrome(subrole: subrole), "\(subrole) is window chrome")
        }
    }

    func testContentSubrolesAreNotChrome() {
        for subrole in ["", "AXStandardWindow", "AXSecureTextField", "AXToggle", "AXTabButton"] {
            XCTAssertFalse(AXIntrospection.isWindowChrome(subrole: subrole), "\(subrole) is app content")
        }
    }
}
#endif
