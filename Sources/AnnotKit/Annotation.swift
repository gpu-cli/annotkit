import Foundation

/// The public entry point. A host adds the toolbar in a few lines, dev-gated:
///
///     import AnnotKit
///     #if DEBUG
///     Annotation.install()            // macOS, or imperative iOS
///     #endif
///
/// SwiftUI iOS hosts can use `.installAnnotation()` instead. On macOS this mounts
/// the overlay with the AX element source; on iOS, the UIKit view-tree source.
/// Both default to the `AGENTATION_NOTES.md` file sink.
@MainActor
public enum Annotation {
    /// True once the overlay has actually mounted.
    public private(set) static var isInstalled = false

    /// Dev-only gate. In DEBUG, on unless `ANNOTKIT_DISABLE` is set; in release,
    /// off unless `ANNOTKIT_ENABLE` is set. Mirrors VirgilHUD's `InspectMode`
    /// env pattern so the toolbar never appears in a normal shipping build.
    public static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        return env["ANNOTKIT_DISABLE"] == nil
        #else
        return env["ANNOTKIT_ENABLE"] != nil
        #endif
    }

    #if os(macOS)
    private static var controller: OverlayController?
    #elseif os(iOS)
    private static var controller: IOSOverlayController?
    #endif

    #if os(macOS) || os(iOS)
    private static var session: AnnotationSession? { controller?.session }
    #endif

    /// Mount the toolbar with the platform-default source and the
    /// `AGENTATION_NOTES.md` file sink.
    public static func install(source: ElementSource? = nil, sink: AnnotationSink? = nil) {
        guard isEnabled else { return }
        #if os(macOS)
        guard controller == nil else { return }
        let session = AnnotationSession(source: source ?? MacElementSource(), sink: sink ?? NotesFileSink())
        let controller = OverlayController(session: session)
        controller.mount()
        Self.controller = controller
        isInstalled = true
        #elseif os(iOS)
        guard controller == nil else { return }
        let session = AnnotationSession(source: source ?? IOSElementSource(), sink: sink ?? NotesFileSink())
        let controller = IOSOverlayController(session: session)
        controller.mount()
        Self.controller = controller
        isInstalled = true
        #else
        notImplemented("install")
        #endif
    }

    /// Enter annotate mode (toolbar active, clicks/taps captured).
    public static func start() {
        #if os(macOS) || os(iOS)
        controller?.start()
        #else
        notImplemented("start")
        #endif
    }

    /// Leave annotate mode (toolbar idle, input passes through).
    public static func stop() {
        #if os(macOS) || os(iOS)
        controller?.stop()
        #else
        notImplemented("stop")
        #endif
    }

    /// Copy pending notes to the pasteboard in `format` (without clearing them).
    public static func copy(format: OutputFormat = .markdown) {
        #if os(macOS) || os(iOS)
        if let pending = session?.pending {
            try? ClipboardSink(format: format).flush(pending)
        }
        #else
        notImplemented("copy")
        #endif
    }

    /// Discard pending notes.
    public static func clear() {
        #if os(macOS) || os(iOS)
        session?.clear()
        #else
        notImplemented("clear")
        #endif
    }

    private static var warned: Set<String> = []
    private static func notImplemented(_ symbol: String) {
        guard !warned.contains(symbol) else { return }
        warned.insert(symbol)
        FileHandle.standardError.write(Data(
            "[AnnotKit] \(symbol)() is not yet implemented on this platform.\n".utf8
        ))
    }
}
