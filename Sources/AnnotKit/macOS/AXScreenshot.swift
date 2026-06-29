#if os(macOS)
import AppKit
import CoreGraphics

/// Element and window screenshots for the macOS adapter. The MVP uses
/// `cacheDisplay`, which is permission-free and works for on-screen and
/// off-screen windows (it renders material backers white). A ScreenCaptureKit
/// composited path, which captures materials correctly when Screen Recording
/// permission is granted, is a tracked enhancement (mirrors VirgilHUD's
/// `compositedPNG`). Main-actor isolated: all AppKit access runs on the main
/// thread, and only the `Sendable` ``CapturedImage`` is returned.
@MainActor
enum AXScreenshot {
    enum CaptureError: Error {
        case noRenderableWindow
        case emptyBitmap
    }

    /// Capture `element` (cropped to its frame) or the key window when nil.
    static func capture(of element: Element?) throws -> CapturedImage {
        guard let window = targetWindow(for: element) else {
            throw CaptureError.noRenderableWindow
        }
        let cropCocoa = element.map {
            ScreenSpace.cocoaRect(fromAXTopLeft: $0.frame, primaryHeight: primaryHeight())
        }
        guard let image = renderPNG(window: window, cropScreenRect: cropCocoa) else {
            throw CaptureError.emptyBitmap
        }
        return image
    }

    /// Render a window's content view (or a screen sub-rect) to PNG via
    /// `cacheDisplay`. `cropScreenRect` is a Cocoa (bottom-left) screen rect.
    static func renderPNG(window: NSWindow, cropScreenRect: CGRect?) -> CapturedImage? {
        guard let contentView = window.contentView else { return nil }
        let target: NSRect
        if let crop = cropScreenRect {
            let inWindow = window.convertFromScreen(crop)
            let inView = contentView.convert(inWindow, from: nil)
            let clamped = inView.intersection(contentView.bounds)
            target = (clamped.isNull || clamped.isEmpty) ? contentView.bounds : clamped
        } else {
            target = contentView.bounds
        }
        guard target.width >= 1, target.height >= 1 else { return nil }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: target) else { return nil }
        contentView.cacheDisplay(in: target, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return CapturedImage(pngData: data, pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
    }

    /// The window that owns an element (by frame), else the key window.
    private static func targetWindow(for element: Element?) -> NSWindow? {
        guard let element else {
            return NSApp.keyWindow ?? NSApp.windows.first
        }
        let axCenter = CGPoint(x: element.frame.midX, y: element.frame.midY)
        let cocoaCenter = ScreenSpace.flipPoint(axCenter, primaryHeight: primaryHeight())
        return NSApp.windows.first { $0.frame.contains(cocoaCenter) }
            ?? NSApp.keyWindow
            ?? NSApp.windows.first
    }

    private static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}
#endif
