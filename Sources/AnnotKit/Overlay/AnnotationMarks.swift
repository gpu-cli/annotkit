import SwiftUI

/// The RECALLED mark: the geometry of the one note the user is currently asking
/// about, drawn back onto the surface.
///
/// Capturing a note leaves the surface exactly as it looked before marks existed —
/// the drawn frame goes away on send and nothing replaces it. "Maintained" here
/// means KEPT RECOVERABLE, not kept drawn, and the recovery gesture is resting the
/// pointer on the note's numbered pin (or opening its edit card). That single
/// constraint is what buys three problems away: no stack of overlapping rectangles
/// after five notes, no competition with the live highlight over what the next press
/// binds to, and no permanent field of stale geometry after a scroll.
///
/// AT MOST ONE MARK IS EVER ON SCREEN, by construction rather than by discipline:
/// the view renders ``AnnotationSession/attendedNote``, which is one note or none.
/// Deleting that note or clearing the set drops the mark for free, because the mark
/// is derived from `pending` on every read and never stored.
///
/// Mounted BELOW ``AnnotationPins`` and BELOW the highlight layer, and in the
/// CATCHER panel, so it appears when the menu opens and vanishes when it closes,
/// along with the pins — consistent with the "the menu is just open or closed"
/// model. What it draws is decided by ``RecalledMark``, a pure rule, so "hover
/// pin 3, see note 3's frame" is a unit test rather than something a human checks
/// with a mouse.
///
/// NOTHING HERE IS HIT-TESTABLE, unconditionally and per shape. A mark under the
/// pointer would sit between the pin and the catcher: it would steal the click that
/// should resolve to the element beneath, and — since the pointer is on it precisely
/// because it is being recalled — it could cancel the hover that summoned it and
/// flicker itself in and out. The pin is the note's handle; the mark is a picture.
///
/// COORDINATES: the note's rects are already WINDOW-LOCAL (snapshotted at capture
/// minus `axOrigin`), so they are offset DIRECTLY — no `axOrigin` subtraction,
/// unlike the live highlight, which arrives in AX screen space. Subtracting here
/// "for symmetry" would slide every mark off by the window's screen origin:
/// invisible on the primary display at the global origin, badly wrong on every
/// secondary one.
struct AnnotationMarks: View {
    @ObservedObject var session: AnnotationSession

    var body: some View {
        // An explicit top-leading stack filling the surface, NOT a bare multi-view
        // body. `OverlayView`'s ZStack is `.topLeading`, and its other layers get
        // that origin for free because they are inlined into it — `highlightLayer`
        // is a `@ViewBuilder` property, the pins are a `ForEach`. A view STRUCT is
        // one child of that stack, so its own body lays out in its own space, which
        // SwiftUI centres: every offset below would then be measured from the middle
        // of the window and the mark would be drawn half a window away from the pin
        // it belongs to. (Observed, once, as "the pins are there and nothing else
        // is" — invisible to every test that reads the model.)
        ZStack(alignment: .topLeading) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if let note = session.attendedNote, let mark = RecalledMark.resolve(note) {
            // The swept frame, when the note's binding has since moved off it
            // (Parent/Child). Drawn FIRST so it sits beneath the bound rect, and
            // much weaker, so "this is what the note records" cannot be misread as
            // "this is what the note binds to" — the same relationship live state 3
            // draws, because it is the same distinction.
            if let dimmed = mark.dimmedRect {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: dimmed.width, height: dimmed.height)
                    .offset(x: dimmed.minX, y: dimmed.minY)
                    .allowsHitTesting(false)
            }
            // The full committed-frame treatment, deliberately: only one mark is
            // ever up, so it can look like the selection it was made from instead
            // of the thin dimmed stroke an always-on layer would have needed to
            // stay legible when stacked.
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.12))
                .frame(width: mark.rect.width, height: mark.rect.height)
                .offset(x: mark.rect.minX, y: mark.rect.minY)
                .allowsHitTesting(false)
            if let name = mark.name {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .fixedSize()
                    // Just above the rect, or just inside its top when the rect
                    // hugs the window's top edge — the same rule the live name tag
                    // follows, so a recalled label sits where a live one would.
                    .offset(x: mark.rect.minX,
                            y: mark.rect.minY - 20 < 0 ? mark.rect.minY + 2 : mark.rect.minY - 20)
                    .allowsHitTesting(false)
            }
        }
    }
}
