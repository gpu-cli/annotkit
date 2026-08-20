import Foundation
#if os(macOS)
import AppKit
#endif

/// The public entry point. A host adds the toolbar in a few lines, dev-gated:
///
///     import AnnotKit
///     #if DEBUG
///     Annotation.install()            // macOS, or imperative iOS
///     #endif
///
/// SwiftUI iOS hosts can use `.installAnnotation()` instead. On macOS this mounts
/// the overlay with the AX element source; on iOS, the UIKit view-tree source.
/// Both default to the `ANNOTKIT_NOTES.md` file sink.
@MainActor
public enum Annotation {
    /// True once the overlay has actually mounted.
    public private(set) static var isInstalled = false

    /// The launch environment this process was given, parsed once. Everything
    /// env-configurable — the gate, the sink destinations, the fallback route, the
    /// world context — is read from here, so a host that launches many isolated
    /// instances of one binary configures each of them without touching a call
    /// site. See ``AnnotationEnvironment`` for the variables.
    ///
    /// Read once and cached: an env var cannot change under a running process, and
    /// re-reading per capture would put a `ProcessInfo` walk in the capture path.
    public static let environment = AnnotationEnvironment()

    /// Dev-only gate. In DEBUG, on unless `ANNOTKIT_DISABLE` is set; in release,
    /// off unless `ANNOTKIT_ENABLE` is set. Mirrors VirgilHUD's `InspectMode`
    /// env pattern so the toolbar never appears in a normal shipping build.
    public static var isEnabled: Bool {
        #if DEBUG
        return environment.isEnabled(byDefault: true)
        #else
        return environment.isEnabled(byDefault: false)
        #endif
    }

    /// The destinations ``install(source:sink:context:route:)`` writes to when the
    /// host passes no sink of its own: the markdown snapshot always, plus the JSON
    /// store and the JSONL event stream when the environment named them.
    ///
    /// Public and pure in its argument so a host can inspect (or reuse) exactly
    /// what a given launch would write, and so the wiring is testable without
    /// mounting a window.
    public static func sink(for environment: AnnotationEnvironment) -> AnnotationSink {
        var sinks: [AnnotationSink] = [NotesFileSink(path: environment.notesPath)]
        if let store = environment.storePath {
            sinks.append(JSONFileSink(path: store))
        }
        if let events = environment.eventsPath {
            // The stream carries the snapshot path so a reader woken by a line
            // knows which file to open — the whole point when several isolated
            // instances share one log.
            sinks.append(JSONLEventSink(path: events, snapshot: environment.notesPath))
        }
        return sinks.count == 1 ? sinks[0] : MultiSink(sinks)
    }

    #if os(macOS)
    private static var controller: OverlayController?
    #elseif os(iOS)
    private static var controller: IOSOverlayController?
    #endif

    #if os(macOS) || os(iOS)
    /// The mounted capture session, or nil before ``install(source:sink:context:route:)``.
    ///
    /// Exposed so a host can drive the overlay from its OWN chrome — a menu item,
    /// a hotkey, a scripted walkthrough — instead of only through the floating
    /// toolbar, and so an embedding host can be exercised end to end through the
    /// same session `install()` mounted rather than through a second one built to
    /// resemble it. Read-only: the session is created with the environment's sinks
    /// and the host's context provider already wired in, and handing out a way to
    /// replace it would make "what does this instance write?" a question with two
    /// answers.
    public static var current: AnnotationSession? { controller?.session }
    #endif

    /// Mount the toolbar with the platform-default source and the destinations the
    /// environment asks for (`ANNOTKIT_NOTES.md` and nothing else, by default).
    ///
    /// - Parameters:
    ///   - context: the host's WORLD-CONTEXT provider, called once per captured
    ///     note. Whatever identifies the world the person is looking at — persona,
    ///     appearance, window size, build — so an agent reading the note can put
    ///     that world back rather than guess at it. Merged over
    ///     `ANNOTKIT_CONTEXT*`, which the provider wins (see
    ///     ``AnnotationEnvironment/merging(_:)``).
    ///   - route: the note's `pathname` analogue, likewise per note. Falls back to
    ///     `ANNOTKIT_ROUTE`.
    public static func install(
        source: ElementSource? = nil,
        sink: AnnotationSink? = nil,
        context: (() -> [String: String])? = nil,
        route: (() -> String?)? = nil
    ) {
        guard isEnabled else { return }
        #if os(macOS)
        guard controller == nil else { return }
        let session = makeSession(
            source: source ?? MacElementSource(), sink: sink, context: context, route: route
        )
        let controller = OverlayController(session: session)
        controller.mount()
        Self.controller = controller
        isInstalled = true
        #elseif os(iOS)
        guard controller == nil else { return }
        let session = makeSession(
            source: source ?? IOSElementSource(), sink: sink, context: context, route: route
        )
        let controller = IOSOverlayController(session: session)
        controller.mount()
        Self.controller = controller
        isInstalled = true
        #else
        notImplemented("install")
        #endif
    }

    #if os(macOS) || os(iOS)
    /// The one place install's arguments meet the environment, so the two overloads
    /// cannot drift into configuring their sessions differently.
    private static func makeSession(
        source: ElementSource,
        sink: AnnotationSink?,
        context: (() -> [String: String])?,
        route: (() -> String?)?
    ) -> AnnotationSession {
        let environment = Self.environment
        return AnnotationSession(
            source: source,
            sink: sink ?? Self.sink(for: environment),
            route: { route?() ?? environment.route },
            context: { environment.merging(context?() ?? [:]) }
        )
    }
    #endif

    #if os(macOS)
    /// Mount the overlay on a SPECIFIC host window instead of the auto-picked one.
    /// Use when the app already knows the exact window to annotate: the auto-picker
    /// (`NSApp.mainWindow ?? keyWindow ?? first visible non-panel`) can otherwise
    /// resolve to a floating `NSPanel` when several windows are visible.
    public static func install(
        on host: NSWindow,
        source: ElementSource? = nil,
        sink: AnnotationSink? = nil,
        context: (() -> [String: String])? = nil,
        route: (() -> String?)? = nil
    ) {
        guard isEnabled else { return }
        guard controller == nil else { return }
        let session = makeSession(
            source: source ?? MacElementSource(), sink: sink, context: context, route: route
        )
        let controller = OverlayController(session: session)
        controller.mount(on: host)
        Self.controller = controller
        isInstalled = true
    }
    #endif

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
        if let pending = current?.pending {
            try? ClipboardSink(format: format).flush(pending)
        }
        #else
        notImplemented("copy")
        #endif
    }

    /// Discard pending notes.
    public static func clear() {
        #if os(macOS) || os(iOS)
        current?.clear()
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
