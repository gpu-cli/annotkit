import Combine
import CoreGraphics
import Foundation

/// The platform-independent heart of the overlay: tracks annotate mode, the
/// hovered and selected elements, and the retained list of captured notes, and
/// turns a selected element plus a comment into an ``AnnotationNote`` that it
/// appends to that list. Notes PERSIST until ``clear()`` — capturing, copying,
/// and exporting never drop them — so the same set can be copied and exported
/// repeatedly. The macOS/iOS overlay hosts drive this; it owns no UI, so it is
/// unit-testable without a window.
@MainActor
public final class AnnotationSession: ObservableObject {
    public enum Mode: Sendable {
        case idle
        case annotating
    }

    @Published public private(set) var mode: Mode = .idle
    /// The retained set of captured notes. Grows via ``addNote(comment:selectedText:screenshot:)``
    /// and is emptied ONLY by ``clear()`` — ``export()`` and copy read it without
    /// mutating it, so the same set survives repeated copy/export.
    @Published public private(set) var pending: [AnnotationNote] = []
    @Published public private(set) var hovered: Element?
    @Published public private(set) var selected: Element? {
        // The region offset and the widening ladder only make sense while their
        // selection is alive; clearing the selection (capture, cancel, stop, pin
        // editing) must never leave a stale offset or ladder for the NEXT note.
        didSet {
            if selected == nil {
                selectedRegionOffset = nil
                componentLadder = []
                ladderIndex = 0
            }
        }
    }
    /// Offset of a REGION selection's point from its anchor element's top-left
    /// (see ``select(atAXPoint:)``); nil for ordinary element selections.
    public private(set) var selectedRegionOffset: CGPoint?

    /// The component-widening ladder for the current selection (target first, each
    /// enclosing identified component after), and the index of the currently
    /// selected rung. Populated on ``select(atAXPoint:)`` when the source offers a
    /// ``ComponentLadderSource``; empty for region selections and unsupported
    /// sources, which disables widening.
    private var componentLadder: [Element] = []
    private var ladderIndex: Int = 0

    /// Whether ``widenSelection()`` can step the current selection up to an
    /// enclosing component. Drives the composer's widen affordance.
    public var canWidenSelection: Bool { ladderIndex + 1 < componentLadder.count }
    /// The id of the retained note whose in-overlay edit card is open, or nil when
    /// no editor is showing. UI-only: drives which pin's edit card the overlay
    /// renders. Mutually exclusive with ``selected`` (the composer) — opening one
    /// closes the other — so exactly one card is ever on screen.
    @Published public private(set) var editingNoteID: String?

    private let source: ElementSource
    private let sink: AnnotationSink
    private let route: () -> String?
    private let timestamp: () -> String
    private let makeID: () -> String

    /// Hover throttle. The hit-test is a cheap cross-process point query, but
    /// `onContinuousHover` fires very frequently, so cap it at ~60fps to keep the
    /// main thread responsive. Lives here so both platform hosts benefit.
    private var lastHover = Date.distantPast
    private let hoverInterval: TimeInterval = 1.0 / 60.0

    public init(
        source: ElementSource,
        sink: AnnotationSink,
        route: @escaping () -> String? = { nil },
        timestamp: @escaping () -> String = { ISO8601DateFormatter().string(from: Date()) },
        makeID: @escaping () -> String = { String(UUID().uuidString.prefix(6)).lowercased() }
    ) {
        self.source = source
        self.sink = sink
        self.route = route
        self.timestamp = timestamp
        self.makeID = makeID
    }

    public func start() { mode = .annotating }

    public func stop() {
        mode = .idle
        hovered = nil
        // Dismiss any open composer so it does not linger (and get clipped by a
        // resized idle overlay) after leaving annotate mode.
        selected = nil
        // Leaving annotate mode hides the pins, so any open pin editor must go too.
        editingNoteID = nil
    }

    /// Update the hover highlight for a screen point (AX top-left coordinates).
    /// Throttled to ~60fps so rapid hover events do not flood the point query.
    public func hover(atAXPoint point: CGPoint) {
        guard mode == .annotating else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHover) >= hoverInterval else { return }
        lastHover = now
        hovered = source.hitTest(point)
    }

    /// Drop the hover highlight — the cursor left the annotatable surface, so
    /// nothing is hovered. `selected` (an open composer) is deliberately kept.
    public func clearHover() {
        hovered = nil
    }

    /// Select the element under a screen point (AX top-left coordinates).
    ///
    /// When nothing resolves (decoration, dividers, gaps beyond any container's
    /// frame) the click is NOT dropped: if the source can name a nearby anchor
    /// (``RegionAnchorSource``), a synthetic REGION selection is made — a small
    /// marker at the point, annotated relative to the nearest meaningful
    /// element ("22pt below the top-left of #Dashboard.Today").
    @discardableResult
    public func select(atAXPoint point: CGPoint) -> Element? {
        guard mode == .annotating else { return nil }
        // Any catcher tap dismisses an open pin editor: a tap on empty space is a
        // click-away close, and a tap on an element hands the stage to the composer.
        editingNoteID = nil
        // Every selection starts offset-free and ladder-free: a region -> element
        // re-selection (the catcher stays active behind an open composer) must not
        // leak the previous region's offset or ladder onto an ELEMENT note — the
        // didSet only clears them when `selected` becomes nil, not on replacement.
        selectedRegionOffset = nil
        componentLadder = []
        ladderIndex = 0
        selected = source.hitTest(point)
        // Capture the widening ladder for a real element selection (its first rung
        // equals the hit-test target). Region selections get no ladder.
        if selected != nil, let ladderSource = source as? ComponentLadderSource {
            componentLadder = ladderSource.componentLadder(at: point)
            ladderIndex = 0
        }
        if selected == nil,
           let anchorSource = source as? RegionAnchorSource,
           let anchorElement = anchorSource.regionAnchor(at: point) {
            let offset = CGPoint(
                x: (point.x - anchorElement.frame.minX).rounded(),
                y: (point.y - anchorElement.frame.minY).rounded()
            )
            let anchorName = anchorElement.label.isEmpty ? anchorElement.id : anchorElement.label
            selected = Element(
                id: anchorElement.id,
                role: "AXRegion",
                type: "Region",
                label: "Region (\(Int(offset.x)), \(Int(offset.y))) in \(anchorName)",
                value: "",
                frame: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16),
                isVisible: true,
                isActionable: false,
                path: anchorElement.path
            )
            selectedRegionOffset = offset
        }
        return selected
    }

    /// Step the current selection UP to the next enclosing identified component
    /// (a coarser-grained note: the card instead of the label inside it). No-op
    /// when the selection is already at the broadest rung, is a region, or the
    /// source offers no ``ComponentLadderSource``. The composer re-anchors to the
    /// widened element's frame for free (it renders `selected`).
    @discardableResult
    public func widenSelection() -> Element? {
        guard ladderIndex + 1 < componentLadder.count else { return nil }
        ladderIndex += 1
        // Widening always lands on a real element, so it is never a region note.
        selectedRegionOffset = nil
        // A non-nil assignment does not trip the didSet clear, so the ladder and
        // index survive for a further widen.
        selected = componentLadder[ladderIndex]
        return selected
    }

    /// Capture a screenshot of the currently selected element, if any.
    public func screenshotSelected() async -> CapturedImage? {
        guard let selected else { return nil }
        return try? await source.screenshot(of: selected)
    }

    /// Turn the selected element plus a comment into a pending note.
    @discardableResult
    public func addNote(
        comment: String,
        selectedText: String? = nil,
        screenshot: CapturedImage? = nil,
        anchor: CGPoint? = nil
    ) -> AnnotationNote? {
        guard let element = selected else { return nil }
        // Code-location hints. `unseeded` is true when the target carries no
        // identifier of its own (the selector anchored to an ancestor or went
        // positional) — a miss worth turning into a seeding task rather than a
        // silent misattribution. `component` is the seeded component to grep: the
        // target's own id when seeded, else the tightest enclosing seeded
        // component from the GEOMETRIC widening ladder — which reaches a SwiftUI
        // `.axCardSurface` card whose identifier sits on a background sibling, not
        // an ancestor, so plain ancestry (the fallback for region/ladderless
        // sources) would miss it.
        let ownIdentifier = element.path.last?.identifier ?? ""
        let component = !ownIdentifier.isEmpty
            ? ownIdentifier
            : (componentLadder.dropFirst().first?.id
                ?? element.path.last(where: { !($0.identifier ?? "").isEmpty })?.identifier)
        let note = AnnotationNote(
            id: makeID(),
            route: route(),
            selector: source.selector(for: element),
            elementPath: element.path.map(\.pathDescription).joined(separator: " > "),
            component: component,
            elementRole: element.role.isEmpty ? nil : element.role,
            elementText: element.value.isEmpty ? nil : element.value,
            unseeded: ownIdentifier.isEmpty,
            selectedText: selectedText,
            comment: comment,
            screenshot: screenshot,
            timestamp: timestamp(),
            anchor: anchor,
            regionOffset: selectedRegionOffset
        )
        pending.append(note)
        selected = nil
        return note
    }

    /// Edit a retained note's comment in place (the numbered-pin edit popover).
    /// No-op if the id is no longer present.
    public func updateNote(id: String, comment: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].comment = comment
    }

    /// Remove a retained note (the numbered-pin delete action). The pin numbers
    /// and the count badge are DERIVED from `pending`'s order and size, so
    /// dropping a note reflows both for free — no explicit renumbering.
    public func deleteNote(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Write the full retained set to the sink, WITHOUT clearing it. Notes
    /// persist until ``clear()``, so the same set can be exported repeatedly (and
    /// also copied). The file sink overwrites its file with the current set, so
    /// re-exporting after more notes were captured replaces it with the full set —
    /// idempotent, no duplicates.
    public func export() throws {
        try sink.flush(pending)
    }

    public func clear() {
        pending.removeAll()
        selected = nil
        // Clearing all notes removes every pin, so close any open editor.
        editingNoteID = nil
    }

    /// Open the in-overlay edit card for a retained note (a pin tap/hover). Nils
    /// ``selected`` so the composer and the pin editor are mutually exclusive —
    /// exactly one card shows at a time.
    public func beginEditing(id: String) {
        editingNoteID = id
        selected = nil
    }

    /// Close the pin edit card (Save, Delete, Escape, or click-away).
    public func endEditing() {
        editingNoteID = nil
    }

    /// Drop the current selection without capturing a note (composer cancel).
    public func cancelSelection() {
        selected = nil
    }

    /// A short, human label for the selected element (for the composer header).
    public var selectionLabel: String? {
        guard let selected else { return nil }
        if !selected.label.isEmpty { return selected.label }
        return selected.id
    }
}
