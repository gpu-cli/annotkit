#if os(macOS)
import AppKit
import XCTest
@testable import AnnotKit

/// The panel's scroll hand-off, at the unit level.
///
/// The overlay panel covers the host while annotating, so wheel events land on the
/// panel. It must scroll the host WITHOUT the event object ever entering the host's
/// view tree: NSScrollView answers a phase `began` (every trackpad scroll) by engaging
/// event tracking against `event.window` — the PANEL — and that cross-window tracking
/// wedges the panel's event delivery and display. That was the vanishing-toolbar bug.
/// The design under test drives the enclosing scroller's clip directly by the deltas.
/// Flipped like every real host document (SwiftUI and NSHostingView documents are
/// flipped): a non-flipped document starts with its origin at the content's END, so
/// a downward scroll is correctly a no-op there and the fixture would prove nothing.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ScrollForwardTests: XCTestCase {
    private func makeHost() -> (NSWindow, NSScrollView) {
        let host = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 400, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.orderFront(nil)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        host.contentView?.addSubview(scroll)
        return (host, scroll)
    }

    private func makePanel(over host: NSWindow) -> KeyablePanel {
        let panel = KeyablePanel(contentRect: host.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        host.addChildWindow(panel, ordered: .above)
        return panel
    }

    private func wheel(at panelLocal: CGPoint, deltaY: Int32, phase: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: deltaY, wheel2: 0, wheel3: 0)!
        if phase != 0 {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: panelLocal.x, y: primaryHeight - panelLocal.y)
        return NSEvent(cgEvent: cg)!
    }

    func testWheelOverThePanelScrollsTheHostScroller() {
        let (host, scroll) = makeHost()
        defer { host.orderOut(nil) }
        let panel = makePanel(over: host)

        let before = scroll.contentView.bounds.origin.y
        panel.scrollWheel(with: wheel(at: CGPoint(x: 200, y: 300), deltaY: -120))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before,
                             "a wheel that landed on the panel must move the host's clip")
    }

    /// The trackpad stream that used to wedge the overlay: phase-tagged events must
    /// scroll like any other, and the mechanism (direct clip drive) guarantees the
    /// host's own `scrollWheel` never sees the cross-window event.
    func testPhaseTaggedWheelScrollsToo() {
        let (host, scroll) = makeHost()
        defer { host.orderOut(nil) }
        let panel = makePanel(over: host)

        let before = scroll.contentView.bounds.origin.y
        panel.scrollWheel(with: wheel(at: CGPoint(x: 200, y: 300), deltaY: -120, phase: 1))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before,
                             "a phase-tagged (trackpad) wheel must scroll — this stream wedged the old design")
    }

    /// The event object must never be delivered into the host's view tree — that IS
    /// the bug. A scroller subclass records whether its `scrollWheel` ran.
    func testTheEventObjectNeverEntersTheHostViewTree() {
        final class RecordingScrollView: NSScrollView {
            nonisolated(unsafe) static var sawEvent = false
            override func scrollWheel(with event: NSEvent) { Self.sawEvent = true }
        }
        let host = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 400, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let scroll = RecordingScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        host.contentView?.addSubview(scroll)
        let panel = makePanel(over: host)

        RecordingScrollView.sawEvent = false
        panel.scrollWheel(with: wheel(at: CGPoint(x: 200, y: 300), deltaY: -120, phase: 1))
        XCTAssertFalse(RecordingScrollView.sawEvent,
                       "the cross-window event reached the host's scrollWheel — the wedge is back")
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "yet the clip still moved")
    }
}
#endif
