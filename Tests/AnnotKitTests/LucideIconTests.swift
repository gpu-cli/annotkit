import CoreGraphics
import SwiftUI
import XCTest
@testable import AnnotKit

/// The pill's glyphs are hand-ported Lucide primitives + a tiny `d`-string
/// parser, so these guard that every icon still renders a real, in-bounds path
/// (a parser regression that silently emptied a glyph would slip past the
/// off-screen probe otherwise).
final class LucideIconTests: XCTestCase {
    private let grid = CGRect(x: 0, y: 0, width: 24, height: 24)

    private let icons: [(name: String, icon: LucideIcon)] = [
        ("crosshair", .crosshair),
        ("pause", .pause),
        ("check", .check),
        ("copy", .copy),
        ("trash", .trash),
        ("close", .close),
    ]

    func testEachIconRendersNonEmptyPath() {
        for (name, icon) in icons {
            let path = LucideShape(parts: icon.parts).path(in: grid)
            XCTAssertFalse(path.isEmpty, "\(name) produced an empty path")
        }
    }

    func testEachIconStaysWithinTheDesignGrid() {
        for (name, icon) in icons {
            let bounds = LucideShape(parts: icon.parts).path(in: grid).boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minX, -0.5, "\(name) spills off the left")
            XCTAssertGreaterThanOrEqual(bounds.minY, -0.5, "\(name) spills off the top")
            XCTAssertLessThanOrEqual(bounds.maxX, 24.5, "\(name) spills off the right")
            XCTAssertLessThanOrEqual(bounds.maxY, 24.5, "\(name) spills off the bottom")
        }
    }

    func testRelativeMoveAndLineResolveAgainstCurrentPoint() {
        // "M6 6l12 12" = absolute move to (6,6) then a relative line ending at
        // (18,18) — exercises the parser's relative-command handling.
        let bounds = LucideShape(parts: [.path("M6 6l12 12")]).path(in: grid).boundingRect
        XCTAssertEqual(bounds.minX, 6, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 6, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 18, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 18, accuracy: 0.01)
    }

    func testImplicitLinetoAfterMove() {
        // "M20 6 9 17l-5-5": the second coord pair is an implicit lineto and
        // "-5-5" tokenizes into two negative numbers -> ends at (4,12).
        let bounds = LucideShape(parts: [.path("M20 6 9 17l-5-5")]).path(in: grid).boundingRect
        XCTAssertEqual(bounds.minX, 4, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 6, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 20, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 17, accuracy: 0.01)
    }

    func testScalesToTheRenderRect() {
        // At half size the same glyph must occupy half the grid.
        let bounds = LucideShape(parts: LucideIcon.close.parts)
            .path(in: CGRect(x: 0, y: 0, width: 12, height: 12))
            .boundingRect
        XCTAssertEqual(bounds.minX, 3, accuracy: 0.01)  // 6 * (12/24)
        XCTAssertEqual(bounds.maxX, 9, accuracy: 0.01)  // 18 * (12/24)
    }

    func testHexColorFallsBackToClearOnBadInput() {
        // Valid input yields an opaque (non-clear) color; malformed input must
        // fall back to clear rather than crash a host.
        XCTAssertEqual(Color(hex: "nope"), Color.clear)
        XCTAssertEqual(Color(hex: "12345"), Color.clear) // wrong length
        XCTAssertNotEqual(Color(hex: "1A1A1A"), Color.clear)
        XCTAssertNotEqual(Color(hex: "#EF4444"), Color.clear)
    }
}
