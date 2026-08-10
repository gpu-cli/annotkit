import CoreGraphics
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
public struct AnnotationNote: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    /// The `pathname` analogue: a host-supplied route or screen name, with an
    /// inferred fallback (key-window title or identifier). See DECISIONS.md.
    public var route: String?
    /// The `element` field: a round-tripping ``Selector`` string.
    public var selector: String
    /// The human-readable Element Path (ancestor chain).
    public var elementPath: String
    /// The seeded component the note is scoped to: the deepest
    /// `accessibilityIdentifier` in the target's ancestry (the target's own id
    /// when it is seeded, else its nearest seeded ancestor). This is the string an
    /// agent greps to find the component's Swift view; nil when nothing in the
    /// ancestry is seeded. Optional and additive — old files decode with nil.
    public var component: String?
    /// The bound element's accessibility role (`AXButton`, `AXStaticText`, …), so
    /// an agent knows what kind of view to look for. Optional/additive.
    public var elementRole: String?
    /// The bound element's displayed text/value, if any — a direct grep target
    /// (e.g. the button title or the `Text` string). Optional/additive.
    public var elementText: String?
    /// True when the bound element has NO `accessibilityIdentifier` of its own, so
    /// the selector had to anchor to an ancestor (``component``) or go positional.
    /// It marks a miss the user can turn into a seeding task rather than a silent
    /// misattribution. nil on notes captured before this field existed.
    public var unseeded: Bool?
    public var selectedText: String?
    public var comment: String
    public var screenshot: CapturedImage?
    /// ISO-8601 timestamp, injected by the caller (kept out of pure logic so the
    /// model stays deterministic and testable).
    public var timestamp: String
    /// Window-local top-left where the numbered pin is drawn in annotate mode
    /// (the element's AX frame origin minus the host window's `axOrigin` AT
    /// CAPTURE). UI-only: intentionally NOT persisted — it is omitted from
    /// ``CodingKeys`` so the on-disk JSON store and the MCP payload stay
    /// byte-for-byte unchanged, and older files still decode (`anchor` -> nil).
    public var anchor: CGPoint?
    /// REGION note (decoration/gaps with no AX node): offset of the annotated
    /// POINT from the top-left of the anchor element named by `selector`.
    /// PERSISTED, unlike `anchor` — it is the locator agents need ("22pt below
    /// the top-left of #Dashboard.Today"). Optional, so element notes serialize
    /// unchanged and old files decode (nil).
    public var regionOffset: CGPoint?
    /// MARQUEE note: the frame the user DREW, with its origin relative to the
    /// top-left of the element named by `selector` (its size is absolute). Like
    /// `regionOffset` it is PERSISTED — it is the locator agents need when the
    /// user framed a spot rather than clicked one ("a 320x48 band 40pt down inside
    /// #Settings.Models"). Mutually exclusive with `regionOffset` by construction:
    /// a note carries the point locator or the frame locator, never both. Optional,
    /// so click notes serialize unchanged and old files decode (nil).
    public var regionRect: CGRect?

    /// Explicit keys that OMIT `anchor`: `JSONFileSink` and the MCP
    /// `FileNotesStore` encode/decode `[AnnotationNote]` directly, so a naked
    /// stored property would leak the pin position into the serialized record.
    /// `anchor` decodes to nil when absent, so the store and old files round-trip
    /// unchanged.
    private enum CodingKeys: String, CodingKey {
        case id, route, selector, elementPath, selectedText, comment, screenshot, timestamp
        case component, elementRole, elementText, unseeded
        case regionOffset, regionRect
    }

    public init(
        id: String,
        route: String? = nil,
        selector: String,
        elementPath: String,
        component: String? = nil,
        elementRole: String? = nil,
        elementText: String? = nil,
        unseeded: Bool? = nil,
        selectedText: String? = nil,
        comment: String,
        screenshot: CapturedImage? = nil,
        timestamp: String,
        anchor: CGPoint? = nil,
        regionOffset: CGPoint? = nil,
        regionRect: CGRect? = nil
    ) {
        self.id = id
        self.route = route
        self.selector = selector
        self.elementPath = elementPath
        self.component = component
        self.elementRole = elementRole
        self.elementText = elementText
        self.unseeded = unseeded
        self.selectedText = selectedText
        self.comment = comment
        self.screenshot = screenshot
        self.timestamp = timestamp
        self.anchor = anchor
        self.regionOffset = regionOffset
        self.regionRect = regionRect
    }
}
