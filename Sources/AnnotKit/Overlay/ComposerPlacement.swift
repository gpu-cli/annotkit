import CoreGraphics

/// Where to put the note composer relative to the selected element, expressed in
/// the overlay's window-local space (top-left origin, y grows down — the same
/// space the highlight and the `.offset` chrome live in).
///
/// Pure geometry, so it is unit-tested without SwiftUI. The catcher feeds the AX
/// point query by ADDING the host window's `axOrigin`; everything drawn on the
/// overlay (highlight, composer, caret) SUBTRACTS it. Sharing that one transform
/// is why the click, the highlight, and the composer agree by construction on any
/// display, and why the primary-at-origin case (`axOrigin == .zero`) is a no-op.
///
/// The card is placed adjacent to the element — below it by default, flipped
/// above when it would spill off the bottom — and always fully clamped inside the
/// surface. A caret (small pointer) ties the card back to the element: it points
/// up toward the element when the card is below, down when the card is flipped
/// above, and slides horizontally to line up with the element's center.
struct ComposerPlacement: Equatable {
    /// Card top-left in window-local space; feed straight into `.offset`.
    var origin: CGPoint
    /// Caret points up (card below the element) vs down (card flipped above it).
    var caretPointsUp: Bool
    /// Horizontal caret offset from the card's center, aligning it with the
    /// element's horizontal center and clamped so it never rides a rounded corner.
    var caretDX: CGFloat

    /// Resolve placement for a selected element.
    /// - Parameters:
    ///   - elementFrame: the element's frame in AX-screen coordinates.
    ///   - axOrigin: AX top-left origin of the host window (subtracted to reach
    ///     window-local space; see ``ScreenSpace/windowAXOrigin(cocoaFrame:primaryHeight:)``).
    ///   - surfaceSize: window-local surface size, used to clamp the card fully
    ///     on-screen.
    ///   - composerSize: estimated card size, for the clamp and the flip decision.
    ///   - gap: spacing between the element and the card (and the surface edge).
    ///   - caretCornerInset: how far the caret must stay from the card's side
    ///     edges so it never overlaps a rounded corner.
    static func resolve(
        elementFrame: CGRect,
        axOrigin: CGPoint,
        surfaceSize: CGSize,
        composerSize: CGSize,
        gap: CGFloat = 8,
        caretCornerInset: CGFloat = 18
    ) -> ComposerPlacement {
        // Element in window-local (y-down) space.
        let ex = elementFrame.minX - axOrigin.x
        let ey = elementFrame.minY - axOrigin.y
        let elementCenterX = ex + elementFrame.width / 2

        // Horizontal: left-align with the element, clamped so the whole card fits.
        let maxX = max(gap, surfaceSize.width - composerSize.width - gap)
        let x = min(max(gap, ex), maxX)

        // Vertical: below the element by default; flip above when it would spill
        // off the bottom (the diagnosis's window-selected (640,790) off-screen
        // spill). Then clamp the top on-screen.
        var caretPointsUp = true
        var y = ey + elementFrame.height + gap
        if y + composerSize.height > surfaceSize.height - gap {
            y = ey - composerSize.height - gap
            caretPointsUp = false
        }
        y = max(gap, y)

        // Caret: align with the element center, clamped within the card.
        let cardCenterX = x + composerSize.width / 2
        let caretLimit = max(0, composerSize.width / 2 - caretCornerInset)
        let caretDX = min(max(-caretLimit, elementCenterX - cardCenterX), caretLimit)

        return ComposerPlacement(
            origin: CGPoint(x: x, y: y),
            caretPointsUp: caretPointsUp,
            caretDX: caretDX
        )
    }
}
