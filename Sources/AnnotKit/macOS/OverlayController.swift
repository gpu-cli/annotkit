#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the annotation overlay on macOS as a transparent `NSPanel` attached as a
/// **child window** of the host app's own window (`addChildWindow(_:ordered:.above)`),
/// not floating at `.statusBar` over the whole desktop. AppKit keeps a child glued
/// directly above its parent in the window stack and moves it with the parent
/// across Spaces, hide, and miniaturize, so the overlay can never sit over another
/// app or the desktop, and it hides whenever the host app hides — this replaces
/// the old `.canJoinAllSpaces`/`.statusBar`/`orderFrontRegardless` behavior.
///
/// The panel is sized to just the toolbar corner of the host window when idle (so
/// the rest of the app stays usable) and to the host window's full frame while
/// annotating (so the SwiftUI catcher receives hover and clicks over the app).
/// Because it is pinned to one window, all coordinates collapse to a single fixed
/// AX origin (`axOrigin`), which also makes placement correct on any display —
/// no `NSScreen.main` (active-screen) assumption. Child windows follow the
/// parent's position automatically but do **not** auto-resize, so the host window
/// is observed for move/resize/screen changes to keep the frame and `axOrigin` in
/// sync.
@MainActor
public final class OverlayController: NSObject {
    public let session: AnnotationSession
    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<OverlayView>?
    private weak var host: NSWindow?

    /// AX top-left origin of the host window, threaded into `OverlayView` so click,
    /// highlight, and composer share one transform. Recomputed on every geometry
    /// change.
    private var axOrigin: CGPoint = .zero
    /// Host-window-local size, for clamping the composer on-screen.
    private var surfaceSize: CGSize = .zero

    public init(session: AnnotationSession) {
        self.session = session
        super.init()
    }

    public func mount() {
        guard panel == nil else { return }
        guard let host = hostWindow() else {
            // Embedded tools always get a window eventually; retry when one
            // becomes main rather than dropping the install on the floor.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowAppeared(_:)),
                name: NSWindow.didBecomeMainNotification,
                object: nil
            )
            return
        }
        attach(to: host)
    }

    public func unmount() {
        NotificationCenter.default.removeObserver(self)
        if let panel {
            host?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        hostingView = nil
        host = nil
    }

    public func toggle() {
        session.mode == .annotating ? stop() : start()
    }

    public func start() {
        // Bring the host app frontmost (fixes "host is behind other apps",
        // including the swift-run launch quirk) before capturing clicks. Done
        // library-side so it is robust for any host, not just a self-activating
        // demo. The panel stays a non-activating child, so its own key focus for
        // the composer text field is unaffected.
        NSApp.activate(ignoringOtherApps: true)
        host?.orderFront(nil)
        session.start()
        syncFrameAndOrigin()
    }

    public func stop() {
        session.stop()
        syncFrameAndOrigin()
    }

    private func export() {
        try? session.export()
    }

    private func copy() {
        try? ClipboardSink().flush(session.pending)
    }

    // MARK: - Host window

    /// Pick the host window once, excluding our own panels so we never attach to
    /// (or resolve coordinates against) ourselves.
    private func hostWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is KeyablePanel) && $0.contentView != nil }
    }

    private func attach(to host: NSWindow) {
        self.host = host

        let panel = KeyablePanel(
            contentRect: frame(for: .idle, on: host),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        // Tag the panel WINDOW so `AXIntrospection` can skip it in the point
        // query and the snapshot. Marking the SwiftUI content non-accessible is
        // not enough: once the panel expands to the host's full frame it is a
        // live `AXWindow` that the point query hits first, so the whole app
        // resolves to the overlay's hosting view instead of the control beneath.
        panel.setAccessibilityIdentifier(AXIntrospection.overlayWindowIdentifier)

        let hostingView = NSHostingView(rootView: makeRootView())
        // Keep the overlay out of the app's own AX tree so the point query sees
        // through it (the SwiftUI root is also `accessibilityHidden`).
        hostingView.setAccessibilityElement(false)
        panel.contentView = hostingView

        // Glue the panel directly above the host window. This is what fixes the
        // layering: no window level, no all-Spaces behavior, no
        // orderFrontRegardless.
        host.addChildWindow(panel, ordered: .above)

        self.panel = panel
        self.hostingView = hostingView

        // We have a host now, so drop the retry observer and start tracking
        // geometry.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        registerGeometryObservers(for: host)
        syncFrameAndOrigin()
    }

    private func makeRootView() -> OverlayView {
        OverlayView(
            session: session,
            axOrigin: axOrigin,
            surfaceSize: surfaceSize,
            onToggle: { [weak self] in self?.toggle() },
            onCopy: { [weak self] in self?.copy() },
            onExport: { [weak self] in self?.export() },
            onClose: { [weak self] in self?.unmount() }
        )
    }

    // MARK: - Geometry

    private func registerGeometryObservers(for host: NSWindow) {
        let center = NotificationCenter.default
        // A child follows the parent's position automatically but does not
        // resize with it, and neither the child nor AppKit recomputes our AX
        // origin — so re-sync on every geometry change. One handler covers move
        // (origin stale), resize (frame + origin stale), and screen changes.
        center.addObserver(self, selector: #selector(hostGeometryChanged(_:)),
                           name: NSWindow.didMoveNotification, object: host)
        center.addObserver(self, selector: #selector(hostGeometryChanged(_:)),
                           name: NSWindow.didResizeNotification, object: host)
        center.addObserver(self, selector: #selector(hostGeometryChanged(_:)),
                           name: NSWindow.didChangeScreenNotification, object: host)
        center.addObserver(self, selector: #selector(hostGeometryChanged(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func hostGeometryChanged(_ note: Notification) {
        syncFrameAndOrigin()
    }

    @objc private func hostWindowAppeared(_ note: Notification) {
        guard panel == nil, hostWindow() != nil else { return }
        mount()
    }

    /// Resize the child to the current mode's frame and recompute the AX origin
    /// and surface size, then push both into the SwiftUI view.
    private func syncFrameAndOrigin() {
        guard let panel, let host else { return }
        panel.setFrame(frame(for: session.mode, on: host), display: true)
        // Primary display = the origin/menu-bar screen, NOT NSScreen.main (the
        // active screen), which was the single-display bug.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        axOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: host.frame, primaryHeight: primaryHeight)
        surfaceSize = host.frame.size
        hostingView?.rootView = makeRootView()
    }

    private func frame(for mode: AnnotationSession.Mode, on host: NSWindow) -> NSRect {
        switch mode {
        case .annotating:
            // The host window's full outer frame (includes the title bar so the
            // window-local y aligns with AX y).
            return host.frame
        case .idle:
            // A small panel sized to the pill's real bounds, pinned to the host
            // window's bottom-right corner, so the idle overlay covers only the
            // toolbar and never swallows clicks meant for the host. Width fits the
            // widest pill state (toggle + count badge + copy + export + clear +
            // divider + close, ~200pt) plus its 20pt inset and the drop shadow;
            // height fits the 44pt pill plus the same inset. Anchored to the
            // window so it rides along on move and is recomputed on resize.
            let size = NSSize(width: 240, height: 104)
            return NSRect(
                x: host.frame.maxX - size.width,
                y: host.frame.minY,
                width: size.width,
                height: size.height
            )
        }
    }
}

/// A borderless, non-activating panel that can still become key, so the note
/// composer's text field accepts keyboard input (a plain borderless panel
/// cannot become key, which silently blocks typing). `.nonactivatingPanel`
/// keeps it from stealing app activation on hover; `canBecomeKey` lets a click
/// into the composer focus the field. Used as a child window per host window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
#endif
