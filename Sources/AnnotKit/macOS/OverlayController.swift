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
/// annotating (so the SwiftUI catcher receives hover and clicks over the app) —
/// both narrowed to the display's `visibleFrame` by ``OverlayPlacement``, because a
/// host taller than the screen would otherwise draw its toolbar under the Dock.
/// Because it is pinned to one window, all coordinates collapse to a single fixed
/// AX origin (`axOrigin`), which also makes placement correct on any display —
/// no `NSScreen.main` (active-screen) assumption. Child windows follow the
/// parent's position automatically but do **not** auto-resize, so the host window
/// is observed for move/resize/screen changes to keep the frame and `axOrigin` in
/// sync.
@MainActor
public final class OverlayController: NSObject {
    public let session: AnnotationSession
    /// The TOOLBAR panel: permanently mounted, fixed size, pinned to the host's
    /// bottom-right. It holds only the pill, and its frame changes for exactly one
    /// reason — the host moved, resized, or changed screen. Opening and closing the
    /// menu does not touch it, which is what makes the pill "always visible, always
    /// in the same spot" a structural property rather than a coincidence.
    ///
    /// KNOWN LIMITATION, measured rather than assumed (`AnnotKitOverlayProbe` 11a,
    /// DECISIONS.md → "The toolbar panel claims its whole frame"): this panel is
    /// 240x104 while the pill occupies only its bottom-right corner, and it consumes
    /// presses across the WHOLE rect. macOS does not pass mouse events through the
    /// transparent parts of a window — a panel whose content view draws nothing at
    /// all swallows a click just the same — and `ignoresMouseEvents = true`, the one
    /// thing that would let them through, would take the pill's own clicks with it.
    /// So the host's bottom-right 240x104 is inert to clicks and to the start of a
    /// frame drag, in both modes. Shrinking the panel to the pill is the fix and it
    /// is deliberately not made here.
    private var toolbarPanel: KeyablePanel?
    private var toolbarHosting: NSHostingView<ToolbarOverlayView>?
    /// The CATCHER panel: exists ONLY while the menu is open. Covers the host so the
    /// SwiftUI catcher can receive hover and clicks, and carries the highlight, the
    /// marquee band, the pins and the cards. Ordered BELOW the toolbar panel so the
    /// pill stays clickable, and torn down on close so nothing of it can outlive the
    /// open state.
    private var catcherPanel: KeyablePanel?
    private var catcherHosting: NSHostingView<OverlayView>?
    private weak var host: NSWindow?

    /// AX top-left origin of the overlay PANEL — the surface `OverlayView` draws into,
    /// which is the host window narrowed to the visible screen — threaded into the view
    /// so click, highlight, and composer share one transform. Recomputed on every
    /// geometry change.
    private var axOrigin: CGPoint = .zero
    /// Panel-local size, for clamping the composer inside the visible region.
    private var surfaceSize: CGSize = .zero
    /// How many times a fresh SwiftUI root view has been pushed into the hosting view.
    /// Rebuilding it mid-hover is what makes the pill flicker or vanish, so the probe
    /// asserts a storm of redundant geometry notifications pushes none.
    private(set) var rootViewPushes = 0

    /// Host frame captured at the last geometry sync. A SwiftUI/content-sized host
    /// can attach at its PRE-LAYOUT frame and grow to its final size a runloop turn
    /// or two later without posting `didMove`/`didResize`; comparing against this
    /// lets the post-attach settle poll tell when the frame has stabilized.
    private var lastSyncedHostFrame: NSRect = .null
    /// The clamped frames each panel is SUPPOSED to occupy, re-asserted after
    /// AppKit's parent-follow repositioning. `.null` when there is nothing to hold
    /// (no sync yet, or the catcher is closed).
    private var desiredToolbarFrame: NSRect = .null
    private var desiredCatcherFrame: NSRect = .null
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
        guard toolbarPanel == nil else { return }
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
        guard toolbarPanel == nil else { return }
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
        dismissCatcher()
        if let toolbarPanel {
            host?.removeChildWindow(toolbarPanel)
            toolbarPanel.orderOut(nil)
        }
        toolbarPanel = nil
        toolbarHosting = nil
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
        if let host { presentCatcher(on: host) }
        syncFrameAndOrigin()
        installEscapeMonitor()
    }

    public func stop() {
        // Remove FIRST: the monitor exists to serve annotate mode, and leaving it
        // installed for even the rest of this call would let a keystroke arrive while
        // the session is half-torn-down.
        removeEscapeMonitor()
        session.stop()
        dismissCatcher()
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
            contentRect: OverlayPlacement.toolbarFrame(hostFrame: host.frame, visibleFrame: visibleFrame(for: host)),
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

        let hostingView = NSHostingView(rootView: makeToolbarView())
        // Keep the overlay out of the app's own AX tree so the point query sees
        // through it (the SwiftUI root is also `accessibilityHidden`).
        hostingView.setAccessibilityElement(false)
        panel.contentView = hostingView

        // Glue the panel directly above the host window. This is what fixes the
        // layering: no window level, no all-Spaces behavior, no
        // orderFrontRegardless.
        host.addChildWindow(panel, ordered: .above)

        self.toolbarPanel = panel
        self.toolbarHosting = hostingView
        // Re-open the catcher if we are attaching INTO an already-open menu.
        if session.mode == .annotating { presentCatcher(on: host) }

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

    /// Build a transparent, non-activating child panel. Shared so the toolbar and the
    /// catcher cannot drift in the properties that make an overlay behave —
    /// transparency, shadowlessness, and the AX identifier the point query skips.
    private func makePanel(frame: NSRect) -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        // Tag the panel WINDOW so `AXIntrospection` skips it in the point query and
        // the snapshot: a full-frame panel is a live `AXWindow` the query would hit
        // first, resolving every click to the overlay instead of the app beneath.
        panel.setAccessibilityIdentifier(AXIntrospection.overlayWindowIdentifier)
        return panel
    }

    /// Open the catcher over the host. Idempotent.
    private func presentCatcher(on host: NSWindow) {
        guard catcherPanel == nil else { return }
        let panel = makePanel(frame: OverlayPlacement.catcherFrame(hostFrame: host.frame,
                                                                  visibleFrame: visibleFrame(for: host)))
        let hosting = NSHostingView(rootView: makeRootView())
        hosting.setAccessibilityElement(false)
        panel.contentView = hosting
        // While the menu is open THIS panel scrolls the host (it covers the whole
        // window, so the wheel never reaches the host's own scroller), which makes it
        // the one place that knows exactly how far the content moved. Feed that back
        // into the notes so a pin — and the mark recalled from it — stays on the
        // content it was made on. Wired on the CATCHER only: the toolbar panel is a
        // 240x104 corner that no host scroller lives under.
        panel.onHostScrolled = { [weak self] translation, viewport in
            self?.session.translateNotes(by: translation, within: viewport)
        }
        host.addChildWindow(panel, ordered: .above)
        catcherPanel = panel
        catcherHosting = hosting
        // The toolbar must stay ABOVE the catcher, or the full-frame catcher swallows
        // every click meant for the pill — including the one that closes the menu.
        //
        // Re-adding an existing child does NOT re-stack it (measured: `childWindows`
        // still ended with the catcher, and the catcher sat on top). Detaching first
        // is what actually moves the toolbar to the end of the child order, and
        // ordering it explicitly above the catcher pins the window-server z-order the
        // clicks actually follow.
        if let toolbarPanel {
            host.removeChildWindow(toolbarPanel)
            host.addChildWindow(toolbarPanel, ordered: .above)
            toolbarPanel.order(.above, relativeTo: panel.windowNumber)
        }
    }

    /// Close the catcher. Idempotent; leaves the toolbar untouched.
    private func dismissCatcher() {
        guard let panel = catcherPanel else { return }
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
        catcherPanel = nil
        catcherHosting = nil
    }

    private func visibleFrame(for host: NSWindow) -> NSRect? {
        (host.screen ?? NSScreen.screens.first)?.visibleFrame
    }

    private func makeToolbarView() -> ToolbarOverlayView {
        ToolbarOverlayView(
            session: session,
            onToggle: { [weak self] in self?.toggle() },
            onCopy: { [weak self] in self?.copy() },
            onExport: { [weak self] in self?.export() }
        )
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
            onFocusRequest: { [weak self] in self?.catcherPanel?.makeKey() }
        )
    }

    // MARK: - Geometry

    private func registerGeometryObservers(for host: NSWindow) {
        let center = NotificationCenter.default
        // A child follows the parent's position automatically but does not
        // resize with it, and neither the child nor AppKit recomputes our AX
        // origin — so re-sync on every geometry change. One handler covers move
        // (origin stale), resize (frame + origin stale), and screen changes. The
        // screen-parameters observer earns its keep twice over now that placement is
        // clamped: a Dock that appears, or a display that changes resolution, moves
        // `visibleFrame` without touching the host's frame, and the pill has to follow.
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
        guard toolbarPanel == nil, hostWindow() != nil else { return }
        mount()
    }

    /// Re-place BOTH panels for the current host geometry and push the catcher's
    /// coordinates into its SwiftUI root.
    ///
    /// The toolbar's frame does not depend on the mode, so opening or closing the
    /// menu leaves the pill exactly where it was — that is the whole point of giving
    /// it its own window.
    private func syncFrameAndOrigin() {
        guard let host else { return }
        let visible = visibleFrame(for: host)

        let toolbarFrame = OverlayPlacement.toolbarFrame(hostFrame: host.frame, visibleFrame: visible)
        desiredToolbarFrame = toolbarFrame
        toolbarPanel?.setFrame(toolbarFrame, display: true)

        let catcherFrame = OverlayPlacement.catcherFrame(hostFrame: host.frame, visibleFrame: visible)
        desiredCatcherFrame = catcherPanel == nil ? .null : catcherFrame
        catcherPanel?.setFrame(catcherFrame, display: true)

        // Always record the host frame, even on the early-out below: the settle poll
        // decides "has the host stopped growing" by comparing against this, so leaving
        // it stale would keep the poll re-syncing a window that has already settled.
        lastSyncedHostFrame = host.frame

        // AppKit repositions a CHILD window to follow its parent, and does so AFTER
        // the `didMove` notification we are reacting to — so the clamped frames we
        // just applied get dragged back a runloop turn later. Measured, with
        // forensics on: computed=(1272,60,240,104) then next-turn=(1272,-200,...).
        // Re-assert once AppKit has finished; it is a no-op when nothing fought us.
        DispatchQueue.main.async { [weak self] in self?.enforcePanelFrames() }

        // Primary display = the origin/menu-bar screen, NOT NSScreen.main (the active
        // screen), which was the single-display bug.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Derived from the CATCHER's frame, never the host's: `OverlayView`'s contract
        // is that these describe the surface it draws into — the catcher ADDS
        // `axOrigin` to turn a panel-local click into an AX screen point, the
        // highlight and composer SUBTRACT it — so a host-derived origin would offset
        // every click, highlight and card by exactly the clipped amount.
        let newAXOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: catcherFrame, primaryHeight: primaryHeight)

        // Push a new SwiftUI root ONLY when something it renders from changed. A host
        // emitting a burst of move/resize notifications would otherwise rebuild the
        // catcher on each one; the pill is no longer in that view, so this can no
        // longer flicker the toolbar, but the churn is still wasted work.
        guard newAXOrigin != axOrigin || catcherFrame.size != surfaceSize else { return }
        axOrigin = newAXOrigin
        surfaceSize = catcherFrame.size
        rootViewPushes += 1
        catcherHosting?.rootView = makeRootView()
    }

    /// Put both panels back where placement said they belong, if AppKit moved them.
    ///
    /// Child windows are repositioned to preserve their offset from the parent, which
    /// undoes the visible-frame clamp on every host move. Comparing before setting
    /// keeps this free when nothing fought us, and keeps it from looping: a `setFrame`
    /// to the frame a window already has posts no move.
    private func enforcePanelFrames() {
        enforce(toolbarPanel, desiredToolbarFrame, "toolbar")
        enforce(catcherPanel, desiredCatcherFrame, "catcher")
    }

    private func enforce(_ panel: KeyablePanel?, _ desired: NSRect, _ label: String) {
        guard let panel, desired != .null, panel.frame != desired else { return }
        if KeyablePanel.forensics {
            FileHandle.standardError.write(Data(
                "[sync] re-asserting \(label) frame: \(panel.frame) -> \(desired)\n".utf8))
        }
        panel.setFrame(desired, display: true)
    }

    private func frame(for mode: AnnotationSession.Mode, on host: NSWindow) -> NSRect {
        OverlayPlacement.panelFrame(
            for: mode,
            hostFrame: host.frame,
            // `host.screen` is the display the window is mostly on, so the clamp
            // follows the host across displays. A window AppKit reports no screen for
            // (entirely off-display, or mid-teardown) falls back to the primary rather
            // than skipping the clamp, so the pill still lands somewhere reachable.
            visibleFrame: (host.screen ?? NSScreen.screens.first)?.visibleFrame
        )
    }
}

/// Where the overlay panel goes, as pure geometry — no window, no display, so the
/// rules below are unit-testable instead of only observable on a real screen.
enum OverlayPlacement {
    /// The idle panel's size: fits the widest pill state (toggle + count badge + copy
    /// + export + clear, ~180pt) plus its 20pt inset and the drop shadow, and the 44pt
    /// pill plus the same inset.
    static let idleSize = CGSize(width: 240, height: 104)

    /// The part of the host the user can actually see and click: its frame narrowed to
    /// the screen's `visibleFrame`.
    ///
    /// `visibleFrame` and not `frame`, because the Dock and menu bar cover the
    /// display's edges and a pill under the Dock is exactly as unreachable as one off
    /// the display.
    ///
    /// This is the whole of the "on scrollable screens the menu in the bottom right
    /// disappears" bug: BOTH modes anchor the toolbar to the host's BOTTOM edge, and
    /// AppKit constrains a window's TOP under the menu bar but never lifts its bottom —
    /// so a host taller than the display (the shape a content-sized/scrollable window
    /// grows into, the same growth ``OverlayController/scheduleSettleResync()`` exists
    /// to catch) hangs its bottom edge below `visibleFrame`, and an unclamped anchor
    /// draws the pill under the Dock or off the display entirely.
    ///
    /// An EMPTY intersection means the host is off-display altogether (another Space, a
    /// window parked off-screen). Keep the unclamped frame there rather than collapse
    /// the panel to nothing: a zero-sized panel would have to be rebuilt to come back,
    /// whereas an off-screen one simply reappears with its window.
    static func region(hostFrame: CGRect, visibleFrame: CGRect?) -> CGRect {
        guard let visibleFrame else { return hostFrame }
        let region = hostFrame.intersection(visibleFrame)
        return region.isEmpty ? hostFrame : region
    }

    /// The TOOLBAR panel's frame: a fixed-size corner, pinned to the visible region's
    /// bottom-right. Identical in both states — the menu opening must never move the
    /// pill — and dependent only on where the host is, never on what mode it is in.
    static func toolbarFrame(hostFrame: CGRect, visibleFrame: CGRect?) -> CGRect {
        let region = region(hostFrame: hostFrame, visibleFrame: visibleFrame)
        // Anchored at FULL size rather than intersected down to the region: shrinking
        // this panel would clip the pill it exists to carry. Pinning its BOTTOM edge
        // inside the region is what keeps the pill reachable; only the panel's empty
        // upper part may spill past a region shorter than itself.
        return CGRect(
            x: region.maxX - idleSize.width,
            y: region.minY,
            width: idleSize.width,
            height: idleSize.height
        )
    }

    /// The CATCHER panel's frame: the host, narrowed to what is on screen.
    static func catcherFrame(hostFrame: CGRect, visibleFrame: CGRect?) -> CGRect {
        region(hostFrame: hostFrame, visibleFrame: visibleFrame)
    }

    static func panelFrame(for mode: AnnotationSession.Mode, hostFrame: CGRect, visibleFrame: CGRect?) -> CGRect {
        let region = region(hostFrame: hostFrame, visibleFrame: visibleFrame)
        switch mode {
        case .annotating:
            // The host's outer frame minus whatever hangs off the display (the title
            // bar is included, so the window-local y still aligns with AX y). Clipping
            // the catcher costs nothing: the part that was cut cannot be hovered or
            // clicked anyway.
            return region
        case .idle:
            // Anchored to the visible region's bottom-right corner at FULL size, not
            // intersected down to it: shrinking this panel would clip the pill it
            // exists to carry. The pill is drawn against the panel's BOTTOM edge, so
            // pinning that edge inside the region is what keeps it reachable — only the
            // panel's empty upper part can spill past a region shorter than 104pt.
            return CGRect(
                x: region.maxX - idleSize.width,
                y: region.minY,
                width: idleSize.width,
                height: idleSize.height
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

    /// Called after this panel has driven a host scroller, with the translation it
    /// applied to the content and that scroller's viewport — both in PANEL-LOCAL,
    /// y-DOWN coordinates, which is the space captured notes store their rects in,
    /// so the receiver applies them with no conversion of its own.
    ///
    /// A callback rather than a session reference because the panel's job is to
    /// MEASURE, not to decide: it is the only object that knows how far the content
    /// actually moved, and the only one that should not care what moves with it.
    var onHostScrolled: ((CGSize, CGRect) -> Void)?

    /// Forensics for "the pill vanished": every path AppKit can take to hide a
    /// window funnels through `orderWindow`/`setIsVisible`/`close`, so logging the
    /// call stack at each one names the culprit instead of leaving a symptom.
    /// Opt-in via `ANNOTKIT_PANEL_FORENSICS=1`; costs one env lookup otherwise.
    static let forensics = ProcessInfo.processInfo.environment["ANNOTKIT_PANEL_FORENSICS"] == "1"

    private func forensic(_ what: String) {
        guard Self.forensics else { return }
        FileHandle.standardError.write(Data("""
        [panel-forensics] \(what) visible=\(isVisible) frame=\(frame) parent=\(parent.map { "\($0.title)" } ?? "nil")
        \(Thread.callStackSymbols.prefix(14).joined(separator: "\n"))\n\n
        """.utf8))
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { forensic("order(.out)") }
        super.order(place, relativeTo: otherWin)
    }

    override func orderOut(_ sender: Any?) {
        forensic("orderOut(sender: \(sender.map { String(describing: type(of: $0)) } ?? "nil"))")
        super.orderOut(sender)
    }

    override func setIsVisible(_ flag: Bool) {
        if !flag { forensic("setIsVisible(false)") }
        super.setIsVisible(flag)
    }

    override func close() {
        forensic("close()")
        super.close()
    }

    /// Hand an unconsumed scroll down to the host window.
    ///
    /// Measured, not assumed: while annotating this panel covers the host's whole frame
    /// with `ignoresMouseEvents = false`, and an event no view handles walks THIS
    /// window's responder chain — never the window beneath it — where `NSWindow`'s
    /// do-nothing default ate it. So the host could not be scrolled AT ALL in annotate
    /// mode, which is fatal on exactly the tall scrollable screens this placement fix is
    /// about: nothing below the fold can be annotated if it cannot be brought into view.
    ///
    /// Only events that reached the WINDOW are forwarded, and that is the correct filter
    /// by construction rather than by a mode check: anything in the overlay that
    /// legitimately scrolls (a long note in the composer) consumes the wheel in the view
    /// tree, so it never arrives here.
    override func scrollWheel(with event: NSEvent) {
        guard let host = parent else { return }
        // Re-aim through screen space rather than passing `locationInWindow` along: it
        // is PANEL-local, and the panel is no longer the host's frame once placement is
        // clamped to the visible region, so handing it over unconverted would scroll
        // whatever sits at the wrong point (the wrong scroller, in a window with two).
        let hostPoint = host.convertPoint(fromScreen: convertPoint(toScreen: event.locationInWindow))
        // Hit-test from the window's ROOT view (the content view's superview, AppKit's
        // border/theme frame), not from the content view: `hitTest(_:)` takes a point
        // in the receiver's SUPERVIEW space, and the border view is flipped — so
        // handing window-base coordinates to `contentView.hitTest` mirrors the y and
        // misses everything, silently. The root view's "superview space" is defined
        // as window base, which is exactly what `convertPoint(fromScreen:)` yields.
        let root = host.contentView?.superview ?? host.contentView
        guard let target = root?.hitTest(hostPoint) ?? host.contentView else { return }

        // Scroll the host's scroller DIRECTLY by the event's deltas. The event object
        // itself must NEVER cross into the host's view tree: an earlier version did
        // `targetView.scrollWheel(with: event)`, and for a TRACKPAD stream — phase
        // `began`/`changed`/`ended` plus momentum, which is every real-world scroll —
        // NSScrollView's responsive scrolling responds to `began` by engaging an
        // event-tracking loop against `event.window`. That window is THIS PANEL, not
        // the scroll view's own, and the cross-window tracking never terminates:
        // it wedged the panel's event delivery and display, so the overlay silently
        // stopped rendering AND stopped hit-testing while its window sat there —
        // observed as "the toolbar vanishes after I scroll, then hover on and off it",
        // with a plain mouse wheel (no phases) never triggering it. Reproduced
        // against a live host and pinned by the probe's scroll phase.
        //
        // Driving the clip view by deltas keeps everything inside the HOST's own
        // machinery, no event identity involved. Momentum events still arrive here
        // carrying deltas, so inertia is preserved; only the edge rubber-band is
        // lost, because `constrainBoundsRect` clamps at the document bounds.
        var view: NSView? = target
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView else { return }

        let clip = scrollView.contentView
        // Where the content sits BEFORE the scroll, sampled from the document view
        // itself rather than computed from the deltas. The deltas are what we ASK
        // for; this is what the scroller GAVE us, which differs at the ends of the
        // document (`constrainBoundsRect` clamps) and would otherwise slide the
        // notes further than the content they are pinned to.
        let documentBefore = scrollView.documentView?.convert(NSPoint.zero, to: nil)

        // Non-precise deltas (an external mouse wheel) are in LINES; convert to
        // points the same way NSScrollView itself does.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : scrollView.verticalLineScroll
        var origin = clip.bounds.origin
        origin.x -= event.scrollingDeltaX * scale
        // A flipped clip (the AppKit default for scroll content) grows y downward, so
        // natural-scroll deltas subtract; an unflipped one is the mirror.
        origin.y += (clip.isFlipped ? -1 : 1) * event.scrollingDeltaY * scale
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)

        reportScroll(of: scrollView, documentBefore: documentBefore, host: host)
    }

    /// Hand the translation this panel just applied to the host's content, plus the
    /// viewport it applied it inside, to whoever is tracking geometry over the host
    /// (the overlay's captured notes: their pins and their recalled marks).
    ///
    /// Measured by DIFFERENCE, through the view hierarchy, rather than derived from
    /// the deltas: sampling the document view's own position before and after is
    /// correct for a flipped or unflipped document, for a scroll clamped at either
    /// end, and for any coordinate convention the host happens to use — three ways
    /// arithmetic on the deltas would have to be right, and only be discovered wrong
    /// as a mark drawn slightly off the thing it describes.
    private func reportScroll(of scrollView: NSScrollView, documentBefore: NSPoint?, host: NSWindow) {
        guard let onHostScrolled, let document = scrollView.documentView, let before = documentBefore else { return }
        let after = document.convert(NSPoint.zero, to: nil)
        // Window BASE coordinates are Cocoa (y-up) and panel-local space is y-down,
        // so the vertical component flips; x does not.
        let translation = CGSize(width: after.x - before.x, height: -(after.y - before.y))
        guard translation != .zero else { return }

        let clip = scrollView.contentView
        let viewportOnScreen = host.convertToScreen(clip.convert(clip.bounds, to: nil))
        onHostScrolled(translation, panelLocal(viewportOnScreen))
    }

    /// A screen rect in this panel's own y-DOWN, top-left-origin space — the space
    /// `OverlayView` draws in and captured notes store their rects in.
    private func panelLocal(_ screenRect: NSRect) -> CGRect {
        CGRect(x: screenRect.minX - frame.minX,
               y: frame.maxY - screenRect.maxY,
               width: screenRect.width,
               height: screenRect.height)
    }
}
#endif
