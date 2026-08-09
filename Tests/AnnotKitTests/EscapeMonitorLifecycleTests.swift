#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit

/// A minimal source so a controller can be built without an accessibility tree.
@MainActor
private final class NullSource: ElementSource {
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { nil }
    func selector(for element: Element) -> String { "#none" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

/// The Escape key monitor's INSTALL/REMOVE lifecycle, which is the one part of this
/// feature that can damage the host app: `NSEvent` keeps a local monitor alive until
/// it is explicitly removed, so one left behind keeps swallowing the host's own
/// Escape for the life of the process — presenting as "this app's dialogs stopped
/// closing", with nothing on screen to connect it to AnnotKit.
///
/// Read through a `Mirror` because there is no API to ask AppKit what monitors are
/// installed. That is a deliberate trade: the alternative is exposing the token just
/// so a test can see it, and this contract (nil whenever the overlay is not
/// annotating) is worth more than the coupling costs.
@MainActor
final class EscapeMonitorLifecycleTests: XCTestCase {
    private func monitorIsInstalled(_ controller: OverlayController) -> Bool {
        for child in Mirror(reflecting: controller).children where child.label == "escapeMonitor" {
            // The property is `Any?`; a nil optional still reflects as a child, so
            // unwrap through `Optional<Any>` rather than testing for its presence.
            return (child.value as? Any?) .map { $0 != nil } ?? false
        }
        XCTFail("escapeMonitor is gone — this test is asserting nothing")
        return false
    }

    private func makeController() -> OverlayController {
        // Force NSApp into existence: `start()` activates the app, and `NSApp` is an
        // implicitly-unwrapped optional that is nil until something touches it.
        _ = NSApplication.shared
        return OverlayController(
            session: AnnotationSession(source: NullSource(), sink: NotesFileSink(path: "/dev/null"))
        )
    }

    func testMonitorIsInstalledOnlyWhileAnnotating() {
        let controller = makeController()
        XCTAssertFalse(monitorIsInstalled(controller), "idle must not watch the host's keystrokes")
        controller.start()
        XCTAssertTrue(monitorIsInstalled(controller), "annotate mode needs to see Escape")
        controller.stop()
        XCTAssertFalse(monitorIsInstalled(controller), "leaving the mode must give Escape back to the host")
    }

    func testUnmountRemovesTheMonitorEvenMidAnnotate() {
        // Unmounting can happen while annotate mode is still running (a host window
        // closing), and that path never touches `stop()`.
        let controller = makeController()
        controller.start()
        XCTAssertTrue(monitorIsInstalled(controller))
        controller.unmount()
        XCTAssertFalse(monitorIsInstalled(controller), "an unmounted overlay must own no monitor")
    }

    /// Re-mounting into a session that is ALREADY annotating must re-arm Escape.
    ///
    /// `unmount()` removes the monitor, but the SESSION's mode outlives the
    /// controller's panel — so a host that unmounts and re-mounts a live overlay
    /// (window recycling, a host tearing the overlay down on hide) comes back with
    /// annotate mode on. Without re-arming, Escape is silently dead in exactly the
    /// state that has no other keyboard way out, and nothing on screen hints why.
    func testReMountingWhileStillAnnotatingReArmsTheMonitor() {
        let controller = makeController()
        controller.start()
        controller.unmount()
        XCTAssertFalse(monitorIsInstalled(controller))
        XCTAssertEqual(controller.session.mode, .annotating, "unmount does not leave the mode — that is the trap")

        controller.mount(on: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                      styleMask: [.titled], backing: .buffered, defer: true))
        XCTAssertTrue(monitorIsInstalled(controller), "a re-mounted annotating overlay must hear Escape again")
        controller.unmount()
    }

    func testRepeatedStartsInstallExactlyOneMonitor() {
        // `installEscapeMonitor` is guarded, so a second `start()` cannot strand the
        // first token — which would be unremovable, since only the latest is kept.
        let controller = makeController()
        controller.start()
        let first = Mirror(reflecting: controller).children.first { $0.label == "escapeMonitor" }?.value
        controller.start()
        let second = Mirror(reflecting: controller).children.first { $0.label == "escapeMonitor" }?.value
        XCTAssertTrue(
            (first as AnyObject) === (second as AnyObject),
            "the second start must reuse the installed monitor, not leak the first"
        )
        controller.stop()
        XCTAssertFalse(monitorIsInstalled(controller))
    }
}
#endif
