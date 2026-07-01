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
    /// Dismiss the whole overlay (macOS -> `unmount()`, iOS -> hide the window).
    let onClose: () -> Void
    /// Make the host panel key so the composer's text field accepts keystrokes.
    /// macOS passes `panel.makeKey()` (the child panel is non-activating, so a
    /// programmatic focus needs the window made key first); iOS uses the default
    /// no-op because `@FocusState` alone raises the keyboard. See Feature 3.
    /// A `var` (not `let`) so it stays a defaulted memberwise-init parameter that
    /// the iOS host can omit.
    var onFocusRequest: () -> Void = {}

    @State private var comment: String = ""
    /// Drives first-responder focus of the composer field so a click on an
    /// element lets the user type immediately (Feature 3). The same
    /// `@FocusState` + `.onAppear` pattern backs the pin edit popover.
    @FocusState private var composerFocused: Bool

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

            if session.selected != nil {
                composer
            }

            toolbar
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
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

    private var composer: some View {
        let placement = composerPlacement
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(session.selectionLabel ?? "Element")
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
            TextField("Describe the change", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
                .frame(width: 260)
                .focused($composerFocused)
                // Enter submits the note; Shift+Enter falls through to insert a
                // newline in the multiline field.
                .onKeyPress(keys: [.return]) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
                    addNote()
                    return .handled
                }
            HStack {
                Button("Cancel") {
                    comment = ""
                    session.cancelSelection()
                }
                // Escape cancels the composer (reuses the Cancel action). The
                // panel is key while typing, so the shortcut reaches this button.
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add note") { addNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 260)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        // Caret in the gap, tying the card back to the highlighted element. It
        // uses the SAME material as the card so it reads as the card's pointer
        // (not an accent), points up when the card is below (down when flipped
        // above), and slides horizontally (`caretDX`) to line up with the
        // element's center. Added before the shadow so card and caret cast one
        // unified shadow.
        .overlay(alignment: placement.caretPointsUp ? .top : .bottom) {
            ComposerCaret(pointsUp: placement.caretPointsUp)
                .fill(.regularMaterial)
                .frame(width: 16, height: 8)
                .offset(x: placement.caretDX, y: placement.caretPointsUp ? -7 : 7)
        }
        .shadow(radius: 12)
        .offset(x: placement.origin.x, y: placement.origin.y)
        // Track the selection: slide the composer when it moves from one element
        // to the next. Keyed on the selection (not `axOrigin`) so a host-window
        // drag keeps the composer glued instead of lagging behind.
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: session.selected)
        // Focus on first appearance (nil -> element) and on element -> element
        // switches (the composer is not re-inserted, so `.onAppear` won't fire).
        .onAppear { focusComposer() }
        .onChange(of: session.selected) { _, newValue in
            if newValue == nil { composerFocused = false } else { focusComposer() }
        }
    }

    /// Focus the composer text field, making the host panel key FIRST so the
    /// non-activating child window accepts keystrokes. If focus does not stick on
    /// first appearance on some macOS builds (a known `@FocusState`-set-during-
    /// insertion race), the fallback is to defer the `composerFocused = true` to
    /// the next runloop tick.
    private func focusComposer() {
        onFocusRequest()
        composerFocused = true
        // A @FocusState set in the same layout pass that inserts the field can be
        // dropped on first appearance (the classic first-responder race); re-assert
        // on the next main-actor tick so the first click reliably lands the cursor.
        Task { @MainActor in composerFocused = true }
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
                    onExport: onExport,
                    onClose: onClose
                )
                .padding(20)
            }
        }
    }
}

/// The compact dark icon pill, styled after the Agentation nav bar and shared by
/// both platform hosts. Every control maps to a real ``AnnotationSession``
/// capability — no dead buttons (CLAUDE.md) — so Agentation's `settings`/`eye`
/// (no settings model, no preview capability here) are deliberately omitted.
///
/// Left to right: annotate toggle (always), then — only while notes exist — a
/// count badge, then two DISTINCT persist actions (Copy to the clipboard as
/// markdown, and Export to `AGENTATION_NOTES.md`), and a destructive clear, then
/// a divider and a close/exit (always). Copy and Export never clear the retained
/// set (only Clear does), so the same notes can be both copied and exported.
/// Copy/Export flow through host callbacks (they need a sink); toggle needs the
/// controller (activation); clear reads/writes the session directly.
///
/// The pill itself is rendered unconditionally and is NEVER gated on an entrance
/// flag, so it stays visible across idle<->annotate and before/during/after
/// capturing a note; only the note-action cluster animates in and out.
private struct ToolbarView: View {
    @ObservedObject var session: AnnotationSession
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onExport: () -> Void
    let onClose: () -> Void

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

            if hasNotes {
                PillButton(
                    icon: justCopied ? .check : .copy,
                    glyphTint: justCopied ? PillStyle.success : nil,
                    tooltip: justCopied ? "Copied" : "Copy notes (Markdown)",
                    action: { onCopy(); flashCopied() }
                )
                PillButton(icon: .download, tooltip: "Export to AGENTATION_NOTES.md", action: onExport)
                PillButton(icon: .trash, isDestructive: true, tooltip: "Clear notes") {
                    session.clear()
                }
            }

            divider
            PillButton(icon: .close, tooltip: "Exit annotate mode", action: onClose)
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
        // Reveal/hide the note-action cluster smoothly as pending changes. The
        // pill has no entrance opacity/scale gate: it must ALWAYS be visible.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasNotes)
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

    private var divider: some View {
        Rectangle()
            .fill(PillStyle.divider)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
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
    var glyphTint: Color? = nil
    let tooltip: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var glyphColor: Color {
        if let glyphTint { return glyphTint }
        if isDestructive && hovering { return .white }
        if isActive { return .white }
        return hovering ? PillStyle.iconHover : PillStyle.iconIdle
    }

    // Active state is carried by `glyphColor` (white when active) with NO circle
    // fill, so the annotate toggle reads as a bright glyph, not a blue chip.
    private var fillColor: Color {
        if hovering { return isDestructive ? PillStyle.destructive : PillStyle.hoverBackground }
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
        .pillToolTip(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { value in
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
