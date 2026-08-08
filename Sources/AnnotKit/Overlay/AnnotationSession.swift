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
        // The region offset, the drawn marquee frame, and the widening ladder only
        // make sense while their selection is alive; clearing the selection
        // (capture, cancel, stop, pin editing) must never leave a stale offset,
        // frame, or ladder for the NEXT note.
        didSet {
            if selected == nil {
                selectedRegionOffset = nil
                selectedMarqueeRect = nil
                marqueeRegionOrigin = nil
                componentLadder = []
                ladderIndex = 0
            }
        }
    }
    /// Offset of a REGION selection's point from its anchor element's top-left
    /// (see ``select(atAXPoint:)``); nil for ordinary element selections.
    public private(set) var selectedRegionOffset: CGPoint?

    /// The frame the user DREW for the current selection, in ABSOLUTE AX screen
    /// coordinates; nil for click selections. Kept absolute (not element-relative)
    /// so ``widenSelection()`` re-relativizes it for free: widening rebinds the
    /// note to an enclosing element with a different origin, and a frame already
    /// relativized at selection time would then silently describe the drag against
    /// a box the note no longer names.
    public private(set) var selectedMarqueeRect: CGRect?
    /// Origin the drawn frame is measured from when the selection is a synthetic
    /// REGION — whose own `frame` IS the drawn rect, so it cannot be its own
    /// reference (it would relativize to 0,0 and locate nothing). nil for element
    /// selections, which measure from the selected element's origin.
    private var marqueeRegionOrigin: CGPoint?

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
        // Every selection starts offset-free, frame-free and ladder-free: a
        // region -> element or marquee -> click re-selection (the catcher stays
        // active behind an open composer) must not leak the previous region's
        // offset, the previous drag's drawn frame, or a stale ladder onto the next
        // note — the didSet only clears them when `selected` becomes nil, not on
        // replacement.
        selectedRegionOffset = nil
        selectedMarqueeRect = nil
        marqueeRegionOrigin = nil
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

    /// Select the annotation target for a frame the user DREW (AX top-left screen
    /// coordinates) — the marquee gesture: press-drag a rectangle AROUND what you
    /// mean instead of hunting for the one pixel that hit-tests to it.
    ///
    /// The source resolves the frame (``MarqueeTargetSource``) and hands back the
    /// same target-first, broadest-last ladder ``ComponentLadderSource`` produces,
    /// so widening and the note's `component` field work unchanged. When nothing
    /// in the frame is annotatable the drag is NOT dropped: it degrades to a
    /// REGION note anchored at the frame's centre, exactly as a no-hit click does,
    /// but carrying the drawn frame rather than a single point.
    ///
    /// CALLER CONTRACT: a press that never moved is a CLICK, and this method
    /// returns nil for it (see the degenerate guard below). The gesture recognizer
    /// owns that routing — it must send a no-movement press, and any drag below its
    /// own slop threshold, to ``select(atAXPoint:)`` instead. The session cannot
    /// make that call for you: it sees only a rect, and cannot tell a deliberate
    /// tiny drag from a jittery tap. Route it wrong and the symptom is "clicking
    /// does nothing in annotate mode", which reads as a broken feature rather than
    /// a missing threshold.
    @discardableResult
    public func select(inAXRect rect: CGRect) -> Element? {
        guard mode == .annotating else { return nil }
        // A drag on the catcher dismisses an open pin editor for the same reason a
        // tap does: the composer is about to take the stage.
        editingNoteID = nil
        // Same stale-state hazard as the point path, and then some — a marquee ->
        // click flow must not leak `selectedMarqueeRect` onto the click's note, and
        // a region-click -> marquee flow must not leak `selectedRegionOffset` onto
        // the framed one. The didSet only fires on nil, not on replacement.
        selectedRegionOffset = nil
        selectedMarqueeRect = nil
        marqueeRegionOrigin = nil
        componentLadder = []
        ladderIndex = 0

        // Normalize once: a right-to-left or bottom-to-top drag arrives with
        // negative extents.
        //
        // A zero-width or zero-height rect is a click that never moved, not a
        // marquee. Returning nil here is a DELIBERATE divergence from "the caller
        // falls back to the region path when resolution yields nothing": that
        // fallback is for a drag that framed nothing annotatable, whereas this is
        // not a drag at all. Falling through would anchor a zero-area frame to
        // whatever happens to sit near the press and plant a note the user never
        // asked for — worse than nothing, because it looks deliberate. The gesture
        // recognizer routes this case to ``select(atAXPoint:)`` instead (see the
        // caller contract above). Note this also bails BEFORE consulting the
        // source, so a degenerate rect never reaches `MarqueeTargetRule.resolve`
        // or `regionAnchor(at:)`.
        let normalized = rect.standardized
        guard normalized.width > 0, normalized.height > 0 else { return nil }

        if let marqueeSource = source as? MarqueeTargetSource {
            let ladder = marqueeSource.marqueeLadder(in: normalized)
            if let target = ladder.first {
                selected = target
                componentLadder = ladder
                ladderIndex = 0
                selectedMarqueeRect = normalized
                return selected
            }
        }

        // Region fallback, mirroring the point path but anchored at the frame's
        // CENTRE — the one point inside a drawn rect that is nearest everything it
        // covers, so the anchor a user would name themselves.
        if let anchorSource = source as? RegionAnchorSource,
           let anchorElement = anchorSource.regionAnchor(at: CGPoint(x: normalized.midX, y: normalized.midY)) {
            let offset = CGPoint(
                x: (normalized.minX - anchorElement.frame.minX).rounded(),
                y: (normalized.minY - anchorElement.frame.minY).rounded()
            )
            let anchorName = anchorElement.label.isEmpty ? anchorElement.id : anchorElement.label
            selected = Element(
                id: anchorElement.id,
                role: "AXRegion",
                type: "Region",
                label: "Region \(Int(normalized.width))x\(Int(normalized.height)) at (\(Int(offset.x)), \(Int(offset.y))) in \(anchorName)",
                value: "",
                // The DRAWN rect, not a marker at a point, so the overlay
                // highlights the frame the user actually swept.
                frame: normalized,
                isVisible: true,
                isActionable: false,
                path: anchorElement.path
            )
            selectedMarqueeRect = normalized
            // The synthetic element's frame IS the drawn rect, so it cannot be its
            // own measuring stick; record the anchor's origin instead.
            marqueeRegionOrigin = anchorElement.frame.origin
            // Deliberately NOT setting `selectedRegionOffset`: `regionOffset` stays
            // the point-click locator so every note carries exactly one, and the
            // formatter's framed/offset branches stay mutually exclusive.
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
        // ...and for the same reason it can never keep a region's measuring stick:
        // every rung is a real element, so the drawn frame is measured from the
        // element itself. Clearing is cheap insurance rather than a live fix —
        // regions get no ladder today, so this state is currently unreachable —
        // but leaving a stale anchor origin behind would silently measure the
        // persisted rect from the wrong box, and that is exactly the class of bug
        // `7993a67` was.
        marqueeRegionOrigin = nil
        // `selectedMarqueeRect` is deliberately KEPT: it is absolute, so it is
        // still the frame the user drew whichever rung is now bound, and `addNote`
        // re-relativizes it against the widened element.
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
        // Relativize the drawn frame HERE rather than at selection — the asymmetry
        // with `regionOffset` (computed at selection) is deliberate:
        // ``widenSelection()`` can rebind the note to an enclosing element AFTER
        // the frame was drawn, so the persisted rect must be measured against
        // whatever element the note FINALLY names. A region never widens, so its
        // offset's anchor is fixed the moment it is picked.
        let regionRect: CGRect? = selectedMarqueeRect.map { drawn in
            // A synthetic region's own frame IS the drawn rect, so it measures from
            // its anchor (else it would trivially be 0,0); elements measure from
            // themselves.
            let base = marqueeRegionOrigin ?? element.frame.origin
            return CGRect(x: (drawn.minX - base.x).rounded(), y: (drawn.minY - base.y).rounded(),
                          width: drawn.width.rounded(), height: drawn.height.rounded())
        }
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
            regionOffset: selectedRegionOffset,
            regionRect: regionRect
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
