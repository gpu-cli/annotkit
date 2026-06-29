#if os(macOS)
import AppKit
import CoreGraphics
import SwiftUI

/// Hosts the annotation overlay on macOS: a transparent, AX-excluded `NSPanel`
/// at status-bar level that is click-through when idle and captures clicks in
/// annotate mode. A local event monitor feeds mouse moves and clicks (converted
/// to AX top-left coordinates) into the ``AnnotationSession``.
@MainActor
public final class OverlayController {
    public let session: AnnotationSession
    private var panel: NSPanel?
    private var monitor: Any?
    /// Hover throttle. The hit-test uses the cheap AX point query (not a full
    /// tree walk), so a light ~60fps cap is enough; no tree cache is needed.
    private var lastHover = Date.distantPast
    private let hoverInterval: TimeInterval = 1.0 / 60.0

    public init(session: AnnotationSession) {
        self.session = session
    }

    /// Create and show the overlay panel.
    public func mount() {
        guard panel == nil else { return }
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: OverlayView(
            session: session,
            onToggle: { [weak self] in self?.toggle() },
            onFlush: { [weak self] in self?.flush() }
        ))
        // Keep the overlay out of our own AX tree so the hit-test never
        // resolves to it.
        host.setAccessibilityElement(false)
        panel.contentView = host
        panel.orderFrontRegardless()

        self.panel = panel
        installMonitor()
    }

    /// Remove the overlay and its event monitor.
    public func unmount() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    public func toggle() {
        session.mode == .annotating ? stop() : start()
    }

    public func start() {
        session.start()
        panel?.ignoresMouseEvents = false
    }

    public func stop() {
        session.stop()
        panel?.ignoresMouseEvents = true
    }

    private func flush() {
        try? session.flush()
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard session.mode == .annotating else { return }
        let height = (NSScreen.main ?? NSScreen.screens.first)?.frame.height ?? 0
        let axPoint = ScreenSpace.flipPoint(NSEvent.mouseLocation, primaryHeight: height)
        switch event.type {
        case .mouseMoved:
            let now = Date()
            guard now.timeIntervalSince(lastHover) >= hoverInterval else { return }
            lastHover = now
            session.hover(atAXPoint: axPoint)
        case .leftMouseDown:
            session.select(atAXPoint: axPoint)
        default:
            break
        }
    }
}
#endif
