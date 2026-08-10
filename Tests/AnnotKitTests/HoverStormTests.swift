#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit

/// The vanishing-pill regression, reported as: "the menu disappears when I hover over
/// it and then off it, on scrollable screens."
///
/// Two multipliers, both fixed, both pinned here:
///
/// 1. `AXIntrospection.appElement()` WROTE `AXEnhancedUserInterface` on every call,
///    and the catcher calls it from the hover hit-test at up to 60Hz. That attribute
///    announces an assistive client; AppKit answers by re-evaluating and relaying out
///    its windows, so a moving pointer drove a resize storm in the host.
/// 2. Every resulting resize pushed a FRESH SwiftUI root view, tearing the pill down
///    and rebuilding it mid-hover.
///
/// The reported trigger is what identified it: hovering ONTO the pill stops the
/// writes — the pill consumes hover, so the catcher sees `.ended` and queries nothing
/// — and moving OFF restarts them. Scrollable screens showed it first because a large
/// scroll view is a large AX tree, so materializing it costs a real layout pass.
@MainActor
final class HoverStormTests: XCTestCase {
    /// A hover storm must write the AX attribute ZERO extra times.
    ///
    /// `snapshot()` goes through the same `appElement()` every hover hit-test uses, so
    /// this exercises the real path without needing a live window. The first call in
    /// the process may legitimately write once; what must never happen again is a
    /// second write, let alone one per query.
    func testHoverStormDoesNotRewriteTheEnhancedUIAttribute() {
        _ = NSApplication.shared
        // Prime the cache so this test is independent of whichever test ran first.
        _ = AXIntrospection.snapshot()
        let writesAfterPriming = AXIntrospection.enhancedUserInterfaceWrites
        XCTAssertLessThanOrEqual(writesAfterPriming, 1, "the attribute is set once per process, not per query")

        // ~3 seconds of real 60Hz hovering.
        for _ in 0 ..< 200 { _ = AXIntrospection.snapshot() }

        XCTAssertEqual(AXIntrospection.enhancedUserInterfaceWrites, writesAfterPriming,
                       "200 queries wrote AXEnhancedUserInterface again — this is the resize storm that ate the pill")
    }

    /// Redundant geometry notifications must not rebuild the overlay's SwiftUI root.
    ///
    /// A relayout storm arrives as a burst of `didResize`/`didMove`. None of them
    /// change the panel's geometry, so none may tear down and rebuild the pill — that
    /// rebuild is what the user SEES as the toolbar vanishing.
    func testRedundantGeometryNotificationsDoNotRebuildTheOverlay() {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }

        let controller = OverlayController(
            session: AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        )
        controller.mount(on: host)
        defer { controller.unmount() }

        let pushesBefore = controller.rootViewPushes
        let frameBefore = host.childWindows?.first?.frame

        for _ in 0 ..< 50 {
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: host)
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: host)
        }

        XCTAssertEqual(controller.rootViewPushes, pushesBefore,
                       "100 redundant notifications rebuilt the pill — mid-hover that reads as it vanishing")
        XCTAssertEqual(host.childWindows?.first?.frame, frameBefore, "and the panel must not have moved")
    }

    /// The guard must skip REDUNDANT syncs, not all of them.
    ///
    /// An idempotence check that silently stopped syncing would be a far worse bug
    /// than the flicker it fixes: the panel would drift away from a host that really
    /// did move.
    func testARealResizeStillRebuildsTheOverlay() {
        _ = NSApplication.shared
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }

        let controller = OverlayController(
            session: AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        )
        controller.mount(on: host)
        defer { controller.unmount() }

        let pushesBefore = controller.rootViewPushes
        // MOVE the host rather than growing it. In idle mode the panel is a fixed-size
        // corner pinned to the host's BOTTOM edge, so growing the window upward leaves
        // the panel exactly where it was — the guard correctly skips that, and a test
        // built on it would be asserting the guard is broken.
        host.setFrameOrigin(NSPoint(x: host.frame.minX + 140, y: host.frame.minY + 90))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: host)

        XCTAssertGreaterThan(controller.rootViewPushes, pushesBefore,
                             "a real resize must still push a new root view, or the overlay stops tracking its host")
    }
}
#endif
