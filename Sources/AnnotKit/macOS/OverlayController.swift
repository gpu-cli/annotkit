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

    /// Host frame captured at the last geometry sync. A SwiftUI/content-sized host
    /// can attach at its PRE-LAYOUT frame and grow to its final size a runloop turn
    /// or two later without posting `didMove`/`didResize`; comparing against this
    /// lets the post-attach settle poll tell when the frame has stabilized.
    private var lastSyncedHostFrame: NSRect = .null
    /// Bumped on every attach/unmount so an in-flight settle poll for a previous
    /// host stops instead of re-syncing against a stale (or detached) window.
    private var settleGeneration = 0

    /// The Escape key monitor's token, non-nil ONLY while annotate mode is running.
    /// Held so it can be removed in both exits (``stop()`` and ``unmount()``): AppKit
    /// keeps a local monitor alive until it is explicitly removed, so a leaked one
    /// would keep swallowing the host app's own Escape long after the overlay was
    /// gone — a bug that presents as "this app's dialogs stopped closing".
    private var escapeMonitor: Any?

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

    /// Mount the overlay on a SPECIFIC host window, bypassing the `hostWindow()`
    /// auto-picker. Use when the caller already knows the exact window to annotate
    /// (e.g. a settings/document window): the auto-picker
    /// (`NSApp.mainWindow ?? keyWindow ?? first visible non-panel`) can otherwise
    /// resolve to a floating panel when several windows are visible.
    public func mount(on host: NSWindow) {
        guard panel == nil else { return }
        attach(to: host)
    }

    public func unmount() {
        NotificationCenter.default.removeObserver(self)
        // Unmounting can happen mid-annotate (a host window closing), which never
        // routes through `stop()`. A monitor outliving the overlay it belongs to is
        // the one failure here that damages the HOST rather than AnnotKit: it keeps
        // eating Escape for the life of the process.
        removeEscapeMonitor()
        // Invalidate any in-flight settle poll so it cannot re-sync a detached host.
        settleGeneration += 1
        lastSyncedHostFrame = .null
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
        installEscapeMonitor()
    }

    public func stop() {
        // Remove FIRST: the monitor exists to serve annotate mode, and leaving it
        // installed for even the rest of this call would let a keystroke arrive while
        // the session is half-torn-down.
        removeEscapeMonitor()
        session.stop()
        syncFrameAndOrigin()
    }

    private func export() {
        try? session.export()
    }

    private func copy() {
        try? ClipboardSink().flush(session.pending)
    }

    // MARK: - Escape

    /// Start watching for Escape while annotate mode runs.
    ///
    /// A LOCAL monitor, not a SwiftUI modifier and not a global one, and both halves
    /// of that matter:
    ///
    /// * A panel-scoped modifier (`.onExitCommand`) only fires when the overlay panel
    ///   is KEY, and the panel is made key solely by a card focusing its text field.
    ///   In the state a user most wants to leave — annotate mode with nothing open —
    ///   the HOST window is key, so no view in the panel ever sees the keystroke.
    /// * A local monitor sees events on their way to THIS process's windows, which
    ///   works precisely because AnnotKit is in-process with its host: the Escape
    ///   headed for the host window passes through here first. (A global monitor
    ///   watches OTHER apps, cannot consume the event, and would need accessibility
    ///   permission — all three wrong for this.)
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    /// Decide one key-down. EVERY event in the app flows through here while annotate
    /// mode runs, so the non-Escape path does nothing but return the event: any work
    /// on this path is work added to every keystroke the user types into their own
    /// app, and any early `return nil` is a character they never see.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 53 is Escape's virtual key code — a hardware position, so it is
        // layout-independent (a character comparison would miss on layouts that
        // remap, and `charactersIgnoringModifiers` is empty for some IMEs).
        guard event.keyCode == 53 else { return event }

        let action = EscapeRule.resolve(
            isAnnotating: session.mode == .annotating,
            isDrawingFrame: session.isDrawingFrame,
            hasOpenCard: session.hasOpenCard
        )
        switch action {
        case .cancelDrag:
            session.cancelFrameDrag()
        case .dismissCard:
            // The composer and the pin editor are mutually exclusive, and the composer
            // wins the same theoretical tie the view's render ladder gives it, so the
            // card that closes is always the card that is drawn.
            if session.selected != nil {
                session.cancelSelection()
            } else {
                session.endEditing()
            }
        case .exitAnnotateMode:
            // The CONTROLLER's stop, never `session.stop()`: leaving the mode also
            // shrinks the panel back to the toolbar corner and re-syncs the AX origin.
            // Stopping the session alone would leave a full-window transparent panel
            // over the host, swallowing every click with no visible overlay to explain
            // why — and this monitor would stay installed on top of that.
            stop()
        case .passThrough:
            break
        }
        // Swallow anything we acted on. Forwarding a handled Escape means the host
        // ALSO acts on it (we are in its process, and the event is still on its way to
        // its key window), so one press would both leave annotate mode and close the
        // host's sheet.
        return action.consumesEvent ? nil : event
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
        // A content-sized host is often still at its pre-layout frame right here and
        // grows a runloop turn or two later without posting a move/resize; poll until
        // the host frame settles so the panel and axOrigin reflect the FINAL frame.
        scheduleSettleResync()
        // Re-arm Escape if we are attaching INTO an already-annotating session.
        // `unmount()` removes the monitor, and the session's mode outlives the
        // controller's panel — so a host that unmounts and re-mounts a live
        // overlay (window recycling, a host that tears down on hide) would come
        // back with annotate mode on and Escape silently dead, the one state with
        // no other keyboard way out. `installEscapeMonitor()` is idempotent, so
        // the ordinary mount-then-start path is unaffected.
        if session.mode == .annotating { installEscapeMonitor() }
    }

    private func makeRootView() -> OverlayView {
        OverlayView(
            session: session,
            axOrigin: axOrigin,
            surfaceSize: surfaceSize,
            onToggle: { [weak self] in self?.toggle() },
            onCopy: { [weak self] in self?.copy() },
            onExport: { [weak self] in self?.export() },
            // Make the non-activating child panel key so the composer/pin-editor
            // text fields accept keystrokes (a plain borderless panel that is not
            // key silently drops typing).
            onFocusRequest: { [weak self] in self?.panel?.makeKey() }
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

    /// Re-sync across the next several runloop turns until the host frame stops
    /// changing. A SwiftUI/content-sized host attaches at its PRE-LAYOUT frame and
    /// grows to its final laid-out size a turn or two later WITHOUT posting
    /// `didMove`/`didResize` (content-driven sizing does not fire those), so the
    /// notification observers alone leave the panel frame and `axOrigin` stale at the
    /// initial tiny frame — which is both the misplacement and the dead AX hit-test.
    /// This poll catches that settle; it is bounded (self-terminating) and guarded by
    /// a generation token so it stops on unmount / re-attach, and the observers still
    /// cover any move/resize after the window has settled. A host created at its final
    /// size (the demo, the probes) is already stable, so this does zero extra syncs.
    private func scheduleSettleResync() {
        settleGeneration += 1
        pollSettle(generation: settleGeneration, ticksRemaining: 24, stableTicks: 0)
    }

    private func pollSettle(generation: Int, ticksRemaining: Int, stableTicks: Int) {
        // ~40ms/turn gives layout a real runloop turn to run between polls; a burst of
        // plain `async` blocks would drain before SwiftUI lays out and miss the growth.
        // A 24-tick budget (~1s) is far more than layout needs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, generation == self.settleGeneration, let host = self.host else { return }
            var stable = stableTicks
            if host.frame == self.lastSyncedHostFrame {
                stable += 1
            } else {
                stable = 0
                self.syncFrameAndOrigin()
            }
            // Stop once the frame has held for two consecutive turns (settled) or the
            // budget is spent; otherwise keep polling for the post-layout growth.
            guard ticksRemaining > 1, stable < 2 else { return }
            self.pollSettle(generation: generation, ticksRemaining: ticksRemaining - 1, stableTicks: stable)
        }
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
        lastSyncedHostFrame = host.frame
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
            // widest pill state (toggle + count badge + copy + export + clear,
            // ~180pt) plus its 20pt inset and the drop shadow; height fits the 44pt
            // pill plus the same inset. Anchored to the
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
