#if os(macOS)
import AppKit
import XCTest
@testable import AnnotKit

/// The vanishing-toolbar bug, at its root.
///
/// AppKit repositions a CHILD window to preserve its offset from the parent — and it
/// does so AFTER the `didMove` notification the controller reacts to. So the
/// visible-frame clamp was computed correctly, applied correctly, and then silently
/// dragged back a runloop turn later. On a host whose bottom hangs below the display
/// (a tall scrollable window) that puts the pill off-screen: "the menu disappears".
///
/// Measured against a live host with forensics on, before the fix:
///
///     computed=(1272, 60, 240, 104)  afterSet=(1272, 60, 240, 104)
///     next-turn panel=(1272, -200, 240, 104)  clobbered=true
///
/// The controller re-asserts the clamped frame on the next turn. These tests pin both
/// halves: that the clamp survives a parent move, and that the re-assert does not fire
/// when AppKit left the panel alone (which would mean it is fighting normal placement).
@MainActor
final class PanelFrameEnforcementTests: XCTestCase {
    /// A host whose bottom hangs below the visible frame, so placement must clamp.
    private func makeHangingHost() -> NSWindow {
        let visible = (NSScreen.screens.first?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1512, height: 900)
        let host = NSWindow(contentRect: NSRect(x: visible.minX + 100, y: visible.minY - 260,
                                                width: 600, height: 800),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.orderFront(nil)
        // AppKit constrains a TITLED window's top under the menu bar but never lifts
        // its bottom, so this really does end up hanging off the display.
        host.setFrame(NSRect(x: visible.minX + 100, y: visible.minY - 260, width: 600, height: 800),
                      display: true)
        return host
    }

    private func makeController(on host: NSWindow) -> OverlayController {
        _ = NSApplication.shared
        let controller = OverlayController(
            session: AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        )
        controller.mount(on: host)
        return controller
    }

    /// Moving the host must not drag the pill off the visible screen.
    func testTheClampSurvivesAParentMove() async {
        let host = makeHangingHost()
        defer { host.orderOut(nil) }
        let controller = makeController(on: host)
        defer { controller.unmount() }

        guard let panel = host.childWindows?.first,
              let visible = (host.screen ?? NSScreen.screens.first)?.visibleFrame else {
            return XCTFail("no panel/screen to assert against")
        }
        XCTAssertGreaterThanOrEqual(panel.frame.minY, visible.minY - 0.5,
                                    "precondition: the clamp put the panel inside the visible frame")

        // Reproduce the OBSERVED ORDERING, which is the whole bug: the controller
        // handles `didMove` and applies the clamped frame, and only THEN does AppKit
        // drag the child to follow its parent. Posting the notification and moving the
        // panel afterwards is exactly that sequence — and it is why a test that merely
        // moves the host proves nothing: there, the controller's own `setFrame` is the
        // last writer and the assertion passes with or without the fix (verified by
        // deleting the re-assert and watching it still pass).
        host.setFrameOrigin(NSPoint(x: host.frame.minX, y: host.frame.minY - 120))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: host)
        let clobbered = NSRect(x: panel.frame.minX, y: visible.minY - 200,
                               width: panel.frame.width, height: panel.frame.height)
        panel.setFrame(clobbered, display: false) // AppKit's parent-follow, after the fact
        XCTAssertLessThan(panel.frame.minY, visible.minY, "precondition: the panel really is off-screen now")

        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertGreaterThanOrEqual(panel.frame.minY, visible.minY - 0.5,
                                    "AppKit dragged the panel below the visible frame and it was not put back — the pill is off-screen")
    }

    /// The pill must not move when the menu opens or closes.
    ///
    /// It lives in its own permanently mounted panel precisely so that opening the
    /// menu — which creates a second, host-sized catcher panel — cannot shift it. The
    /// old design drew the pill inside that resizing panel, so every open/close moved
    /// the thing the user is aiming at.
    func testTheToolbarDoesNotMoveWhenTheMenuOpensOrCloses() {
        let visible = (NSScreen.screens.first?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1512, height: 900)
        let host = NSWindow(contentRect: NSRect(x: visible.minX + 120, y: visible.minY + 120,
                                                width: 700, height: 500),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let controller = makeController(on: host)
        defer { controller.unmount() }

        guard let toolbar = host.childWindows?.first else { return XCTFail("no toolbar panel") }
        let closed = toolbar.frame
        XCTAssertEqual(host.childWindows?.count, 1, "closed: only the toolbar is mounted")

        controller.start()
        XCTAssertEqual(toolbar.frame, closed, "the pill moved when the menu opened")
        XCTAssertEqual(host.childWindows?.count, 2, "open: the catcher joins the toolbar")
        // The toolbar must be ABOVE the catcher, or the full-frame catcher eats the
        // click that closes the menu.
        XCTAssertEqual(host.childWindows?.last, toolbar, "the toolbar must stay on top of the catcher")

        controller.stop()
        XCTAssertEqual(toolbar.frame, closed, "the pill moved when the menu closed")
        XCTAssertEqual(host.childWindows?.count, 1, "closed again: the catcher is gone")
    }

    /// The re-assert must be a no-op when nothing fought us: a controller that
    /// re-set the frame unconditionally would post a move notification for every
    /// move it handled, and chase its own tail.
    func testTheReAssertDoesNotFireWhenAppKitLeavesThePanelAlone() async {
        let visible = (NSScreen.screens.first?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1512, height: 900)
        // A host comfortably INSIDE the visible frame: placement and AppKit agree, so
        // there is nothing to correct.
        let host = NSWindow(contentRect: NSRect(x: visible.minX + 120, y: visible.minY + 120,
                                                width: 500, height: 400),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let controller = makeController(on: host)
        defer { controller.unmount() }

        guard let panel = host.childWindows?.first else { return XCTFail("no panel") }
        let settled = panel.frame
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: host)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(panel.frame, settled, "the panel moved when nothing asked it to")
    }
}
#endif
