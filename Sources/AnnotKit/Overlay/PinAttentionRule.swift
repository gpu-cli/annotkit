import CoreGraphics

/// "Which captured note is the pointer attending to?" — answered from geometry
/// alone, so recalling a note's mark never depends on a view receiving hover.
///
/// This lives outside the SwiftUI closure for the same reason ``SelectionGesture``,
/// ``EscapeRule`` and ``MarqueeTargetRule`` do: a decision buried in a gesture
/// callback can only be checked by a human with a mouse, and "hovering pin 3 shows
/// note 3's frame" is exactly the kind of claim that should be a unit test.
///
/// WHY NOT THE PIN'S OWN `onHover`. ``AnnotationPins`` goes inert in frame mode so
/// a press starting on a pin reaches the catcher's drag gesture instead of being
/// swallowed by a button — and a view with `allowsHitTesting(false)` receives no
/// hover either. Making recall geometric pays for itself three times over: the pins
/// can go fully inert without losing recall, there is ONE mechanism in both modes
/// rather than two that can drift, and the mapping becomes testable without a
/// window. The pin stays a `Button` in point mode for click-to-edit; it just stops
/// being the source of the hover signal.
///
/// COST. A point-in-circle test per retained note per pointer-motion event, with no
/// AX query anywhere — which is why, unlike ``AnnotationSession/hover(atAXPoint:)``,
/// this needs no throttle. The session still refuses to re-publish an unchanged
/// answer, so a pointer crossing empty space emits nothing at all.
enum PinAttentionRule {
    /// The pin's drawn diameter, and therefore the geometry this rule measures
    /// against. ``AnnotationPins`` reads it from here so the circle the user sees
    /// and the circle this rule describes are one number.
    static let pinDiameter: CGFloat = 20

    /// How close the pointer must come to a pin's centre to attend it.
    ///
    /// DELIBERATELY LARGER THAN THE PIN, and not as a comfort target. In point mode
    /// the pin is a live `Button` sitting above the catcher, so the moment the
    /// pointer crosses onto it the catcher's hover ENDS and this rule stops being
    /// evaluated: a radius equal to the pin's own would mean the only points that
    /// could ever attend it are the points the catcher never sees, and recall would
    /// never fire in the default mode. An annulus outside the pin is what the
    /// catcher does see, so attention is established on the way IN — and because the
    /// last answer stands until another point produces a different one, it survives
    /// the crossing and lasts exactly as long as the pointer is on the pin.
    ///
    /// It is also why hover-exit needs no rule of its own: a pointer leaving the
    /// window from empty space has already set the answer to nil on its way out.
    static let attentionRadius: CGFloat = pinDiameter

    /// The id of the note whose pin the pointer at `point` (WINDOW-LOCAL, the space
    /// ``AnnotationNote/anchorRect`` is stored in) is attending, or nil for a point
    /// near no pin.
    ///
    /// LAST NOTE WINS on overlap, because pins are drawn in `pending` order and a
    /// later one is therefore painted ON TOP of an earlier one. The user can only
    /// mean the pin they can see.
    static func attendedNote(atWindowPoint point: CGPoint, in notes: [AnnotationNote]) -> String? {
        for note in notes.reversed() {
            guard let anchor = note.anchorRect?.origin else { continue }
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            if dx * dx + dy * dy <= attentionRadius * attentionRadius { return note.id }
        }
        return nil
    }
}

/// The shape of a RECALLED mark: what to draw when the user asks "what was note 3
/// about?" by resting the pointer on its pin.
///
/// A fifth state BENEATH ``OverlayView``'s four-state highlight ladder, and
/// mutually exclusive with none of them — that ladder answers "what does the next
/// press bind to", which is a live question asked continuously, while this answers
/// a different one, asked deliberately, one note at a time. Because at most one
/// mark is ever on screen it can afford the full committed-frame treatment the live
/// selection uses (solid stroke plus the wash) rather than the thin dimmed strokes
/// an always-on layer would have needed to stay legible when stacked: a recalled
/// note should look like the selection it was made from.
///
/// The three cases mirror the live ladder rung for rung, which is the point — the
/// user is being shown the same picture they filed the note against:
///
/// * **Area note** — the rect the user swept, solid and with NO name tag, exactly
///   like live state 2 (the committed frame). Recognized by the two rects AGREEING:
///   a framed selection anchors to the frame it drew, so `anchorRect == drawnRect`
///   until something moves the binding off it.
/// * **Element note** — the anchor rect, solid, WITH the name tag. Live state 4
///   names the element for the same reason, and here (unlike an always-on layer)
///   there is exactly one mark, so there is no ambiguity about what the tag labels.
/// * **Navigated framed note** — the anchor rect (the element the note is actually
///   filed against) named, with the drawn rect dimmed beneath it, mirroring live
///   state 3. This is the one case where the note's binding and the user's gesture
///   disagree, and a deliberate hover is precisely when they want to see both.
struct RecalledMark: Equatable {
    /// The rect drawn SOLID: what the note is filed against.
    let rect: CGRect
    /// The swept rect drawn DIMMED beneath it, when the binding has moved off it;
    /// nil whenever that would just stack a second stroke on the same edge.
    let dimmedRect: CGRect?
    /// The name tag's text, or nil for a committed frame — whose binding is named
    /// nowhere on the canvas by design, so that a tag cannot read as a label for
    /// the rectangle the user drew.
    let name: String?

    /// Resolve a captured note into the mark to draw, or nil for a note with no
    /// recorded geometry (one decoded from disk, where the rects are deliberately
    /// not persisted).
    static func resolve(_ note: AnnotationNote) -> RecalledMark? {
        guard let anchor = note.anchorRect else { return nil }
        // Exact equality, no epsilon: both rects are copies of the SAME CGRect when
        // a frame selection anchors to what it drew, so the comparison is
        // bit-identical by construction — the same test ``OverlayView``'s live
        // state 3 already makes against `selected.frame`.
        if let drawn = note.drawnRect, drawn == anchor {
            return RecalledMark(rect: drawn, dimmedRect: nil, name: nil)
        }
        return RecalledMark(rect: anchor, dimmedRect: note.drawnRect, name: name(of: note))
    }

    /// The label for an element note's tag. The live highlight prefers the seeded
    /// identifier, then the label, then the displayed text, then the role; a
    /// captured note has no ``Element`` left, so this reads the frozen equivalents
    /// in the same order.
    ///
    /// ``AnnotationNote/component`` is used ONLY when the note's own target was
    /// seeded (`unseeded == false`): for an unseeded target it holds an ANCESTOR's
    /// identifier, and labelling a small element with the name of the card around
    /// it would say the note binds to something it does not.
    private static func name(of note: AnnotationNote) -> String {
        if note.unseeded == false, let component = note.component, !component.isEmpty { return component }
        if let text = note.elementText, !text.isEmpty { return String(text.prefix(40)) }
        if let role = note.elementRole, !role.isEmpty { return role }
        return note.selector
    }
}
