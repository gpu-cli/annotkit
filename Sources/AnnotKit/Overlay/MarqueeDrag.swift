import CoreGraphics

/// The pure part of the marquee gesture: given where a press began and where the
/// pointer is now, decide whether it is a FRAME or a CLICK and produce the
/// geometry for whichever it is.
///
/// This lives outside the SwiftUI closure for the same reason ``ComposerPlacement``
/// does — a decision buried in a gesture callback can only be checked by a human
/// with a mouse, and this particular decision is the one that silently breaks the
/// whole mode when it is wrong.
///
/// Why the threshold is the load-bearing part:
///
/// * A press that never moved is a CLICK and must go to
///   ``AnnotationSession/select(atAXPoint:)``. ``AnnotationSession/select(inAXRect:)``
///   returns nil for a zero-area rect (deliberately — see its CALLER CONTRACT), so
///   routing a click into the marquee path makes clicking do NOTHING in annotate
///   mode. That reads as a dead feature, not as a missing constant.
/// * A 3-point jitter-drag is the worse failure, because it is NOT zero-area: the
///   rule resolves it happily and lands on whatever container the pointer happened
///   to sit in, producing a plausible-looking note bound to something the user
///   never framed. A wrong note is more expensive than no note, because nobody
///   goes back to check it.
///
/// Travel is measured as the hypotenuse, not per-axis: a 5-point-right,
/// 5-point-down drift is ~7 points of real movement and reads as intentional, while
/// a per-axis test would call it a click on both axes.
///
/// Touch needs more slop than a cursor because a finger rolls several points on a
/// deliberate tap — a mouse-tuned threshold on iOS turns ordinary taps into
/// accidental marquees.
enum MarqueeDrag {
    /// Travel a press must EXCEED before it counts as a frame rather than a click.
    /// Exactly at the threshold is still a click: the boundary belongs to the
    /// safer branch, since a click misread as a frame plants a wrong note whereas
    /// a frame misread as a click just selects what is under the press.
    #if os(iOS)
    static let minimumTravel: CGFloat = 10
    #else
    static let minimumTravel: CGFloat = 6
    #endif

    /// True when the press travelled far enough to be a deliberate frame.
    static func isFrame(from start: CGPoint, to end: CGPoint) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot() > minimumTravel
    }

    /// Window-local rect, normalized so any drag direction gives the same result.
    /// Users drag up-left as readily as down-right; without `standardized` the
    /// three "backwards" directions produce negative extents, which the session's
    /// degenerate guard would treat as a non-drag.
    static func localRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
            .standardized
    }

    /// AX screen rect: the window-local rect shifted by the surface's AX origin.
    /// Gesture coordinates are window-local, and the AX queries behind
    /// ``AnnotationSession/select(inAXRect:)`` are in AX screen space — the same
    /// ADD-to-query / SUBTRACT-to-draw transform the click path and the highlight
    /// share, which is why all of them agree on a secondary display.
    static func axRect(from start: CGPoint, to end: CGPoint, axOrigin: CGPoint) -> CGRect {
        localRect(from: start, to: end).offsetBy(dx: axOrigin.x, dy: axOrigin.y)
    }
}
