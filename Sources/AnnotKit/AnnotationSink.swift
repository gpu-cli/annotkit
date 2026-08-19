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
    /// Window-local rect that was HIGHLIGHTED when the user pressed send — the
    /// same `selectionAnchorFrame ?? selected.frame` rule the live highlight, the
    /// composer and the numbered pin already follow, minus the host window's
    /// `axOrigin` AT CAPTURE. The pin is drawn at its ORIGIN, so this names exactly
    /// the pixel the old `anchor` POINT named, with a size attached.
    ///
    /// A RECT and not a point because a captured note has to be REDRAWABLE:
    /// hovering its pin recalls the note's mark (``AnnotationMarks``), and a point
    /// carries no size at all for an element note. Deriving the size instead —
    /// `anchor` + ``regionRect``'s size — is wrong the moment the user pressed
    /// Parent/Child, which re-anchors the note to the ELEMENT while the drawn size
    /// stays the swept one: a right-sized box in the wrong place. Store both rects;
    /// derive neither.
    ///
    /// UI-only, exactly as `anchor` was: omitted from ``CodingKeys`` so the on-disk
    /// JSON store, the MCP payload and the markdown stay byte-for-byte unchanged,
    /// and older files still decode (-> nil, which simply draws nothing).
    public var anchorRect: CGRect?
    /// Window-local rect the user actually SWEPT, non-nil ONLY for a marquee
    /// selection — which is what makes "was this an area or an element?" a field
    /// lookup rather than a fragile equality between two rects measured in
    /// different spaces.
    ///
    /// It also carries the navigated case for free: pressing Parent/Child moves
    /// ``anchorRect`` onto the element the note is filed against while this stays
    /// the box the user drew, so a recalled mark can show both — the binding, and
    /// the gesture it came from — which is the one case where they disagree.
    ///
    /// UI-only alongside ``anchorRect``; the PERSISTED, element-relative locator an
    /// agent reads is ``regionRect``, and that is untouched.
    public var drawnRect: CGRect?
    /// REGION note (decoration/gaps with no AX node): offset of the annotated
    /// POINT from the top-left of the anchor element named by `selector`.
    /// PERSISTED, unlike the two window-local rects — it is the locator agents need ("22pt below
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
    /// WORLD CONTEXT: an opaque snapshot of the host's state at the moment of
    /// capture — persona, route, appearance, window size, whatever the embedding
    /// host decides identifies the world the person was looking at. Registered
    /// once at install time as a provider and evaluated PER NOTE, so a value that
    /// changes mid-session (the user toggles dark mode) is recorded as it was when
    /// the note was made, not as it is when the file is read.
    ///
    /// `[String: String]` and nothing richer, deliberately: AnnotKit knows nothing
    /// about personas or routes or design systems, and the moment it does it stops
    /// being embeddable in the next host. The keys are the host's vocabulary; the
    /// agent reading the note is the one that understands them.
    ///
    /// PERSISTED (unlike the window-local rects) — reproducing the world a note was
    /// made in is the whole point, and that survives the process. nil, never an
    /// empty dictionary: an empty snapshot must serialize to nothing at all so a
    /// host that registers no provider produces byte-for-byte the file it always
    /// did, and notes captured before this field existed decode unchanged.
    public var context: [String: String]? {
        // Normalized on EVERY assignment, not just at init: the property is
        // public and settable, so `note.context = [:]` from a host would
        // otherwise put a `"context": {}` into the store and break the
        // "no provider changes no byte" guarantee from the far side.
        // (Re-assigning inside `didSet` does not re-enter it.)
        didSet { if context?.isEmpty == true { context = nil } }
    }

    /// Explicit keys that OMIT ``anchorRect`` and ``drawnRect``: `JSONFileSink`
    /// and the MCP `FileNotesStore` encode/decode `[AnnotationNote]` directly, so a
    /// naked stored property would leak the overlay's window-local geometry into
    /// the serialized record. Both decode to nil when absent, so the store and old
    /// files round-trip unchanged — and the agent-facing payload is byte-for-byte
    /// what it was before marks existed.
    private enum CodingKeys: String, CodingKey {
        case id, route, selector, elementPath, selectedText, comment, screenshot, timestamp
        case component, elementRole, elementText, unseeded
        case regionOffset, regionRect, context
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
        anchorRect: CGRect? = nil,
        drawnRect: CGRect? = nil,
        regionOffset: CGPoint? = nil,
        regionRect: CGRect? = nil,
        context: [String: String]? = nil
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
        self.anchorRect = anchorRect
        self.drawnRect = drawnRect
        self.regionOffset = regionOffset
        self.regionRect = regionRect
        // Normalize empty -> nil at the boundary rather than trusting every caller
        // to: the "no provider registered changes no byte of output" guarantee is
        // only worth as much as the one place that can enforce it.
        self.context = (context?.isEmpty == true) ? nil : context
    }
}
