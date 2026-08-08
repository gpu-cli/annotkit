import CoreGraphics

/// The pure part of the catcher's press→outcome decision: given the ACTIVE TOOL,
/// where a press began and where it ended, decide what the release resolves to and
/// produce the geometry for it.
///
/// This lives outside the SwiftUI closure for the same reason ``ComposerPlacement``
/// does — a decision buried in a gesture callback can only be checked by a human
/// with a mouse, and this particular decision is the one that silently breaks the
/// whole mode when it is wrong.
///
/// The tool, NOT the travel distance, picks the branch. An earlier design inferred
/// it: a short press was a click and a long one a frame, from the same gesture. That
/// made the outcome depend on how steady the user's hand was, and the failure was
/// silent — a 12-point wobble on a click planted a framed note bound to whatever
/// container happened to be under the sweep. Travel now only answers a much smaller
/// question, asked ONLY inside frame mode: was this a real drag?
///
/// The two modes are strictly separated:
///
/// * **Point mode always yields a point**, no matter how far the press travelled.
///   A drag in point mode is a sloppy click, not a frame; there is no press that
///   does nothing in the default mode, because a dead click reads as a broken tool.
/// * **Frame mode below the threshold yields NOTHING.** That is the user's explicit
///   choice — the tool you picked is the outcome you get — and it also absorbs the
///   jitter case for free. A 3-point wobble is not zero-area, so nothing downstream
///   rejects it: ``AnnotationSession/select(inAXRect:)`` would resolve it happily
///   onto whatever container the pointer sat in and produce a plausible-looking note
///   bound to something the user never framed. A wrong note is more expensive than
///   no note, because nobody goes back to check it. In frame mode the crosshair
///   cursor is what tells the user a click alone will not do anything.
///
/// Travel is measured as the hypotenuse, not per-axis: a 5-point-right,
/// 5-point-down drift is ~7 points of real movement and reads as intentional, while
/// a per-axis test would call it a click on both axes.
///
/// Touch needs more slop than a cursor because a finger rolls several points on a
/// deliberate tap — a mouse-tuned threshold on iOS would make ordinary frame-mode
/// taps register as tiny accidental frames.
enum SelectionGesture {
    /// What a completed press resolves to. All coordinates are AX SCREEN space
    /// (window-local gesture coordinates already shifted by `axOrigin`), so the
    /// caller hands the payload straight to the session with no further transform
    /// — the transform living in one place is why the click path, the frame path
    /// and the highlight agree on a secondary display.
    enum Outcome: Equatable {
        case point(CGPoint)
        case frame(CGRect)
        case none
    }

    /// Travel a press must EXCEED, IN FRAME MODE ONLY, before it counts as a real
    /// drag rather than a stray click. Exactly at the threshold is NOT a frame: the
    /// boundary belongs to the branch that does nothing, since a doubtful frame
    /// plants a note nobody asked for whereas a rejected one costs a second drag.
    #if os(iOS)
    static let minimumTravel: CGFloat = 10
    #else
    static let minimumTravel: CGFloat = 6
    #endif

    /// Route a completed press. The one place the mode semantics live, so they are
    /// pinned by tests rather than by a human dragging a mouse.
    static func resolve(
        tool: AnnotationSession.SelectionTool,
        from start: CGPoint,
        to end: CGPoint,
        axOrigin: CGPoint
    ) -> Outcome {
        switch tool {
        case .point:
            // `startLocation`, not `location`: it is where the user AIMED, and it is
            // deterministic for a press that drifted under the finger/cursor — the
            // release point of a sloppy click can easily sit on the neighbouring
            // control.
            return .point(CGPoint(x: start.x + axOrigin.x, y: start.y + axOrigin.y))
        case .frame:
            guard travelledFarEnough(from: start, to: end) else { return .none }
            return .frame(axRect(from: start, to: end, axOrigin: axOrigin))
        }
    }

    /// True when the press travelled far enough, in frame mode, to be a deliberate
    /// drag. Also gates the drawn band, so the rubber band never appears for a press
    /// the release is going to discard.
    static func travelledFarEnough(from start: CGPoint, to end: CGPoint) -> Bool {
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
