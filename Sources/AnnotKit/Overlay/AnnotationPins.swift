import SwiftUI

/// Numbered comment pins (Feature 1), shared by the macOS and iOS overlay hosts.
///
/// Each captured note carries a window-local ``AnnotationNote/anchorRect`` — the
/// rect that was highlighted AT CAPTURE, minus the host window's `axOrigin` — and
/// the pin is centred on its ORIGIN, so a pin stays glued to where the note was
/// made when the host WINDOW moves (the panel is a child window, so a window-local
/// value is invariant under a window drag). It is FIXED, not live-tracked, with one
/// correction: a scroll the overlay itself drives translates the stored rects
/// (``AnnotationSession/translateNotes(by:within:)``), because while annotating the
/// overlay owns every wheel event and therefore knows exactly how far the content
/// moved. Scrolls it does not originate (keyboard paging, programmatic
/// `scrollToVisible`, anything while the menu is closed) are still not chased.
///
/// Pins are annotate-mode-only chrome, mounted in ``OverlayView`` ABOVE the
/// full-window catcher and BELOW the composer/toolbar, so each pin consumes its
/// own hover/click and can never fall through to re-select the element beneath it.
/// The whole overlay stays `accessibilityHidden`, so pins never disturb the AX
/// point query's see-through.
///
/// IN FRAME MODE THEY ARE INERT. Sitting above the catcher means a press that
/// starts on a pin never reaches the catcher's drag gesture — and every capture
/// plants one exactly where the user is most likely to draw the next frame, on the
/// thing they just annotated. That is the "I selected an element and now I can't
/// use the frame tool" report. In frame mode the user is drawing, not editing, and
/// the tool is an explicit choice ("the tool you picked is the outcome you get",
/// per ``SelectionGesture``), so one condition removes the collision with no
/// gesture negotiation — the thing `VRT-dp47` learned to stay away from.
///
/// Recall does NOT ride on the pin's own hover, and that is what makes going inert
/// affordable: a view with `allowsHitTesting(false)` receives no hover at all.
/// "Which note's pin is the pointer on?" is answered geometrically by
/// ``PinAttentionRule``, from the catcher's `onContinuousHover`, which covers the
/// whole surface and fires in BOTH modes.
struct AnnotationPins: View {
    @ObservedObject var session: AnnotationSession

    var body: some View {
        // Enumerate the FULL retained set so a pin's number matches the count
        // badge; notes captured without an anchor simply draw nothing.
        ForEach(Array(session.pending.enumerated()), id: \.element.id) { index, note in
            if let anchor = note.anchorRect?.origin {
                AnnotationPin(session: session, note: note, number: index + 1, anchor: anchor)
                    // Per PIN rather than on the `ForEach`: a modifier on the
                    // ForEach itself wraps the whole list in an implicit container,
                    // which is a layout change smuggled in behind a hit-testing one.
                    .allowsHitTesting(session.tool == .point)
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

    /// Also the geometry ``PinAttentionRule`` measures against. Shared through that
    /// rule rather than duplicated as a second literal, so the circle the user sees
    /// and the circle the recall tests describe cannot drift apart.
    private var diameter: CGFloat { PinAttentionRule.pinDiameter }

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
        // Open the editor on hover, but ONLY in POINT mode and ONLY when nothing
        // else is open. Two separate guards for two separate reasons, and the
        // distinction is what lets hover mean two things at once:
        //
        // * Opening the editor is STATEFUL — it steals focus and nils `selected` —
        //   so an incidental hover must never tear down an in-progress composer or
        //   another pin's edit (moving the mouse must not destroy typed text). An
        //   explicit tap (the Button above) can still open or switch at will.
        // * It is POINT-MODE-ONLY for the same reason the pin is inert there: in
        //   frame mode the card it drops under the pointer (~284x172) turns the
        //   neighbourhood of every pin into a no-drag zone the user enters just by
        //   moving the mouse.
        //
        // REVEALING the note's mark is neither: it is purely visual and
        // non-destructive, so it fires unconditionally — and from the catcher, not
        // from here (see ``PinAttentionRule``), which is why this handler is not
        // also the recall trigger.
        //
        // Do NOT close on hover-exit; the in-overlay edit card (rendered by
        // ``OverlayView``, above the pins) owns dismissal: Save / Delete / Escape /
        // click-away, routed through ``AnnotationSession/editingNoteID``.
        .onHover { inside in
            if inside, session.tool == .point, session.selected == nil, session.editingNoteID == nil {
                session.beginEditing(id: note.id)
            }
        }
        // The overlay ZStack is `.topLeading`, so centering the pin on the
        // element's top-left corner is `anchor - radius`.
        .offset(x: anchor.x - diameter / 2, y: anchor.y - diameter / 2)
    }
}
