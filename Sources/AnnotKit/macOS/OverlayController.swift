#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the annotation overlay on macOS as a transparent, always-interactive
/// `NSPanel` at status-bar level. The panel is sized to just the toolbar corner
/// when idle (so the rest of the screen is the host app) and to the full screen
/// while annotating (so the SwiftUI catcher can receive hover and clicks over the
/// app). Interaction is handled in `OverlayView` via SwiftUI hit-testing, so the
/// toolbar is always clickable and clicks on the overlay's own chrome never
/// trigger element selection.
@MainActor
public final class OverlayController {
    public let session: AnnotationSession
    private var panel: NSPanel?

    public init(session: AnnotationSession) {
        self.session = session
    }

    public func mount() {
        guard panel == nil, let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: frame(for: .idle, on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: OverlayView(
            session: session,
            onToggle: { [weak self] in self?.toggle() },
            onFlush: { [weak self] in self?.flush() }
        ))
        // Keep the overlay out of the app's own AX tree so the point query sees
        // through it (the SwiftUI root is also `accessibilityHidden`).
        host.setAccessibilityElement(false)
        panel.contentView = host
        panel.orderFrontRegardless()

        self.panel = panel
    }

    public func unmount() {
        panel?.orderOut(nil)
        panel = nil
    }

    public func toggle() {
        session.mode == .annotating ? stop() : start()
    }

    public func start() {
        session.start()
        applyFrame()
    }

    public func stop() {
        session.stop()
        applyFrame()
    }

    private func flush() {
        try? session.flush()
    }

    private func applyFrame() {
        guard let panel, let screen = NSScreen.main else { return }
        panel.setFrame(frame(for: session.mode, on: screen), display: true)
    }

    private func frame(for mode: AnnotationSession.Mode, on screen: NSScreen) -> NSRect {
        switch mode {
        case .annotating:
            return screen.frame
        case .idle:
            // Bottom-right corner, big enough for the toolbar (plus a pending
            // badge and Save button), anchored so it does not move when the
            // panel grows to full screen.
            let size = NSSize(width: 380, height: 130)
            return NSRect(
                x: screen.frame.maxX - size.width,
                y: screen.frame.minY,
                width: size.width,
                height: size.height
            )
        }
    }
}
#endif
