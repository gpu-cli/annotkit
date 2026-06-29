import Foundation

/// Output format for sinks that serialize notes as a blob (clipboard, logs).
public enum OutputFormat: Sendable, Hashable {
    case markdown
    case json
}

/// Where captured notes go. Implementations land in F4:
///
/// - `NotesFileSink` writes the `AGENTATION_NOTES.md` format that the
///   `process-agentation-notes` skill already consumes (with the native
///   source-location adaptation), and
/// - `ClipboardSink` copies markdown or JSON for a zero-config paste.
/// - the optional `MCPBridgeSink` (F6) exposes pending notes to an agent.
///
/// `Sendable` so a sink can be handed to the capture session safely.
public protocol AnnotationSink: Sendable {
    /// Persist or transmit a batch of notes. Throwing surfaces IO or encoding
    /// failures to the caller (the overlay shows an error toast).
    func flush(_ notes: [AnnotationNote]) throws
}

/// One captured annotation. This is the record the agent ultimately reads; the
/// field names map onto the `AGENTATION_NOTES.md` format:
/// `id`, `pathname` (here ``route``), `element` (here ``selector``),
/// `Element Path`, `Selected Text`, and the comment.
public struct AnnotationNote: Sendable, Hashable, Identifiable {
    public let id: String
    /// The `pathname` analogue: a host-supplied route or screen name, with an
    /// inferred fallback (key-window title or identifier). See DECISIONS.md.
    public var route: String?
    /// The `element` field: a round-tripping ``Selector`` string.
    public var selector: String
    /// The human-readable Element Path (ancestor chain).
    public var elementPath: String
    public var selectedText: String?
    public var comment: String
    public var screenshot: CapturedImage?
    /// ISO-8601 timestamp, injected by the caller (kept out of pure logic so the
    /// model stays deterministic and testable).
    public var timestamp: String

    public init(
        id: String,
        route: String? = nil,
        selector: String,
        elementPath: String,
        selectedText: String? = nil,
        comment: String,
        screenshot: CapturedImage? = nil,
        timestamp: String
    ) {
        self.id = id
        self.route = route
        self.selector = selector
        self.elementPath = elementPath
        self.selectedText = selectedText
        self.comment = comment
        self.screenshot = screenshot
        self.timestamp = timestamp
    }
}
