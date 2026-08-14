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
/// IN FRAME MODE THE VIEW IS INERT — the view, not the pin. Sitting above the
/// catcher means a press that starts on a pin never reaches the catcher's drag
/// gesture, and every capture plants one exactly where the user is most likely to
/// draw the next frame, on the thing they just annotated. That is the "I selected
/// an element and now I can't use the frame tool" report. One condition removes the
/// collision with no gesture negotiation — the thing `VRT-dp47` learned to stay
/// away from.
///
/// WHAT THE PIN STILL DOES THERE is the correction `VRT-u209` made, and it is worth
/// separating from the sentence above because they were conflated for two releases.
/// Going hit-test-inert was only ever meant to stop a pin SWALLOWING A DRAG; it also
/// silently removed the only way to re-open a note, so a comment written with the
/// frame tool could be read and never edited. Measured, not assumed — the probe's
/// phase 11c presses a real pin in both tools and reported `editingNoteID=nil` in
/// frame mode, which is exactly the "I hover the numbers and nothing happens"
/// report. Both behaviours are now had at once, because neither the click nor the
/// recall rides on this view any more:
///
/// * **Click → edit** is resolved GEOMETRICALLY at the catcher's release, by
///   ``PinAttentionRule/pressedNote(atWindowPoint:in:)`` via ``SelectionGesture``,
///   gated on the press not having travelled. So a click on a pin edits it in BOTH
///   tools, and a drag from a pin still draws its frame.
/// * **Recall** ("which note's pin is the pointer on?") is answered the same way
///   from the catcher's `onContinuousHover`, which covers the whole surface and
///   fires in both tools.
///
/// The `Button` below is therefore a point-mode convenience that duplicates a route
/// that already works, not the mechanism — deliberately kept, because it is the one
/// path that answers a press on the pin's exact pixels without consulting geometry,
/// and it costs nothing to leave in agreement with the rule.
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
