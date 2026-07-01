#if os(iOS)
import SwiftUI
import UIKit

/// A pass-through overlay window: in idle mode every touch falls through to the
/// app; in annotate mode the window captures touches so a tap selects an element
/// (and the SwiftUI toolbar/composer remain interactive).
final class PassThroughWindow: UIWindow {
    var captureTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard captureTouches else {
            // Idle: only the toolbar/composer (non-root) views are interactive;
            // taps on the bare hosting root pass through.
            return hit === rootViewController?.view ? nil : hit
        }
        return hit
    }
}

/// Hosts the annotation overlay on iOS via a ``PassThroughWindow`` at status-bar
/// level, with a tap gesture that selects the element under the touch.
@MainActor
public final class IOSOverlayController: NSObject {
    public let session: AnnotationSession
    private var window: PassThroughWindow?

    public init(session: AnnotationSession) {
        self.session = session
        super.init()
    }

    public func mount() {
        guard window == nil, let scene = Self.activeScene else { return }
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.backgroundColor = .clear

        // iOS element frames are already view-local (top-left), so `axOrigin` is
        // zero and no per-window AX offset is threaded (unlike macOS). The
        // surface size comes from the hosting geometry, so the composer clamps to
        // the live bounds and follows rotation. Bind `session` locally so the
        // escaping GeometryReader closure does not strongly capture the
        // controller (which retains the window that owns this view).
        let session = self.session
        let host = UIHostingController(rootView: GeometryReader { proxy in
            OverlayView(
                session: session,
                axOrigin: .zero,
                surfaceSize: proxy.size,
                onToggle: { [weak self] in self?.toggle() },
                onCopy: { [weak self] in self?.copy() },
                onFlush: { [weak self] in self?.flush() },
                onClose: { [weak self] in self?.unmount() }
            )
        }
        .ignoresSafeArea())
        host.view.backgroundColor = .clear
        host.view.isAccessibilityElement = false
        window.rootViewController = host

        // Selection is driven by the SwiftUI catcher in OverlayView (so taps on
        // the toolbar/composer do not select), not a window-level recognizer.
        window.isHidden = false
        self.window = window
    }

    public func unmount() {
        window?.isHidden = true
        window = nil
    }

    public func toggle() {
        session.mode == .annotating ? stop() : start()
    }

    public func start() {
        session.start()
        window?.captureTouches = true
    }

    public func stop() {
        session.stop()
        window?.captureTouches = false
    }

    private func flush() {
        try? session.flush()
    }

    private func copy() {
        try? ClipboardSink().flush(session.pending)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}
#endif
