import SwiftUI

/// The overlay's SwiftUI content, shared by the macOS and iOS hosts.
///
/// Interaction is driven entirely through SwiftUI hit-testing, which fixes the
/// two ways a global click monitor went wrong: a full-screen catcher (active
/// only in annotate mode, behind the chrome) receives hover, taps, and frame
/// drags over the app (see ``SelectionGesture`` for the point-vs-frame routing,
/// which follows the toolbar's chosen tool rather than guessing from travel),
/// while the toolbar and composer sit on top and consume their own clicks,
/// so tapping "Add note" can never re-select the element under the button. The
/// whole overlay is `accessibilityHidden` so the AX point query sees through it
/// to the app beneath.
///
/// Coordinate model: this surface is glued to one host window, whose AX top-left
/// origin the host passes as `axOrigin`. Click, highlight, and composer share one
/// transform — the catcher ADDS `axOrigin` to feed the AX point query, and the
/// highlight/composer SUBTRACT it to place overlays in window-local space — so
/// all three agree by construction on any display. On the primary display at the
/// global origin `axOrigin == .zero`, so the previously-working case is
/// unchanged. iOS passes `axOrigin = .zero` (its view-tree frames are already
/// view-local) and `surfaceSize` from the hosting geometry.
struct OverlayView: View {
    @ObservedObject var session: AnnotationSession
    /// AX top-left origin of this surface's host window (see ``ScreenSpace/windowAXOrigin(cocoaFrame:primaryHeight:)``).
    let axOrigin: CGPoint
    /// Window-local size of this surface, used to clamp the composer on-screen.
    let surfaceSize: CGSize
    let onToggle: () -> Void
    /// Copy the retained notes to the pasteboard as markdown (host wires
    /// ``ClipboardSink``). Non-clearing.
    let onCopy: () -> Void
    /// Export the retained notes to `AGENTATION_NOTES.md` (host wires
    /// ``NotesFileSink``). Non-clearing and idempotent.
    let onExport: () -> Void
    /// Make the host panel key so the composer's text field accepts keystrokes.
    /// macOS passes `panel.makeKey()` (the child panel is non-activating, so a
    /// programmatic focus needs the window made key first); iOS uses the default
    /// no-op because `@FocusState` alone raises the keyboard. See Feature 3.
    /// A `var` (not `let`) so it stays a defaulted memberwise-init parameter that
    /// the iOS host can omit.
    var onFocusRequest: () -> Void = {}

    @State private var comment: String = ""
    /// Draft text for the pin edit card, seeded from the note's comment when
    /// editing begins (see the `editingNoteID` seeding hook on the ZStack).
    @State private var editDraft: String = ""
    /// The in-progress marquee band, WINDOW-LOCAL (gesture coordinates), non-nil
    /// only in FRAME mode, between "this press has travelled far enough to be a
    /// real drag" and the release that resolves it. It is never the resolved
    /// selection — that comes back as `session.selected` and is drawn by the
    /// highlight branch.
    @State private var marqueeRect: CGRect?
    /// `session.frameDragGeneration` as it stood when the current drag began, and
    /// re-synced to the session's at every release (and whenever a fresh catcher
    /// appears). The difference between this and the live value IS the cancellation:
    /// AppKit delivers the gesture's `onEnded` whether or not Escape was pressed, and
    /// nothing in SwiftUI can suppress it, so the release has to ask.
    ///
    /// Re-syncing at the END of every press is what makes the NEXT press start
    /// uncancelled — without it, one cancelled drag would leave the two values apart
    /// forever and kill frame mode for the rest of the session.
    @State private var frameDragGeneration = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            catcher

            highlightLayer

            // Numbered comment pins (annotate-mode-only chrome). Layered ABOVE
            // the catcher and BELOW the composer/toolbar, so each pin consumes its
            // own hover/click and can never fall through to re-select the element.
            if session.mode == .annotating {
                AnnotationPins(session: session)
            }

            // Exactly one card shows at a time. The composer (a new note on the
            // selected element) wins any theoretical tie; the pin edit card shows
            // only when nothing is selected but a pin is being edited. Session-level
            // mutual exclusion (`beginEditing` nils `selected`; `select` nils
            // `editingNoteID`) keeps these two states from ever both being set.
            if session.selected != nil {
                composer
            } else if let (note, anchor) = editingCardData {
                editCard(note: note, anchor: anchor)
            }

        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        // Seed the edit draft when a pin editor opens (or switches pin→pin, where
        // the shared card is not re-inserted so `.onAppear` won't refire).
        .onChange(of: session.editingNoteID) { _, id in
            if let id, let note = session.pending.first(where: { $0.id == id }) {
                editDraft = note.comment
            }
        }
        // The draft belongs to the composer, so it dies WITH the composer — for any
        // reason it closes, not just the Cancel button. The button used to clear it
        // itself, which made "no selection implies no draft" a property of one code
        // path rather than an invariant: dismissing from anywhere else (Escape, which
        // now goes through the key monitor, or `stop()`) left `comment` populated and
        // it reappeared, pre-filled, over the NEXT element the user selected.
        //
        // Deliberately not `if session.selected == nil` inside the capture path: a
        // capture also nils `selected`, and `addNote()` clearing the field itself is
        // redundant with this rather than in conflict with it.
        .onChange(of: session.selected) { _, element in
            if element == nil { comment = "" }
        }
        // Drop the band the instant a drag is cancelled, rather than waiting for the
        // release: the whole point of Escape here is that the rectangle stops being
        // dragged around under the cursor.
        .onChange(of: session.frameDragGeneration) { _, _ in
            marqueeRect = nil
        }
    }

    /// What is drawn ON the app, between the catcher and the chrome. Four states,
    /// and keeping them in ONE mutually-exclusive ladder is the point: each earlier
    /// case is a stronger claim about what the next press/release binds to, and any
    /// two of them on screen at once would show the user two different answers.
    ///
    /// 1. **Drawing** — the dashed band, frame-mode-only, window-local.
    /// 2. **Committed frame** — the rect the user just swept, drawn SOLID (so
    ///    "still drawing" and "done" are distinguishable at a glance) and with NO
    ///    name tag: the note's bind target is named in the composer header instead,
    ///    because a tag here would put a second, differently-shaped claim next to
    ///    the rectangle the user actually drew. See ``composerHeader``.
    /// 3. **Navigated** — the user pressed Parent/Child, so they have explicitly
    ///    asked WHICH element: the element is highlighted and named, and the drawn
    ///    frame stays beneath it, DIMMED, because it is still what the note records
    ///    (`regionRect`) even though it no longer decides the binding.
    /// 4. **Point selection / hover** — the original element highlight.
    @ViewBuilder
    private var highlightLayer: some View {
        // The band REPLACES everything else while a frame is being drawn. Showing a
        // solid "this is what you get" highlight under a rectangle that has not
        // resolved to anything yet would promise a binding the release may not make.
        if let marqueeRect {
            // COORDINATES: `marqueeRect` is already window-local, so it is offset
            // DIRECTLY — no `axOrigin` subtraction, unlike every other case here,
            // which arrives in AX screen space. Subtracting here "for symmetry"
            // would slide the band off by the window's screen origin, invisible on
            // the primary display at the global origin and badly wrong on every
            // secondary display.
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.accentColor.opacity(0.08))
                .frame(width: marqueeRect.width, height: marqueeRect.height)
                .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                .allowsHitTesting(false)
        } else if let frame = session.selectionAnchorFrame {
            // The committed frame. It deliberately does NOT also draw the resolved
            // element: the user drew a box and asked to see that box, and the whole
            // reported bug was the highlight snapping to a card they never swept.
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.12))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - axOrigin.x, y: frame.minY - axOrigin.y)
                .allowsHitTesting(false)
        } else {
            // The drawn frame AFTER navigation moved the binding off it. Drawn
            // first so it sits BENEATH the element highlight, and much weaker than
            // case 2, so "this is what the note records" cannot be misread as "this
            // is what the note binds to". Skipped when it coincides with the
            // element's own frame — a region-fallback selection, whose synthetic
            // element IS the drawn rect, would otherwise stack two strokes on one
            // edge and read as a rendering glitch.
            if let drawn = session.selectedMarqueeRect, drawn != session.selected?.frame {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: drawn.width, height: drawn.height)
                    .offset(x: drawn.minX - axOrigin.x, y: drawn.minY - axOrigin.y)
                    .allowsHitTesting(false)
            }
            if let element = session.selected ?? session.hovered {
                let originX = element.frame.minX - axOrigin.x
                let originY = element.frame.minY - axOrigin.y
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: originX, y: originY)
                    .allowsHitTesting(false)
                // Name tag: shows WHICH element a click binds to, so an element and
                // its enclosing card (which look alike as bare rectangles) are
                // distinguishable at a glance. Sits just above the highlight, or
                // just inside its top when the element hugs the window's top edge.
                Text(highlightName(element))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .fixedSize()
                    .offset(x: originX, y: originY - 20 < 0 ? originY + 2 : originY - 20)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The label shown on the hover/selection highlight so the user can see WHICH
    /// element a click will bind to — an element vs its enclosing card, which are
    /// otherwise indistinguishable as bare rectangles. Prefers the seeded
    /// identifier (e.g. `Dashboard.Today` for a card surface), then the label,
    /// then the displayed text, then the role.
    private func highlightName(_ element: Element) -> String {
        if let id = element.path.last?.identifier, !id.isEmpty { return id }
        if !element.label.isEmpty { return element.label }
        if !element.value.isEmpty { return String(element.value.prefix(40)) }
        return element.role
    }

    /// Full-screen hover/tap surface, active only while annotating. Behind the
    /// chrome, so a tap on the toolbar/composer routes to those instead.
    @ViewBuilder
    private var catcher: some View {
        if session.mode == .annotating {
            Color.clear
                .contentShape(Rectangle())
                // A freshly-inserted catcher has no press in flight, so it must start
                // in sync. This is not belt-and-braces: leaving annotate mode DURING a
                // drag cancels it and then removes this view, so the release that
                // would have re-armed the generation never arrives — and the first
                // frame drag of the next session would be born cancelled.
                .onAppear { frameDragGeneration = session.frameDragGeneration }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        // While a band is live the user is FRAMING, not hovering:
                        // resolving an element under the moving pointer would draw a
                        // competing highlight underneath the band (and burn an AX
                        // query per motion event) for a selection the release is
                        // about to overwrite anyway.
                        guard marqueeRect == nil else { return }
                        session.hover(atAXPoint: CGPoint(x: point.x + axOrigin.x, y: point.y + axOrigin.y))
                    case .ended:
                        // The cursor left the catcher (it covers the host's full
                        // frame, so this is "left the window" — or moved onto the
                        // toolbar/composer, which consume hover). Nothing is
                        // hovered: drop the highlight instead of freezing on the
                        // last element. An open composer is unaffected (the
                        // highlight renders selected ?? hovered).
                        session.clearHover()
                    }
                }
                // ONE gesture serves BOTH tools, branching on `session.tool` at
                // release. It is deliberately NOT a DragGesture composed with a
                // SpatialTapGesture: `.exclusively`/`.simultaneously` make the
                // recognizers negotiate, and the case that loses that negotiation is
                // the plain click — which then does nothing at all in annotate mode.
                // A single recognizer that asks ``SelectionGesture`` what a press
                // meant has no ambiguity to lose a click in. `minimumDistance: 0` is
                // what lets it also see the press that never moved.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The band is FRAME-MODE-ONLY chrome. Drawing it in point
                            // mode would promise a rectangle the release is never
                            // going to honour — the user would let go expecting what
                            // they swept and get the element they first pressed on.
                            guard session.tool == .frame,
                                  SelectionGesture.travelledFarEnough(from: value.startLocation, to: value.location)
                            else { return }
                            // A press Escape has already cancelled stays dead for the
                            // REST of the press. The button is usually still held when
                            // Escape lands, so the next twitch of the mouse arrives
                            // here — and without this the band would spring back under
                            // the cursor and the release would resolve it, which is
                            // exactly what was just cancelled.
                            guard frameDragGeneration == session.frameDragGeneration else { return }
                            // Announce the drag on the band's FIRST appearance, when
                            // it becomes a thing the user can see and therefore a
                            // thing Escape can refer to.
                            if marqueeRect == nil {
                                frameDragGeneration = session.frameDragGeneration
                                session.beginFrameDrag()
                            }
                            marqueeRect = SelectionGesture.localRect(from: value.startLocation, to: value.location)
                            session.clearHover()
                        }
                        .onEnded { value in
                            marqueeRect = nil
                            // A cancelled drag still delivers this release; the moved
                            // generation is how we know to drop it on the floor.
                            // Resolving anyway would plant exactly the note Escape
                            // was pressed to prevent.
                            let cancelled = frameDragGeneration != session.frameDragGeneration
                            session.endFrameDrag()
                            // Re-arm for the next press BEFORE bailing out, so a
                            // cancellation costs one drag and not the mode.
                            frameDragGeneration = session.frameDragGeneration
                            guard !cancelled else { return }
                            switch SelectionGesture.resolve(
                                tool: session.tool,
                                from: value.startLocation,
                                to: value.location,
                                axOrigin: axOrigin
                            ) {
                            case .point(let point):
                                session.select(atAXPoint: point)
                            case .frame(let rect):
                                session.select(inAXRect: rect)
                            case .none:
                                // A too-short press in frame mode. Do NOTHING —
                                // explicitly not `cancelSelection()`: this fires for
                                // every stray click on the catcher, including the
                                // ones a user makes while a composer is open, and
                                // clearing there would discard a half-typed comment.
                                break
                            }
                        }
                )
                #if os(macOS)
                // The pointer is what stops frame mode reading as broken. A click
                // does nothing there by design, so the cursor has to say "drag here"
                // BEFORE the press, not after it fails to do anything.
                //
                // `.rectSelection` rather than a generic crosshair: it is the system
                // pointer for "drag out a rectangular selection", which is exactly
                // this gesture, so the affordance is one the user has already learned
                // elsewhere. (SwiftUI's `PointerStyle` has no `.crosshair` member —
                // reaching for one does not compile.)
                .pointerStyle(session.tool == .frame ? .rectSelection : nil)
                #endif
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }

    /// The WRITE card: a shared ``AnnotationCard`` anchored to the selected
    /// element, with a single icon row — tree navigation on the left, dismiss and
    /// commit on the right. Enter submits; Escape dismisses via the host's key
    /// monitor (``EscapeRule``), not from inside this view.
    ///
    /// The four controls used to be two rows of TEXT buttons (a Parent/Child
    /// navigation row above a Cancel/Add note footer), because four labelled
    /// buttons do not fit across 260pt. Four 28pt glyphs do, with room to spare, so
    /// the split row was a symptom of the labels rather than of the grouping — and
    /// a two-row footer on a card whose whole job is one text field read as heavier
    /// than the thing it was framing.
    private var composer: some View {
        AnnotationCard(
            header: composerHeader,
            text: $comment,
            placement: composerPlacement,
            // Re-focus when the selection moves element→element (the shared card
            // is not re-inserted, so `.onAppear` won't refire).
            focusKey: session.selected?.id ?? "",
            onSubmit: { addNote() },
            onFocusRequest: onFocusRequest
        ) {
            HStack(spacing: 4) {
                // Tree navigation: rebind the note to the enclosing component, or to
                // a component inside the current one. Leading, and separated from
                // the commit pair by the Spacer, because they change WHAT the note
                // is filed against — they are inputs to the note, not ways of
                // ending it.
                //
                // DISABLED, never hidden. The control this replaces (a lone "Widen"
                // button) appeared and disappeared with availability, and that is a
                // large part of why it was unlearnable: a control you have never
                // seen is a control you cannot predict. Both buttons are always
                // present, so "you can move the binding up and down the tree" is
                // visible from the first note, and the dim tells you where you are
                // in the tree.
                //
                // No element name in these labels: the card HEADER already shows the
                // bound element (`session.selectionLabel`) and re-renders as you
                // navigate, so it is the "where am I" indicator and repeating it
                // would be noise.
                IconButton(
                    icon: .arrowUp,
                    palette: .card,
                    isDisabled: !session.canSelectParent,
                    tooltip: "Select parent component",
                    action: { session.selectParent() }
                )
                IconButton(
                    icon: .arrowDown,
                    palette: .card,
                    isDisabled: !session.canSelectChild,
                    tooltip: "Select child component",
                    action: { session.selectChild() }
                )
                Spacer()
                // No `comment = ""` here any more: the draft is cleared by the
                // composer CLOSING (see the `session.selected` hook on the ZStack), so
                // every dismissal path — this button, Escape, leaving the mode —
                // clears it identically.
                IconButton(
                    icon: .undo2,
                    palette: .card,
                    tooltip: "Cancel",
                    action: { session.cancelSelection() }
                )
                // The commit action, and the ONLY tinted glyph on the card. It lost
                // `.borderedProminent` along with its label, and without the tint it
                // would be one more grey 16pt glyph in a row of four — the user would
                // have to read four tooltips to find out which one files the note.
                // Colour carries the prominence that the filled capsule used to.
                IconButton(
                    icon: .send,
                    palette: .card,
                    isDisabled: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    glyphTint: .accentColor,
                    tooltip: "Add note",
                    action: { addNote() }
                )
            }
        }
    }

    /// The composer's header. For a committed FRAME selection this is the only
    /// place on screen that names the element the note is filed against — the
    /// canvas deliberately shows the drawn rectangle and no name tag — so it must
    /// not read as a label for the rectangle itself. The `Frame →` prefix says the
    /// name is what the frame RESOLVED to, which is the one thing a user cannot
    /// otherwise verify before pressing Add note, and it disappears the moment
    /// Parent/Child re-anchors to a named element on the canvas, so the name is
    /// never qualified in two places at once.
    private var composerHeader: String {
        let label = session.selectionLabel ?? "Element"
        return session.selectionAnchorFrame != nil ? "Frame → \(label)" : label
    }

    /// The EDIT card: the SAME shared ``AnnotationCard`` chrome as the composer,
    /// anchored to the tapped pin instead of an element, with a Delete / Save icon
    /// row. Enter saves, Escape (via the host's key monitor) closes it, and
    /// Save/Delete/click-away all end
    /// editing. Because it lives in the overlay panel (not a system `.popover`),
    /// it inherits the composer's reliable `panel.makeKey()` focus.
    ///
    /// Its row is icons for the same reason the composer's is, and it changed at the
    /// same time on purpose: two cards that share every pixel of their chrome but
    /// disagree about whether actions are words or glyphs would read as a bug in
    /// whichever one the user opened second.
    ///
    /// No navigation pair here: this card edits a note that has ALREADY been
    /// captured, whose selector, component and element path were frozen at capture.
    /// Offering Parent/Child would move a highlight and change nothing about the
    /// record, which is worse than no control at all.
    private func editCard(note: AnnotationNote, anchor: CGPoint) -> some View {
        AnnotationCard(
            header: note.selector,
            text: $editDraft,
            placement: editCardPlacement(anchor: anchor),
            // Re-focus when the editor moves pin→pin without re-insertion.
            focusKey: note.id,
            onSubmit: { saveEdit(note) },
            onFocusRequest: onFocusRequest
        ) {
            HStack(spacing: 4) {
                // Destructive treatment survives the loss of the word "Delete": red
                // at rest and a full red wash on hover (see ``IconButtonPalette.card``),
                // so the one irreversible control on either card is still the only
                // coloured thing besides the commit action.
                IconButton(
                    icon: .trash,
                    palette: .card,
                    isDestructive: true,
                    tooltip: "Delete",
                    action: {
                        session.deleteNote(id: note.id)
                        session.endEditing()
                    }
                )
                Spacer()
                // Same glyph and same accent as the composer's Add note: both cards
                // commit with `send`, so the gesture is learned once.
                IconButton(
                    icon: .send,
                    palette: .card,
                    isDisabled: editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    glyphTint: .accentColor,
                    tooltip: "Save",
                    action: { saveEdit(note) }
                )
            }
        }
    }

    /// Save the edited comment (Enter or the Save button) and close the editor.
    private func saveEdit(_ note: AnnotationNote) {
        guard !editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.updateNote(id: note.id, comment: editDraft)
        session.endEditing()
    }

    /// Resolve the (note, anchor) pair for the currently-open pin editor, or nil
    /// when nothing is being edited (or the note has no drawable anchor). Drives
    /// the ZStack's `else if` branch so the edit card renders in-overlay.
    private var editingCardData: (AnnotationNote, CGPoint)? {
        guard let id = session.editingNoteID,
              let note = session.pending.first(where: { $0.id == id }),
              let anchor = note.anchor else { return nil }
        return (note, anchor)
    }

    /// Placement for the edit card, reusing ``ComposerPlacement/resolve`` by
    /// treating the pin as a small element rect at its window-local anchor.
    /// `resolve` subtracts `axOrigin` internally, so re-adding it here lands the
    /// synthetic frame exactly on the pin; the 20pt pin diameter is used as the
    /// element size so the caret aligns to the pin's center (pointing up at it,
    /// flipping above when it would spill off the bottom).
    private func editCardPlacement(anchor: CGPoint) -> ComposerPlacement {
        let pin: CGFloat = 20 // AnnotationPin.diameter
        // The pin is DRAWN centered on `anchor` (AnnotationPin offsets by
        // -diameter/2), so the synthetic element rect must be centered on the pin
        // too: window-local top-left = anchor - pin/2. `resolve` subtracts
        // `axOrigin`, so add it back here. This points the caret at the pin's real
        // center with the intended gap (the old `anchor` top-left was off by pin/2).
        let elementFrame = CGRect(
            x: anchor.x - pin / 2 + axOrigin.x,
            y: anchor.y - pin / 2 + axOrigin.y,
            width: pin,
            height: pin
        )
        return ComposerPlacement.resolve(
            elementFrame: elementFrame,
            axOrigin: axOrigin,
            surfaceSize: surfaceSize,
            composerSize: composerEstimatedSize
        )
    }

    /// Capture the pending note. Snapshots the pin anchor BEFORE `addNote` clears
    /// the selection (AX top-left minus axOrigin — the same window-local transform
    /// the highlight uses — so the pin lands on the top-left corner of whatever was
    /// highlighted), then resets the field. Enter submits; Shift+Enter inserts a
    /// newline (handled in the field's `onKeyPress`).
    ///
    /// The anchor follows the SAME rect the highlight and composer used: pinning a
    /// framed note to the resolved element instead would drop the numbered pin on a
    /// corner the user never swept — possibly far outside the frame, for a frame
    /// that resolved to a large enclosing card.
    private func addNote() {
        guard !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let anchor = (session.selectionAnchorFrame ?? session.selected?.frame).map {
            CGPoint(x: $0.minX - axOrigin.x, y: $0.minY - axOrigin.y)
        }
        session.addNote(comment: comment, anchor: anchor)
        comment = ""
    }

    /// Estimated card size (260 field + 12 padding each side ≈ 284 wide; a
    /// representative height). Only used to clamp the card on-screen and to pick
    /// below vs above — the caret attaches to the card's real edge via layout, so
    /// a slightly-off estimate never detaches the pointer.
    private var composerEstimatedSize: CGSize { CGSize(width: 284, height: 172) }

    /// Adjacent, on-screen placement for the composer, shared by the card offset
    /// and its caret. See ``ComposerPlacement``. On the primary display at the
    /// global origin `axOrigin == .zero`, so the previously-working case (card
    /// directly below the element) is unchanged.
    ///
    /// Anchored to the DRAWN frame while that is the truth of the selection, so the
    /// card points at the rectangle the user swept rather than at the element it
    /// resolved to (which may be much larger, and elsewhere). ``ComposerPlacement``
    /// already clamps both axes and flips the card when it would spill, so a frame
    /// larger than any element — even one spanning the whole window — still places
    /// sanely; feeding it the frame is the entire change.
    private var composerPlacement: ComposerPlacement {
        guard let f = session.selectionAnchorFrame ?? session.selected?.frame else {
            return ComposerPlacement(origin: CGPoint(x: 24, y: 24), caretPointsUp: true, caretDX: 0)
        }
        return ComposerPlacement.resolve(
            elementFrame: f,
            axOrigin: axOrigin,
            surfaceSize: surfaceSize,
            composerSize: composerEstimatedSize
        )
    }

}

/// The toolbar pill, in a window of its OWN.
///
/// The pill used to be drawn inside the catcher's ZStack, which meant its position
/// was a function of the catcher panel's frame — and that frame changes size on
/// every open/close, gets narrowed to the visible screen, and is dragged around by
/// AppKit whenever the host window moves. Three ways for a control that must never
/// move to move, and a fourth failure on top: anything that stalled the catcher
/// (a wedged scroll, a rebuilt SwiftUI root) took the pill down with it.
///
/// Giving it a separate, permanently mounted panel makes the guarantee structural
/// rather than incidental: the pill is always present, always at the host's
/// bottom-right corner, and the catcher's geometry and lifetime cannot touch it.
/// The menu is now genuinely just OPEN or CLOSED — the toolbar itself never moves
/// between the two.
struct ToolbarOverlayView: View {
    @ObservedObject var session: AnnotationSession
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                ToolbarView(
                    session: session,
                    onToggle: onToggle,
                    onCopy: onCopy,
                    onExport: onExport
                )
                .padding(20)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The shared floating card behind BOTH the composer (write a new note) and the
/// pin editor (edit an existing note), so the two can never drift apart. It owns
/// all the chrome — the `.regularMaterial` rounded background, the gray
/// ``ComposerCaret`` pointing at its anchor, the drop shadow, the
/// ``ComposerPlacement`` offset, first-responder focus (host `makeKey` +
/// `@FocusState` + a next-tick re-assert to beat the insertion race), and the
/// keyboard contract it can actually honour: Enter submits and Shift+Enter inserts
/// a newline. Escape is NOT handled here — it is the host key monitor's, because a
/// view-level handler only ever sees it once the overlay panel is key (see the note
/// at the bottom of `body`).
///
/// The two flows differ ONLY in the `header` text, the `text` binding, the
/// `placement` anchor, and the `footer` icon row.
private struct AnnotationCard<Footer: View>: View {
    /// Header label: the composer shows the element's selection label; the editor
    /// shows the note's selector.
    let header: String
    /// The edited text: `$comment` for the composer, `$editDraft` for the editor.
    @Binding var text: String
    /// Adjacent, on-screen placement (offset + caret direction/offset), computed by
    /// ``OverlayView`` from the selected element or the pin anchor.
    let placement: ComposerPlacement
    /// A value that changes when the card should re-focus WITHOUT being re-inserted
    /// (element→element for the composer, pin→pin for the editor). Using this (not
    /// `.id()`) preserves the smooth slide between anchors.
    let focusKey: String
    /// Enter (no Shift) and the trailing footer button.
    let onSubmit: () -> Void
    /// Make the host panel key so the field accepts keystrokes (`panel.makeKey()`
    /// on macOS; a no-op on iOS, where `@FocusState` alone raises the keyboard).
    let onFocusRequest: () -> Void
    /// The differing icon row (Parent/Child/Cancel/Add note vs Delete/Save). One
    /// slot, not the two it used to be: the separate `navigation` row existed only
    /// because four TEXT buttons could not share 260pt, and four glyphs can.
    @ViewBuilder let footer: () -> Footer

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(header)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Enter submits; Shift+Enter inserts a newline.
                Text("⏎ save · ⇧⏎ newline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: 260)
            TextField("Describe the change", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
                .frame(width: 260)
                .focused($focused)
                // Enter submits; Shift+Enter falls through to insert a newline in
                // the multiline field.
                .onKeyPress(keys: [.return]) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
                    onSubmit()
                    return .handled
                }
            footer()
                .frame(width: 260)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        // Caret in the gap, tying the card back to its anchor (element or pin). It
        // uses the SAME material as the card so it reads as the card's pointer (not
        // an accent), points up when the card is below (down when flipped above),
        // and slides horizontally (`caretDX`) to line up with the anchor's center.
        // Added before the shadow so card and caret cast one unified shadow.
        .overlay(alignment: placement.caretPointsUp ? .top : .bottom) {
            ComposerCaret(pointsUp: placement.caretPointsUp)
                .fill(.regularMaterial)
                .frame(width: 16, height: 8)
                .offset(x: placement.caretDX, y: placement.caretPointsUp ? -7 : 7)
        }
        .shadow(radius: 12)
        .offset(x: placement.origin.x, y: placement.origin.y)
        // Slide the card when its anchor moves (element→element or pin→pin). Keyed
        // on the placement (Equatable) so a host-window drag keeps the card glued
        // instead of lagging behind.
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: placement)
        // Focus on first appearance and on anchor switches that don't re-insert
        // the view (so `.onAppear` won't refire).
        .onAppear { focus() }
        .onChange(of: focusKey) { _, _ in focus() }
        // NO `.onExitCommand` here, deliberately. It only ever fired when the overlay
        // PANEL was key — which happens only once a card has focused its text field —
        // so it could not dismiss anything in the state a user most wants out of
        // (annotate mode, nothing open, host window key). Escape now has exactly ONE
        // owner, the controller's local key monitor, which sees the keystroke wherever
        // it is delivered. Restoring this modifier would not be redundancy: with the
        // panel key BOTH handlers would run on one press, closing the card and then
        // acting again on the state that leaves behind.
    }

    /// Focus the text field, making the host panel key FIRST so the non-activating
    /// child window accepts keystrokes. A `@FocusState` set in the same layout pass
    /// that inserts the field can be dropped on first appearance (the classic
    /// first-responder race), so re-assert on the next main-actor tick.
    private func focus() {
        onFocusRequest()
        focused = true
        Task { @MainActor in focused = true }
    }
}

/// The compact dark icon pill, styled after the Agentation nav bar and shared by
/// both platform hosts. Every control maps to a real ``AnnotationSession``
/// capability — no dead buttons (CLAUDE.md) — so Agentation's `settings`/`eye`
/// (no settings model, no preview capability here) are deliberately omitted.
///
/// Idle is JUST the pencil, so the resting affordance is one unambiguous "start
/// annotating". Annotate mode replaces it outright with the working set, in two
/// groups split by a hairline divider.
///
/// LEFT of the divider: the selection-tool segment — point (click the thing) and
/// frame (draw a rectangle around it) — with the active one lit. It leads the row
/// because it governs what every subsequent press on the catcher DOES, and because
/// frame mode's "a click does nothing" contract is only honest if the mode is
/// visible somewhere. These two are never disabled: they are how you get out of a
/// mode, so gating them could strand a user in one.
///
/// RIGHT of the divider: what you then do with the notes, left to right — two
/// DISTINCT persist actions (Copy to the clipboard as markdown, and Export to
/// `AGENTATION_NOTES.md`), a destructive clear, and the X that leaves the mode.
/// The X sits FAR RIGHT because that is where a "close this mode"
/// control is looked for, and it is drawn as a plain action rather than a lit-up
/// toggle — the expanded pill and the live catcher already say annotate mode is
/// on, so a permanently bright glyph would only add noise. The three note actions
/// are disabled/dimmed while `pending` is empty (acting on zero notes is a
/// no-op); the X is never gated, because leaving must always work. A count badge
/// overlays the pill whenever notes exist. Copy and Export never clear the
/// retained set (only Clear does), so the same notes can be both copied and
/// exported. Copy/Export flow through host callbacks (they need a sink); the mode
/// control needs the controller (activation); clear and the tool segment
/// read/write the session directly.
///
/// The pill itself is rendered unconditionally and is NEVER gated on an entrance
/// flag, so it stays visible across idle<->annotate; only its contents swap as
/// annotate mode toggles.
struct ToolbarView: View {
    @ObservedObject var session: AnnotationSession
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onExport: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justCopied = false

    private var annotating: Bool { session.mode == .annotating }
    private var hasNotes: Bool { !session.pending.isEmpty }

    var body: some View {
        HStack(spacing: 2) {
            // The two modes share no controls, so they are two whole rows rather
            // than one row with conditional members: idle is the pencil alone,
            // annotate is the tool segment, a divider, then the note actions
            // (dimmed/disabled with no notes to act on) closed by the exit X.
            if annotating {
                // Selection-tool segment. NOT gated on `hasNotes` — unlike every
                // control to its right, these change how the NEXT press behaves, so
                // they must stay live in an empty session, which is exactly when a
                // user is choosing how to make their first selection.
                IconButton(
                    icon: .mousePointer,
                    isActive: session.tool == .point,
                    tooltip: "Select by clicking",
                    action: { session.setTool(.point) }
                )
                IconButton(
                    icon: .squareDashed,
                    isActive: session.tool == .frame,
                    tooltip: "Select by drawing a frame",
                    action: { session.setTool(.frame) }
                )
                // Groups "how you select" apart from "what you do with the notes".
                // Without it the six glyphs read as one undifferentiated strip and
                // the two stateful buttons look like two more one-shot actions.
                Rectangle()
                    .fill(PillStyle.divider)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 3)
                    .allowsHitTesting(false)
                IconButton(
                    icon: justCopied ? .check : .copy,
                    isDisabled: !hasNotes,
                    glyphTint: justCopied ? PillStyle.success : nil,
                    tooltip: justCopied ? "Copied" : "Copy notes (Markdown)",
                    action: { onCopy(); flashCopied() }
                )
                IconButton(
                    icon: .download,
                    isDisabled: !hasNotes,
                    tooltip: "Export to AGENTATION_NOTES.md",
                    action: onExport
                )
                IconButton(icon: .trash, isDestructive: true, isDisabled: !hasNotes, tooltip: "Clear notes") {
                    session.clear()
                }
                // Deliberately NOT gated on `hasNotes`: with zero notes every other
                // control is inert, so the X is the only live thing left and must
                // still work.
                IconButton(icon: .close, tooltip: "Stop annotating", action: onToggle)
            } else {
                IconButton(icon: .pencil, tooltip: "Annotate", action: onToggle)
            }
        }
        // Idle shows ONE 28pt button, so the inset must be EVEN (8pt all around ->
        // a concentric 44x44 capsule hugging the hover wash). The 6pt horizontal
        // inset is for the annotate-mode ROW only — now SIX buttons plus a divider,
        // so the row is wide enough that trimming 2pt off each end reads as balanced
        // rather than cramped, and the saved width keeps the pill off the window
        // edge it is anchored 20pt from.
        .padding(.horizontal, annotating ? 6 : 8)
        .padding(.vertical, 8) // 28pt buttons + 8*2 -> 44pt pill height
        .background(
            Capsule(style: .continuous)
                .fill(PillStyle.background)
                .overlay(Capsule(style: .continuous).strokeBorder(PillStyle.border, lineWidth: 1))
        )
        // Count bubble on the WHOLE pill's top-left corner (not inline in the row,
        // not on the toggle). Non-interactive so it never eats a pill click.
        .overlay(alignment: .topLeading) {
            if hasNotes {
                countBadge
                    .offset(x: -5, y: -5)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
        // Animate the row swap (and the pill's width with it) as annotate mode
        // toggles. The pill itself has no entrance gate: it is always visible
        // (just the pencil when idle).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: annotating)
    }

    /// Show a green check on the Copy button for a beat as success feedback, then
    /// revert to the copy glyph.
    private func flashCopied() {
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            justCopied = false
        }
    }

    /// Compact count bubble that overlaps the pill's top-left corner. A ~18pt
    /// accent capsule (grows for multi-digit counts) with white monospaced digits
    /// and a thin dark ring for contrast; reuses the accent so it reads as one
    /// family with the highlight and the numbered pins.
    private var countBadge: some View {
        Text("\(session.pending.count)")
            .font(.caption2.monospacedDigit().bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .accessibilityLabel("\(session.pending.count) pending notes")
    }
}

/// A single 28pt circular Lucide icon button: transparent when idle, a faint wash
/// on hover (the destructive fill for destructive actions), dimmed and inert when
/// disabled, pressed in slightly on tap. Each carries a tooltip (`.help`) and a
/// MATCHING accessibility label — an icon-only control with a tooltip alone is
/// simply unlabelled to VoiceOver, which is why the two are one parameter here
/// rather than two that can be filled in independently.
///
/// ONE implementation serves both the dark toolbar pill and the `.regularMaterial`
/// note cards, differing only by ``IconButtonPalette``. The colours are the cheap
/// part; the reason this is not two views is the interaction logic above, where a
/// second copy would drift silently (hover that survives a disable, a press scale
/// that stops honouring reduce-motion) and only ever be noticed on one surface.
private struct IconButton: View {
    let icon: LucideIcon
    /// Defaulted to the pill so the toolbar's seven call sites stay exactly as they
    /// were — this is a refactor for the pill, not a restyle of it.
    var palette: IconButtonPalette = .pill
    var isDestructive: Bool = false
    /// Dims the glyph and makes the button a true no-op (used by copy/export/clear
    /// while there are no notes to act on).
    var isDisabled: Bool = false
    /// Lights the glyph to full white for the SELECTED member of a segmented
    /// control. Back after being removed as dead code: the selection-tool pair is
    /// the pill's only control carrying PERSISTENT state — every other button is a
    /// one-shot action, which is why hover was briefly the only state that existed.
    /// A segment with no lit member is worse than no segment at all, because the
    /// user cannot tell whether a click will select a point or do nothing.
    var isActive: Bool = false
    /// Overrides the glyph colour outright, for a button whose MEANING is a colour:
    /// the pill's copied-check flash, and the cards' accent-tinted commit action,
    /// which is how `send` keeps the prominence `.borderedProminent` used to give it.
    /// Ranked below `isDisabled` on purpose — an accent glyph on a dead button would
    /// advertise a commit the empty field cannot make.
    var glyphTint: Color? = nil
    /// Shown on hover AND read by VoiceOver. Name the effect in full: the glyph no
    /// longer carries a word beside it, so this string is the only place the action
    /// is named at all.
    let tooltip: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var glyphColor: Color {
        // Disabled outranks every other state: a dimmed glyph with no hover/active
        // treatment reads as unavailable.
        if isDisabled { return palette.disabled }
        if let glyphTint { return glyphTint }
        // Active outranks hover: hovering the ALREADY-active tool must not dim it
        // toward the inactive treatment, which would read as "clicking this turns
        // it off" for a segment that has no off.
        if isActive { return palette.active }
        if isDestructive { return hovering ? palette.destructiveHover : palette.destructiveIdle }
        return hovering ? palette.hover : palette.idle
    }

    // Hover is the ONLY fill state, even for the active tool: the segment is
    // distinguished by glyph BRIGHTNESS alone, so a persistent circle behind the
    // active tool cannot be mistaken for the hover wash sitting on a neighbour.
    private var fillColor: Color {
        // No hover wash while disabled — the button must look inert.
        if hovering && !isDisabled { return isDestructive ? palette.destructiveFill : palette.hoverFill }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            LucideShape(parts: icon.parts)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 16)
                .foregroundStyle(glyphColor)
                .frame(width: 28, height: 28)
                .background(Circle().fill(fillColor))
                .contentShape(Circle())
        }
        .buttonStyle(PressableIconButtonStyle(reduceMotion: reduceMotion))
        .disabled(isDisabled)
        .iconToolTip(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { value in
            // Ignore hover entirely while disabled so no wash/glyph change leaks in.
            guard !isDisabled else { return }
            guard !reduceMotion else { hovering = value; return }
            withAnimation(.easeOut(duration: 0.15)) { hovering = value }
        }
    }
}

/// Presses the glyph in slightly on tap (`scaleEffect(0.96)`), honoring
/// reduce-motion by dropping the animation.
private struct PressableIconButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A small triangular pointer that connects the composer card to its element.
/// The base spans the card edge and the apex points toward the element — up when
/// the card sits below the element, down when it is flipped above.
private struct ComposerCaret: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsUp {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY)) // apex up
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY)) // apex down
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
