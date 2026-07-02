import SwiftUI

/// The overlay's SwiftUI content, shared by the macOS and iOS hosts.
///
/// Interaction is driven entirely through SwiftUI hit-testing, which fixes the
/// two ways a global click monitor went wrong: a full-screen catcher (active
/// only in annotate mode, behind the chrome) receives hover and taps over the
/// app, while the toolbar and composer sit on top and consume their own clicks,
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            catcher

            if let element = session.selected ?? session.hovered {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: element.frame.minX - axOrigin.x, y: element.frame.minY - axOrigin.y)
                    .allowsHitTesting(false)
            }

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

            toolbar
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
    }

    /// Full-screen hover/tap surface, active only while annotating. Behind the
    /// chrome, so a tap on the toolbar/composer routes to those instead.
    @ViewBuilder
    private var catcher: some View {
        if session.mode == .annotating {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase {
                        session.hover(atAXPoint: CGPoint(x: point.x + axOrigin.x, y: point.y + axOrigin.y))
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { event in
                        session.select(atAXPoint: CGPoint(x: event.location.x + axOrigin.x, y: event.location.y + axOrigin.y))
                    }
                )
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }

    /// The WRITE card: a shared ``AnnotationCard`` anchored to the selected
    /// element, with a Cancel / Add note footer. Enter submits, Escape cancels.
    private var composer: some View {
        AnnotationCard(
            header: session.selectionLabel ?? "Element",
            text: $comment,
            placement: composerPlacement,
            // Re-focus when the selection moves element→element (the shared card
            // is not re-inserted, so `.onAppear` won't refire).
            focusKey: session.selected?.id ?? "",
            onSubmit: { addNote() },
            onCancel: {
                comment = ""
                session.cancelSelection()
            },
            onFocusRequest: onFocusRequest
        ) {
            HStack {
                Button("Cancel") {
                    comment = ""
                    session.cancelSelection()
                }
                Spacer()
                Button("Add note") { addNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The EDIT card: the SAME shared ``AnnotationCard`` chrome as the composer,
    /// anchored to the tapped pin instead of an element, with a Delete / Save
    /// footer. Enter saves, Escape cancels, and Save/Delete/click-away all end
    /// editing. Because it lives in the overlay panel (not a system `.popover`),
    /// it inherits the composer's reliable `panel.makeKey()` focus.
    private func editCard(note: AnnotationNote, anchor: CGPoint) -> some View {
        AnnotationCard(
            header: note.selector,
            text: $editDraft,
            placement: editCardPlacement(anchor: anchor),
            // Re-focus when the editor moves pin→pin without re-insertion.
            focusKey: note.id,
            onSubmit: { saveEdit(note) },
            onCancel: { session.endEditing() },
            onFocusRequest: onFocusRequest
        ) {
            HStack {
                Button(role: .destructive) {
                    session.deleteNote(id: note.id)
                    session.endEditing()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .tint(.red)
                Spacer()
                Button("Save") { saveEdit(note) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    /// the selection (element AX top-left minus axOrigin — the same window-local
    /// transform the highlight uses — so the pin lands on the element's top-left
    /// corner), then resets the field. Enter submits; Shift+Enter inserts a
    /// newline (handled in the field's `onKeyPress`).
    private func addNote() {
        guard !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let anchor = session.selected.map {
            CGPoint(x: $0.frame.minX - axOrigin.x, y: $0.frame.minY - axOrigin.y)
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
    private var composerPlacement: ComposerPlacement {
        guard let f = session.selected?.frame else {
            return ComposerPlacement(origin: CGPoint(x: 24, y: 24), caretPointsUp: true, caretDX: 0)
        }
        return ComposerPlacement.resolve(
            elementFrame: f,
            axOrigin: axOrigin,
            surfaceSize: surfaceSize,
            composerSize: composerEstimatedSize
        )
    }

    /// Pins the compact pill to the host window's bottom-right corner (margin 20,
    /// matching the idle child-window frame the controller sizes).
    private var toolbar: some View {
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
    }
}

/// The shared floating card behind BOTH the composer (write a new note) and the
/// pin editor (edit an existing note), so the two can never drift apart. It owns
/// all the chrome — the `.regularMaterial` rounded background, the gray
/// ``ComposerCaret`` pointing at its anchor, the drop shadow, the
/// ``ComposerPlacement`` offset, first-responder focus (host `makeKey` +
/// `@FocusState` + a next-tick re-assert to beat the insertion race), and the
/// keyboard contract (Enter submits, Shift+Enter inserts a newline, Escape
/// cancels on macOS). The two flows differ ONLY in the `header` text, the `text`
/// binding, the `placement` anchor, and the `footer` button row.
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
    /// Escape (macOS) and the leading footer button (Cancel for the composer).
    let onCancel: () -> Void
    /// Make the host panel key so the field accepts keystrokes (`panel.makeKey()`
    /// on macOS; a no-op on iOS, where `@FocusState` alone raises the keyboard).
    let onFocusRequest: () -> Void
    /// The differing two-button row (Cancel/Add note vs Delete/Save).
    @ViewBuilder let footer: () -> Footer

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(header)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Enter submits; Shift+Enter inserts a newline; Esc cancels.
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
        #if os(macOS)
        // Escape cancels without committing (macOS-only API; iOS has no Esc key).
        .onExitCommand { onCancel() }
        #endif
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
/// Left to right: annotate toggle (always), then — ONLY while annotating — two
/// DISTINCT persist actions (Copy to the clipboard as markdown, and Export to
/// `AGENTATION_NOTES.md`) and a destructive clear. Idle shows JUST the pencil; the
/// tools appear when annotate mode is on, and are disabled/dimmed while `pending`
/// is empty (acting on zero notes is a no-op). A count badge overlays the pill
/// whenever notes exist. The pencil toggle exits annotate mode, so there is no
/// separate close/exit control. Copy and Export never clear the retained set (only
/// Clear does), so the same notes can be both copied and exported. Copy/Export
/// flow through host callbacks (they need a sink); toggle needs the controller
/// (activation); clear reads/writes the session directly.
///
/// The pill itself is rendered unconditionally and is NEVER gated on an entrance
/// flag, so it stays visible across idle<->annotate; the note-action cluster
/// animates in and out as annotate mode toggles.
private struct ToolbarView: View {
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
            PillButton(
                icon: annotating ? .pencilOff : .pencil,
                isActive: annotating,
                tooltip: annotating ? "Stop annotating" : "Annotate",
                action: onToggle
            )

            // Copy/Export/Clear appear ONLY in annotate mode; idle shows just the
            // pencil. While annotating they dim/disable when there are no notes
            // (acting on zero notes is a no-op).
            if annotating {
                PillButton(
                    icon: justCopied ? .check : .copy,
                    isDisabled: !hasNotes,
                    glyphTint: justCopied ? PillStyle.success : nil,
                    tooltip: justCopied ? "Copied" : "Copy notes (Markdown)",
                    action: { onCopy(); flashCopied() }
                )
                PillButton(
                    icon: .download,
                    isDisabled: !hasNotes,
                    tooltip: "Export to AGENTATION_NOTES.md",
                    action: onExport
                )
                PillButton(icon: .trash, isDestructive: true, isDisabled: !hasNotes, tooltip: "Clear notes") {
                    session.clear()
                }
            }
        }
        .padding(.horizontal, 6)
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
        // Animate the note-action cluster in/out as annotate mode toggles. The
        // pill itself has no entrance gate: it is always visible (just the pencil
        // when idle).
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

/// A single 28pt circular icon button in the pill: transparent when idle, a faint
/// white wash on hover (red for destructive), and a bright white glyph (no circle
/// fill) when its toggle is active. Each carries a tooltip (`.help`) and a
/// matching accessibility label.
private struct PillButton: View {
    let icon: LucideIcon
    var isActive: Bool = false
    var isDestructive: Bool = false
    /// Dims the glyph and makes the button a true no-op (used by copy/export/clear
    /// while there are no notes to act on).
    var isDisabled: Bool = false
    var glyphTint: Color? = nil
    let tooltip: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var glyphColor: Color {
        // Disabled outranks every other state: a dimmed glyph with no hover/active
        // treatment reads as unavailable.
        if isDisabled { return PillStyle.iconIdle.opacity(0.4) }
        if let glyphTint { return glyphTint }
        if isDestructive && hovering { return .white }
        if isActive { return .white }
        return hovering ? PillStyle.iconHover : PillStyle.iconIdle
    }

    // Active state is carried by `glyphColor` (white when active) with NO circle
    // fill, so the annotate toggle reads as a bright glyph, not a blue chip.
    private var fillColor: Color {
        // No hover wash while disabled — the button must look inert.
        if hovering && !isDisabled { return isDestructive ? PillStyle.destructive : PillStyle.hoverBackground }
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
        .buttonStyle(PressablePillButtonStyle(reduceMotion: reduceMotion))
        .disabled(isDisabled)
        .pillToolTip(tooltip)
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
private struct PressablePillButtonStyle: ButtonStyle {
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
