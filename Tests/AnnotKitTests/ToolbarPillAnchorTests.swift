#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AnnotKit

/// "Closing the menu shortens it to the left, then it jumps to the right."
///
/// The toolbar panel does not change size in step with the pill it carries. It
/// GROWS the instant the mode flips and SHRINKS a third of a second later, once the
/// pill's 0.15s width animation has settled (``OverlayController``'s asymmetry: a
/// panel that shrinks early clips the control mid-animation). So on every open and
/// close there is a window in which the panel is wider than its content — and
/// ``OverlayPlacement/toolbarFrame(hostFrame:visibleFrame:panelSize:)`` places the
/// panel by computing backwards from the pill's corner, which is only where the
/// pill actually IS if the content is pinned to that corner.
///
/// It was not: a `fixedSize` root in an oversized `NSHostingView` is CENTERED.
/// Measured before the fix, idle content (72pt) in the still-open panel (258pt):
/// the pill sat 93pt from each edge instead of 14pt from the trailing one — so it
/// collapsed toward the middle as it narrowed, then snapped 79pt right when the
/// panel finally shrank under it.
///
/// These tests rasterise the real view and look for the pill's opaque body, because
/// the bug is entirely about where the control is DRAWN — every value the placement
/// math produced was already correct. That is also why
/// `PanelFrameEnforcementTests.testTheToolbarDoesNotMoveWhenTheMenuOpensOrCloses`
/// passed throughout: it derives the pill's corner FROM the panel frame, which is
/// the very assumption that only held once the panel had settled.
@MainActor
final class ToolbarPillAnchorTests: XCTestCase {
    /// The panel size the controller holds during a close: measured for ANNOTATE
    /// mode, while the pill has already animated back down to the lone pencil.
    private let oversized = CGSize(width: 258, height: 104)

    private func makeSession() -> AnnotationSession {
        AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
    }

    /// The mid-close state: idle content, panel still at its annotate-mode width.
    func testThePillKeepsItsCornerWhileThePanelIsWiderThanTheContent() throws {
        let pill = try drawnPillFrame(panelSize: oversized, session: makeSession())
        XCTAssertEqual(oversized.width - pill.maxX, PillStyle.panelChrome.trailing, accuracy: 1,
                       "the pill's trailing edge must stay one chrome margin from the panel's, "
                       + "or the panel's late shrink drags the control sideways")
        XCTAssertEqual(pill.minY, PillStyle.panelChrome.bottom, accuracy: 1,
                       "same for the bottom edge — the seed panel is taller than the pill too")
    }

    /// The settled state, and the one the placement math is written against. The
    /// two must agree pixel for pixel: that they did NOT is the jump.
    func testTheSettledPanelDrawsThePillInTheSamePlaceAsTheOversizedOne() throws {
        let session = makeSession()
        let snugSize = measuredSize(session: session)
        let snug = try drawnPillFrame(panelSize: snugSize, session: session)
        let wide = try drawnPillFrame(panelSize: oversized, session: session)

        XCTAssertEqual(snugSize.width - snug.maxX, oversized.width - wide.maxX, accuracy: 1)
        XCTAssertEqual(snug.minY, wide.minY, accuracy: 1)
        XCTAssertEqual(snug.size.width, wide.size.width, accuracy: 1)
    }

    /// The corner pin is a `maxWidth`/`maxHeight` frame, and the SAME view is what
    /// ``OverlayController/measuredToolbarSize()`` sizes the panel from. A flexible
    /// frame that reported its max instead of its content's ideal would inflate the
    /// panel to fill the screen — every pixel of which is a pixel of the host app
    /// that can no longer be clicked.
    func testPinningTheCornerDoesNotInflateTheMeasuredSize() {
        let size = measuredSize(session: makeSession())
        XCTAssertLessThan(size.width, 200, "idle is one 44pt pill plus 14pt of chrome a side")
        XCTAssertLessThan(size.height, 120)
        XCTAssertGreaterThan(size.width, 40)
        XCTAssertGreaterThan(size.height, 40)
    }

    // MARK: - Rasterising

    private func toolbarView(session: AnnotationSession) -> ToolbarOverlayView {
        ToolbarOverlayView(session: session, onToggle: {}, onCopy: {}, onExport: {})
    }

    /// What the controller sizes the panel from: a fresh, uninstalled hosting view's
    /// `fittingSize`, with the default sizing options that make it report one.
    private func measuredSize(session: AnnotationSession) -> CGSize {
        NSHostingView(rootView: toolbarView(session: session)).fittingSize
    }

    /// The pill's drawn bounds inside a panel of `panelSize`, in AppKit's y-UP
    /// panel-local coordinates.
    ///
    /// Found by alpha, not by colour: the pill's capsule is opaque, and the only
    /// other thing the view draws is its shadow — black at 0.4, radius 12 — so a
    /// high alpha threshold picks out the body and ignores the halo around it.
    private func drawnPillFrame(panelSize: CGSize, session: AnnotationSession) throws -> CGRect {
        let view = NSHostingView(rootView: toolbarView(session: session))
        // Match the panel's own hosting view: the controller owns the frame, so the
        // view must NOT resize itself to its content — being stretched past its
        // content is the whole state under test.
        view.sizingOptions = []
        view.frame = CGRect(origin: .zero, size: panelSize)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                "no bitmap backing for the hosting view")
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / panelSize.width
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try XCTSkipIf(minX == Int.max, "the offscreen rasterisation drew nothing on this machine")

        // The bitmap is y-DOWN; the panel geometry this is compared against is y-UP.
        let top = CGFloat(minY) / scale
        let bottom = CGFloat(maxY + 1) / scale
        return CGRect(x: CGFloat(minX) / scale,
                      y: panelSize.height - bottom,
                      width: CGFloat(maxX + 1 - minX) / scale,
                      height: bottom - top)
    }
}
#endif
