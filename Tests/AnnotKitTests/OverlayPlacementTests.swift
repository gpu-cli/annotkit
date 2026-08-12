#if os(macOS)
import CoreGraphics
import SwiftUI
import XCTest
@testable import AnnotKit

/// Where the overlay panels are placed when the host window does not fit on the display.
///
/// The reported bug: "on scrollable screens, the menu in the bottom right disappears."
/// A tall/scrollable host is a window taller than the display, AppKit constrains a
/// window's TOP under the menu bar but never lifts its bottom, and BOTH overlay modes
/// anchor the toolbar to the host's BOTTOM edge — so the pill was drawn under the Dock
/// or off the display entirely. These are the placement rules that fix it, tested as
/// pure geometry so they hold on display arrangements no test machine has.
///
/// Everything here is asserted about the PILL rather than about the panel carrying it.
/// The panel is sized to the control now (so it stops eating clicks the host app needs
/// — see ``OverlayPlacement/toolbarFrame(hostFrame:visibleFrame:panelSize:)``), which
/// means its own edges move whenever the pill's width changes. The pill's position is
/// the invariant, and it is the only part a user can see or hit.
@MainActor
final class OverlayPlacementTests: XCTestCase {
    /// A 1512x982 display with a 33pt menu bar and a 61pt Dock — the shape of a real
    /// laptop screen, so "visible" and "screen" are never accidentally interchangeable.
    private let visible = CGRect(x: 0, y: 61, width: 1512, height: 888)

    /// A representative measured panel: an annotate-width pill plus the chrome margin
    /// the view pads it by. The placement rule only ever sees a size, so pinning one
    /// here keeps these tests about placement rather than about SwiftUI's layout.
    private let panelSize = CGSize(width: 227, height: 80)
    /// The idle panel: the same pill row collapsed to a single pencil.
    private let idlePanelSize = CGSize(width: 72, height: 80)

    private func annotating(_ host: CGRect, _ visible: CGRect?) -> CGRect {
        OverlayPlacement.catcherFrame(hostFrame: host, visibleFrame: visible)
    }

    private func toolbar(_ host: CGRect, _ visible: CGRect?, size: CGSize? = nil) -> CGRect {
        OverlayPlacement.toolbarFrame(hostFrame: host, visibleFrame: visible, panelSize: size ?? panelSize)
    }

    /// Where the PILL lands inside a toolbar panel: the panel minus the chrome margin
    /// the shadow and count badge draw into.
    private func pill(in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + PillStyle.panelChrome.leading,
               y: panel.minY + PillStyle.panelChrome.bottom,
               width: panel.width - PillStyle.panelChrome.leading - PillStyle.panelChrome.trailing,
               height: panel.height - PillStyle.panelChrome.top - PillStyle.panelChrome.bottom)
    }

    // MARK: - The unchanged case

    /// A host that fits on the display must be placed EXACTLY as before the clamp, or
    /// the fix has moved the overlay for every user who never had the bug.
    func testHostInsideTheVisibleAreaIsPlacedExactlyAsBefore() {
        let host = CGRect(x: 200, y: 200, width: 800, height: 600)
        XCTAssertEqual(annotating(host, visible), host)
        let corner = pill(in: toolbar(host, visible))
        XCTAssertEqual(corner.maxX, host.maxX - PillStyle.cornerInset)
        XCTAssertEqual(corner.minY, host.minY + PillStyle.cornerInset)
    }

    /// The property the whole re-sizing rests on: the panel changing width must not
    /// move the control. Idle is one pencil and annotate is a six-control row, so this
    /// happens every time the menu opens or closes.
    func testThePillLandsInTheSamePlaceWhateverSizeThePanelIs() {
        let host = CGRect(x: 200, y: 200, width: 800, height: 600)
        let wide = pill(in: toolbar(host, visible, size: panelSize))
        let narrow = pill(in: toolbar(host, visible, size: idlePanelSize))
        XCTAssertEqual(wide.maxX, narrow.maxX, "the pill's trailing edge is the anchor")
        XCTAssertEqual(wide.minY, narrow.minY, "and so is its bottom")
        XCTAssertLessThan(toolbar(host, visible, size: idlePanelSize).width,
                          toolbar(host, visible, size: panelSize).width,
                          "sanity: the idle panel really is narrower — the panel grows LEFTWARDS")
    }

    /// The point of sizing the panel at all: it covers the control instead of a fixed
    /// rect, because every pixel it covers is a pixel of the host app that cannot be
    /// clicked (macOS does not pass mouse events through a window's transparent parts).
    func testTheIdlePanelIsFarSmallerThanTheFixedSizeItReplaced() {
        let host = CGRect(x: 200, y: 200, width: 800, height: 600)
        let area = toolbar(host, visible, size: idlePanelSize)
        let old = OverlayPlacement.unmeasuredPanelSize
        XCTAssertLessThan(area.width * area.height, old.width * old.height / 3,
                          "an idle pill claims less than a third of the corner it used to")
    }

    // MARK: - The reported direction: the bottom hangs off

    func testBottomOverhangPullsBothModesUpToTheVisibleBottom() {
        // 300pt of the host is below the visible area — the shape a content-sized
        // window grows into when its content outgrows the display.
        let host = CGRect(x: 400, y: visible.minY - 300, width: 620, height: visible.height + 300)

        let annotate = annotating(host, visible)
        XCTAssertEqual(annotate, host.intersection(visible))
        XCTAssertEqual(annotate.minY, visible.minY, "the catcher's bottom edge — where the pill is drawn — is on screen")

        let corner = pill(in: toolbar(host, visible))
        XCTAssertEqual(corner.minY, visible.minY + PillStyle.cornerInset, "the pill is lifted onto the visible screen")
        XCTAssertEqual(corner.maxX, host.maxX - PillStyle.cornerInset,
                       "and stays anchored to the host's right edge, which is on screen")
    }

    /// The toolbar panel is anchored, never intersected: shrinking it to the visible
    /// region would clip the pill it exists to carry.
    func testToolbarPanelKeepsItsFullSizeWhenTheHostHangsOff() {
        let host = CGRect(x: 400, y: visible.minY - 300, width: 620, height: visible.height + 300)
        XCTAssertEqual(toolbar(host, visible).size, panelSize)
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
        XCTAssertEqual(pill(in: toolbar(host, visible)).maxX, visible.maxX - PillStyle.cornerInset)
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
        XCTAssertEqual(pill(in: toolbar(host, visible)).maxX, host.maxX - PillStyle.cornerInset)
        XCTAssertFalse(annotating(host, visible).isEmpty)
    }

    /// No screen to clamp against (AppKit reports none mid-teardown) is not a reason to
    /// place the panel nowhere.
    func testNoScreenFallsBackToTheHostFrame() {
        let host = CGRect(x: 100, y: -400, width: 600, height: 1400)
        XCTAssertEqual(annotating(host, nil), host)
        XCTAssertEqual(pill(in: toolbar(host, nil)).maxX, host.maxX - PillStyle.cornerInset)
    }

    /// A host with only a sliver on screen still gets a full-size toolbar panel whose
    /// PILL — the part that has to be reachable — is inside the visible region.
    func testSliverOfHostOnScreenStillYieldsAReachablePill() {
        let host = CGRect(x: 400, y: visible.minY - 1000, width: 620, height: 1040)   // 40pt visible
        let corner = toolbar(host, visible)
        XCTAssertEqual(corner.size, panelSize)
        XCTAssertTrue(visible.contains(pill(in: corner)),
                      "the pill itself is inside the visible region")
    }
}
#endif
