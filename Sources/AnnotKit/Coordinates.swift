import CoreGraphics

/// Conversions between the Accessibility coordinate space (top-left origin,
/// y grows down) and the AppKit/Cocoa screen space (bottom-left origin, y grows
/// up). The overlay captures clicks in Cocoa coordinates; the AX point query
/// (`AXUIElementCopyElementAtPosition`) and AX frames are top-left, so the hover
/// loop needs the Cocoa-to-AX flip. Both spaces are in points, so there is no
/// HiDPI scaling here. Pure math, unit-tested, shared by both platform adapters.
public enum ScreenSpace {
    /// Flip a screen point between Cocoa (bottom-left) and AX (top-left). The
    /// transform is its own inverse for a point, so one function serves both
    /// directions. `primaryHeight` is the height of the primary display, the
    /// reference origin both spaces share.
    public static func flipPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Convert an AX (top-left) rect to a Cocoa (bottom-left) rect. Unlike a
    /// point flip this subtracts the height, because a rect's origin moves from
    /// the top edge to the bottom edge. Mirrors VirgilHUD's
    /// `cocoaScreenRect(fromAXTopLeft:)`.
    public static func cocoaRect(fromAXTopLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// Inverse of ``cocoaRect(fromAXTopLeft:primaryHeight:)``.
    public static func axTopLeftRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
