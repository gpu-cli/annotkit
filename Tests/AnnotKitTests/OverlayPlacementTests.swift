#if os(macOS)
import CoreGraphics
import XCTest
@testable import AnnotKit

/// Where the overlay panel is placed when the host window does not fit on the display.
///
/// The reported bug: "on scrollable screens, the menu in the bottom right disappears."
/// A tall/scrollable host is a window taller than the display, AppKit constrains a
/// window's TOP under the menu bar but never lifts its bottom, and BOTH overlay modes
/// anchor the toolbar to the host's BOTTOM edge — so the pill was drawn under the Dock
/// or off the display entirely. These are the placement rules that fix it, tested as
/// pure geometry so they hold on display arrangements no test machine has.
@MainActor
final class OverlayPlacementTests: XCTestCase {
    /// A 1512x982 display with a 33pt menu bar and a 61pt Dock — the shape of a real
    /// laptop screen, so "visible" and "screen" are never accidentally interchangeable.
    private let visible = CGRect(x: 0, y: 61, width: 1512, height: 888)

    private func annotating(_ host: CGRect, _ visible: CGRect?) -> CGRect {
        OverlayPlacement.panelFrame(for: .annotating, hostFrame: host, visibleFrame: visible)
    }

    private func idle(_ host: CGRect, _ visible: CGRect?) -> CGRect {
        OverlayPlacement.panelFrame(for: .idle, hostFrame: host, visibleFrame: visible)
    }

    // MARK: - The unchanged case

    /// A host that fits on the display must be placed EXACTLY as before the clamp, or
    /// the fix has moved the overlay for every user who never had the bug.
    func testHostInsideTheVisibleAreaIsPlacedExactlyAsBefore() {
        let host = CGRect(x: 200, y: 200, width: 800, height: 600)
        XCTAssertEqual(annotating(host, visible), host)
        XCTAssertEqual(idle(host, visible), CGRect(x: host.maxX - 240, y: host.minY, width: 240, height: 104))
    }

    // MARK: - The reported direction: the bottom hangs off

    func testBottomOverhangPullsBothModesUpToTheVisibleBottom() {
        // 300pt of the host is below the visible area — the shape a content-sized
        // window grows into when its content outgrows the display.
        let host = CGRect(x: 400, y: visible.minY - 300, width: 620, height: visible.height + 300)

        let annotate = annotating(host, visible)
        XCTAssertEqual(annotate, host.intersection(visible))
        XCTAssertEqual(annotate.minY, visible.minY, "the catcher's bottom edge — where the pill is drawn — is on screen")

        let corner = idle(host, visible)
        XCTAssertEqual(corner.minY, visible.minY)
        XCTAssertEqual(corner.maxX, host.maxX, "the pill stays anchored to the host's right edge, which is on screen")
    }

    /// The idle panel is anchored, never intersected: shrinking it to the visible region
    /// would clip the pill it exists to carry.
    func testIdlePanelKeepsItsFullSizeWhenTheHostHangsOff() {
        let host = CGRect(x: 400, y: visible.minY - 300, width: 620, height: visible.height + 300)
        XCTAssertEqual(idle(host, visible).size, OverlayPlacement.idleSize)
    }

    /// The coordinate half of the fix, in the direction that is easy to get right by
    /// accident: clipping only the BOTTOM leaves the AX origin (which hangs off the
    /// frame's TOP edge) untouched, and only shrinks the surface — which is itself
    /// correct, because the composer should clamp its cards to the VISIBLE region.
    func testBottomClampLeavesTheAXOriginAloneAndOnlyShrinksTheSurface() {
        let host = CGRect(x: 400, y: visible.minY - 300, width: 620, height: visible.height + 300)
        let panel = annotating(host, visible)
        let primaryHeight: CGFloat = 982
        XCTAssertEqual(
            ScreenSpace.windowAXOrigin(cocoaFrame: panel, primaryHeight: primaryHeight),
            ScreenSpace.windowAXOrigin(cocoaFrame: host, primaryHeight: primaryHeight)
        )
        XCTAssertEqual(panel.height, host.height - 300)
    }

    // MARK: - The other direction: the top is tucked under the menu bar

    /// The case a naive fix breaks silently. Clipping the TOP moves the AX origin, so an
    /// origin still derived from the host offsets every click, highlight and card by
    /// exactly the clipped amount — a fix that makes the pill reachable while shifting
    /// the whole hit-test is worse than the bug it replaces.
    func testTopClampMovesTheAXOriginByExactlyTheClippedAmount() {
        let host = CGRect(x: 400, y: 300, width: 620, height: visible.maxY - 300 + 200)
        let panel = annotating(host, visible)
        XCTAssertEqual(panel.maxY, visible.maxY)

        let primaryHeight: CGFloat = 982
        let panelOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: panel, primaryHeight: primaryHeight)
        let hostOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: host, primaryHeight: primaryHeight)
        XCTAssertEqual(panelOrigin.y - hostOrigin.y, 200, "the origin moves down by the clipped 200pt")
        XCTAssertNotEqual(panelOrigin, hostOrigin, "sanity: the two candidate origins really do differ here")
    }

    // MARK: - Horizontal overhang

    func testRightOverhangPullsTheIdlePillInsideTheDisplay() {
        let host = CGRect(x: 1200, y: 300, width: 800, height: 400)   // 488pt off the right edge
        XCTAssertEqual(idle(host, visible).maxX, visible.maxX)
        XCTAssertEqual(annotating(host, visible).maxX, visible.maxX)
    }

    // MARK: - Degenerate hosts

    /// A host entirely off-display (another Space, a window parked off-screen) keeps its
    /// UNCLAMPED placement. Collapsing the panel to the empty intersection would leave a
    /// zero-sized overlay that has to be rebuilt; an off-screen one just reappears with
    /// its window.
    func testHostEntirelyOffDisplayKeepsTheUnclampedPlacement() {
        let host = CGRect(x: -12000, y: -12000, width: 600, height: 400)
        XCTAssertEqual(annotating(host, visible), host)
        XCTAssertEqual(idle(host, visible), CGRect(x: host.maxX - 240, y: host.minY, width: 240, height: 104))
        XCTAssertFalse(annotating(host, visible).isEmpty)
    }

    /// No screen to clamp against (AppKit reports none mid-teardown) is not a reason to
    /// place the panel nowhere.
    func testNoScreenFallsBackToTheHostFrame() {
        let host = CGRect(x: 100, y: -400, width: 600, height: 1400)
        XCTAssertEqual(annotating(host, nil), host)
        XCTAssertEqual(idle(host, nil), CGRect(x: host.maxX - 240, y: host.minY, width: 240, height: 104))
    }

    /// A host with only a sliver on screen still gets a full-size idle panel whose
    /// BOTTOM edge — the edge the pill is drawn against — is inside the visible region.
    func testSliverOfHostOnScreenStillYieldsAReachablePill() {
        let host = CGRect(x: 400, y: visible.minY - 1000, width: 620, height: 1040)   // 40pt visible
        let corner = idle(host, visible)
        XCTAssertEqual(corner.size, OverlayPlacement.idleSize)
        XCTAssertEqual(corner.minY, visible.minY)
        XCTAssertTrue(visible.contains(CGRect(x: corner.maxX - 200, y: corner.minY + 20, width: 180, height: 44)),
                      "the pill itself (bottom-right, 20pt inset) is inside the visible region")
    }
}
#endif
