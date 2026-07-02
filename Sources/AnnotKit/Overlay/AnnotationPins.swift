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

    private let diameter: CGFloat = 20

    var body: some View {
        Button {
            session.beginEditing(id: note.id)
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
        // Open the editor on hover, but ONLY when nothing else is open, so an
        // incidental hover over a pin never tears down an in-progress composer or
        // another pin's edit (moving the mouse must not destroy typed text). An
        // explicit tap (the Button above) can still open or switch at will. Do NOT
        // close on hover-exit; the in-overlay edit card (rendered by
        // ``OverlayView``, above the pins) owns dismissal: Save / Delete / Escape /
        // click-away, routed through ``AnnotationSession/editingNoteID``.
        .onHover { inside in
            if inside, session.selected == nil, session.editingNoteID == nil {
                session.beginEditing(id: note.id)
            }
        }
        // The overlay ZStack is `.topLeading`, so centering the pin on the
        // element's top-left corner is `anchor - radius`.
        .offset(x: anchor.x - diameter / 2, y: anchor.y - diameter / 2)
    }
}
