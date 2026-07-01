import SwiftUI

/// Numbered comment pins (Feature 1), shared by the macOS and iOS overlay hosts.
///
/// Each captured note carries a window-local ``AnnotationNote/anchor`` — the
/// element's AX top-left minus the host window's `axOrigin` AT CAPTURE — so a pin
/// stays glued to where the note was made when the host WINDOW moves (the panel is
/// a child window, so a window-local value is invariant under a window drag). It is
/// FIXED, not live-tracked: it will not chase a scrolled element (accepted).
///
/// Pins are annotate-mode-only chrome, mounted in ``OverlayView`` ABOVE the
/// full-window catcher and BELOW the composer/toolbar, so each pin consumes its
/// own hover/click and can never fall through to re-select the element beneath it.
/// The whole overlay stays `accessibilityHidden`, so pins never disturb the AX
/// point query's see-through.
struct AnnotationPins: View {
    @ObservedObject var session: AnnotationSession

    var body: some View {
        // Enumerate the FULL retained set so a pin's number matches the count
        // badge; notes captured without an anchor simply draw nothing.
        ForEach(Array(session.pending.enumerated()), id: \.element.id) { index, note in
            if let anchor = note.anchor {
                AnnotationPin(session: session, note: note, number: index + 1, anchor: anchor)
            }
        }
    }
}

/// A single numbered pin overlapping the element's top-left corner. It is a button
/// that consumes its own click (opens the editor, never selects), and — sitting
/// above the catcher — its hover/click cannot fall through to the element.
private struct AnnotationPin: View {
    @ObservedObject var session: AnnotationSession
    let note: AnnotationNote
    let number: Int
    let anchor: CGPoint

    @State private var editing = false

    private let diameter: CGFloat = 20

    var body: some View {
        Button {
            editing = true
        } label: {
            Text("\(number)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        // Open the editor on hover; do NOT close on hover-exit. Pure hover-driven
        // popovers are finicky — moving the pointer from the pin INTO the popover
        // can dismiss it — so this uses the stable "open on hover, close
        // explicitly" rule: the popover owns dismissal (click-away / Save / Delete
        // / Esc).
        .onHover { inside in
            if inside { editing = true }
        }
        .popover(isPresented: $editing, arrowEdge: .top) {
            PinPopover(session: session, note: note, isPresented: $editing)
        }
        // The overlay ZStack is `.topLeading`, so centering the pin on the
        // element's top-left corner is `anchor - radius`.
        .offset(x: anchor.x - diameter / 2, y: anchor.y - diameter / 2)
    }
}

/// The pin's edit popover: an auto-focused, inline-editable comment field plus
/// Save and Delete. Reuses Feature 3's focus pattern (`@FocusState` + `.onAppear`),
/// ⌘Return to save, and Escape to cancel. Save edits the retained note in place;
/// Delete drops it from `pending`, so the `ForEach` reflows the numbers and the
/// count badge automatically.
private struct PinPopover: View {
    @ObservedObject var session: AnnotationSession
    let note: AnnotationNote
    @Binding var isPresented: Bool

    @State private var draft: String
    @FocusState private var focused: Bool

    init(session: AnnotationSession, note: AnnotationNote, isPresented: Binding<Bool>) {
        self.session = session
        self.note = note
        self._isPresented = isPresented
        self._draft = State(initialValue: note.comment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(note.selector)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("⌘⏎ save · esc cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(width: 240)
            TextField("Describe the change", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
                .frame(width: 240)
                .focused($focused)
            HStack {
                Button(role: .destructive) {
                    session.deleteNote(id: note.id)
                    isPresented = false
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Spacer()
                Button("Save") {
                    session.updateNote(id: note.id, comment: draft)
                    isPresented = false
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 240)
        }
        .padding(12)
        // Auto-focus the field on appearance (same pattern as the composer). The
        // popover presents in its own window, so `makeKey` on the parent panel does
        // not apply here; re-assert focus on the next tick to beat the same
        // first-responder race the composer guards against.
        .onAppear {
            focused = true
            Task { @MainActor in focused = true }
        }
        #if os(macOS)
        // Escape cancels without saving (macOS/tvOS-only API; iOS dismisses the
        // popover by tapping away).
        .onExitCommand { isPresented = false }
        #endif
    }
}
