import Foundation

/// The public entry point. A host adds the toolbar in a few lines, dev-gated:
///
///     import AnnotKit
///     #if DEBUG
///     Annotation.install()
///     #endif
///
/// The surface is locked in F0; the overlay, capture session, and sinks are
/// wired in F2-F4. Calls are no-ops (and log once) until then, so adopting the
/// API early never crashes or paints over a host that has not been built out.
@MainActor
public enum Annotation {
    /// True once ``install(source:sink:)`` has run.
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

    /// Mount the toolbar. `source`/`sink` default to the platform's standard
    /// choices once those land (macOS AX source, notes-file sink).
    public static func install(source: ElementSource? = nil, sink: AnnotationSink? = nil) {
        guard isEnabled else { return }
        // `isInstalled` flips to true only once the overlay host actually
        // mounts (F3); until then this stays false so the flag never claims a
        // mounted toolbar that does not exist.
        notImplemented("install")
    }

    /// Enter annotate mode (toolbar active, clicks captured).
    public static func start() { notImplemented("start") }

    /// Leave annotate mode (toolbar idle, clicks pass through).
    public static func stop() { notImplemented("stop") }

    /// Copy pending notes to the pasteboard in `format`.
    public static func copy(format: OutputFormat = .markdown) { notImplemented("copy") }

    /// Discard pending notes.
    public static func clear() { notImplemented("clear") }

    private static var warned: Set<String> = []
    private static func notImplemented(_ symbol: String) {
        guard !warned.contains(symbol) else { return }
        warned.insert(symbol)
        FileHandle.standardError.write(Data(
            "[AnnotKit] \(symbol)() is API-only until the F2-F4 phases land.\n".utf8
        ))
    }
}
