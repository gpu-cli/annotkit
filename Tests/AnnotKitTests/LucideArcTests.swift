import CoreGraphics
import SwiftUI
import XCTest
@testable import AnnotKit

/// Geometry tests for the `d`-parser's elliptical-arc support (SVG 1.1 F.6.5).
///
/// These assert on points sampled ALONG the emitted curves rather than on
/// `Path.boundingRect`, because a Bézier's bounding rect is allowed to include
/// control points — a bulge assertion made against it could pass on a path whose
/// drawn curve never goes there. Sampling also makes every failure here a real
/// visual failure: the old straight-line arc handling reproduces the same
/// endpoints and often the same bounding box, and is only distinguishable by
/// where the stroke actually travels.
final class LucideArcTests: XCTestCase {
    private let grid = CGRect(x: 0, y: 0, width: 24, height: 24)

    // MARK: Sampling helpers

    /// Flatten a path into points on the drawn curve (endpoints plus interior
    /// samples of every line/quad/cubic).
    private func samples(_ d: String, per: Int = 24) -> [CGPoint] {
        let path = LucideShape(parts: [.path(d)]).path(in: grid)
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var subStart = CGPoint.zero

        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            return CGPoint(x: x, y: y)
        }

        path.forEach { element in
            switch element {
            case .move(let to):
                current = to
                subStart = to
                points.append(to)
            case .line(let to):
                for step in 1...per { points.append(lerp(current, to, CGFloat(step) / CGFloat(per))) }
                current = to
            case .quadCurve(let to, let control):
                // Promote to a cubic so one evaluator covers both.
                let c1 = lerp(current, control, 2.0 / 3.0)
                let c2 = lerp(to, control, 2.0 / 3.0)
                for step in 1...per {
                    points.append(cubic(current, c1, c2, to, CGFloat(step) / CGFloat(per)))
                }
                current = to
            case .curve(let to, let control1, let control2):
                for step in 1...per {
                    points.append(cubic(current, control1, control2, to, CGFloat(step) / CGFloat(per)))
                }
                current = to
            case .closeSubpath:
                for step in 1...per { points.append(lerp(current, subStart, CGFloat(step) / CGFloat(per))) }
                current = subStart
            }
        }
        return points
    }

    /// Tight bounding box of the DRAWN curve (control points excluded).
    private func drawnBounds(_ d: String) -> CGRect {
        let points = samples(d)
        guard let first = points.first else { return .null }
        var box = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        return box
    }

    /// The `d` strings of a SHIPPED glyph, so a test can assert on the icon the UI
    /// actually draws rather than on a copy of its path retyped into the test.
    private func pathData(_ icon: LucideIcon) -> [String] {
        var strings: [String] = []
        for case .path(let d) in icon.parts { strings.append(d) }
        return strings
    }

    private func distanceToCurve(_ d: String, _ target: CGPoint) -> CGFloat {
        samples(d, per: 64).map { hypot($0.x - target.x, $0.y - target.y) }.min() ?? .infinity
    }

    private func assertBounds(
        _ d: String, _ expected: CGRect, accuracy: CGFloat = 0.02,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let box = drawnBounds(d)
        XCTAssertEqual(box.minX, expected.minX, accuracy: accuracy, "minX \(message)", file: file, line: line)
        XCTAssertEqual(box.minY, expected.minY, accuracy: accuracy, "minY \(message)", file: file, line: line)
        XCTAssertEqual(box.maxX, expected.maxX, accuracy: accuracy, "maxX \(message)", file: file, line: line)
        XCTAssertEqual(box.maxY, expected.maxY, accuracy: accuracy, "maxY \(message)", file: file, line: line)
    }

    // MARK: The regression that motivated arc support

    /// Lucide `undo-2`'s loop is a 5.5-radius semicircle written as a single `a`
    /// whose endpoint sits DIRECTLY BELOW its start. A straight line to that
    /// endpoint has zero width — the curl vanishes and the glyph stops reading as
    /// "undo" — so this pins the loop's full 5.5-unit bulge.
    func testSemicircleLoopBulgesTheFullRadius() {
        let box = drawnBounds("M14.5 9a5.5 5.5 0 0 1 0 11")
        XCTAssertEqual(box.width, 5.5, accuracy: 0.02, "the loop collapsed to a straight segment")
        XCTAssertEqual(box.minX, 14.5, accuracy: 0.02)
        XCTAssertEqual(box.maxX, 20, accuracy: 0.02)
        XCTAssertEqual(box.minY, 9, accuracy: 0.02)
        XCTAssertEqual(box.maxY, 20, accuracy: 0.02)
        // The extreme of the loop, a quarter turn in: dead centre of the bulge.
        XCTAssertLessThan(distanceToCurve("M14.5 9a5.5 5.5 0 0 1 0 11", CGPoint(x: 20, y: 14.5)), 0.02)
    }

    /// The same loop as Lucide actually authors it — two chained quarter arcs, so
    /// the flattened form is a triangle rather than a line and the bounding box
    /// alone would NOT catch the regression. The 45-degree points are what
    /// separates a real curve from its chords.
    func testUndoStyleTwoArcLoopFollowsTheCircle() {
        let d = "M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"
        let box = drawnBounds(d)
        XCTAssertEqual(box.maxX, 20, accuracy: 0.02)
        XCTAssertEqual(box.maxY, 20, accuracy: 0.02)
        // Centre (14.5, 14.5), radius 5.5: the two 45-degree points sit ~1.1 units
        // outside the chords a line approximation would draw.
        let offset: CGFloat = 5.5 / CGFloat(2).squareRoot()
        XCTAssertLessThan(distanceToCurve(d, CGPoint(x: 14.5 + offset, y: 14.5 - offset)), 0.02)
        XCTAssertLessThan(distanceToCurve(d, CGPoint(x: 14.5 + offset, y: 14.5 + offset)), 0.02)
    }

    // MARK: Basic sweeps

    func testQuarterCircleSpansItsRadiiAndBulges() {
        let d = "M0 0 A10 10 0 0 1 10 10"
        assertBounds(d, CGRect(x: 0, y: 0, width: 10, height: 10), "quarter circle")
        // Centre (0,10): the mid-sweep point is at 45 degrees, 2.93 units off the
        // chord. A straight line shares this bounding box, so the chord distance —
        // not the box — is the assertion that has teeth.
        let radial: CGFloat = 10 / CGFloat(2).squareRoot()
        let mid = CGPoint(x: radial, y: 10 - radial)
        XCTAssertLessThan(distanceToCurve(d, mid), 0.02)
        XCTAssertGreaterThan(distanceToCurve(d, CGPoint(x: 5, y: 5)), 2.9, "curve hugged the chord")
        XCTAssertEqual(samples(d).last!.x, 10, accuracy: 0.0001)
        XCTAssertEqual(samples(d).last!.y, 10, accuracy: 0.0001)
    }

    func testHalfCircleBulgesToTheFullRadiusOnTheSweptSide() {
        // Start (5,4) -> end (5,14), r=5: a semicircle bulging right for sweep=1.
        assertBounds("M5 4 A5 5 0 0 1 5 14", CGRect(x: 5, y: 4, width: 5, height: 10), "sweep=1 half")
        // sweep=0 mirrors it to the left of the chord.
        assertBounds("M5 4 A5 5 0 0 0 5 14", CGRect(x: 0, y: 4, width: 5, height: 10), "sweep=0 half")
    }

    // MARK: Flags

    /// All four flag combinations from one pair of endpoints. Two centres times
    /// two directions: minor arcs stay inside the chord's half-plane, major arcs
    /// wrap past both poles.
    func testAllFourLargeArcSweepCombinationsDiffer() {
        let paths = [
            "M5 10 A6 6 0 0 0 15 10", // minor, counter-sweep -> below the chord
            "M5 10 A6 6 0 0 1 15 10", // minor, sweep -> above the chord
            "M5 10 A6 6 0 1 0 15 10", // major, counter-sweep -> wraps below
            "M5 10 A6 6 0 1 1 15 10", // major, sweep -> wraps above
        ]
        let boxes = paths.map { drawnBounds($0) }

        for i in boxes.indices {
            for j in boxes.indices where j > i {
                XCTAssertNotEqual(boxes[i], boxes[j], "flag combination \(i) and \(j) drew the same arc")
            }
        }

        // Centres are (10, 6.683) and (10, 13.317); half-height of the bulge is
        // 6 - 3.317 = 2.683 for the minor arcs, 6 + 3.317 = 9.317 for the major.
        XCTAssertEqual(boxes[0].minY, 10, accuracy: 0.02, "minor sweep=0 must not cross above the chord")
        XCTAssertEqual(boxes[0].maxY, 12.683, accuracy: 0.02)
        XCTAssertEqual(boxes[1].maxY, 10, accuracy: 0.02, "minor sweep=1 must not cross below the chord")
        XCTAssertEqual(boxes[1].minY, 7.317, accuracy: 0.02)
        XCTAssertEqual(boxes[2].maxY, 19.317, accuracy: 0.02, "major sweep=0 must wrap the far pole")
        XCTAssertEqual(boxes[3].minY, 0.683, accuracy: 0.02, "major sweep=1 must wrap the far pole")
        // Both major arcs pass the ellipse's left and right extremes.
        XCTAssertEqual(boxes[2].minX, 4, accuracy: 0.02)
        XCTAssertEqual(boxes[3].maxX, 16, accuracy: 0.02)
    }

    // MARK: Rotation

    func testXAxisRotationReshapesTheEllipse() {
        let upright = drawnBounds("M4 12 A8 3 0 0 1 20 12")
        let rotated = drawnBounds("M4 12 A8 3 45 0 1 20 12")
        XCTAssertNotEqual(upright, rotated, "x-axis-rotation was ignored")
        // Upright: the top half of an 8x3 ellipse centred on the chord, so it rises
        // exactly ry above the chord and stays inside the endpoints in x.
        XCTAssertEqual(upright.minX, 4, accuracy: 0.02)
        XCTAssertEqual(upright.minY, 9, accuracy: 0.02)
        XCTAssertEqual(upright.maxY, 12, accuracy: 0.02)
        // Rotated 45 degrees the arc leans: it climbs far past the chord's own
        // y-range and reaches left of the start point. Rotating the RESULT (or a
        // bounding box) instead of the ellipse frame cannot produce this.
        XCTAssertEqual(rotated.minX, -0.167, accuracy: 0.02)
        XCTAssertEqual(rotated.minY, -0.167, accuracy: 0.02)
        XCTAssertEqual(rotated.maxX, 20, accuracy: 0.02)
    }

    /// The strongest rotation check available without a second implementation:
    /// half an ellipse whose endpoints are the two ends of its major axis, so the
    /// centre is the chord midpoint and every point on the curve — control points
    /// included, since they are what shapes the samples — must satisfy the
    /// rotated ellipse equation.
    func testRotatedEllipseSamplesSatisfyTheEllipseEquation() {
        // Centre (10,10), rx 10, ry 5, phi 30 degrees.
        let phi = CGFloat.pi / 6
        let d = "M1.339746 5 A10 5 30 0 1 18.660254 15"
        let points = samples(d, per: 40)
        XCTAssertGreaterThan(points.count, 40)
        for point in points {
            let dx = point.x - 10, dy = point.y - 10
            let x = cos(phi) * dx + sin(phi) * dy
            let y = -sin(phi) * dx + cos(phi) * dy
            XCTAssertEqual(x * x / 100 + y * y / 25, 1, accuracy: 0.01, "point \(point) is off the ellipse")
        }
    }

    /// Rotating an ellipse by 90 degrees is the same shape as swapping its radii.
    /// An implementation that rotated only the endpoints, or applied phi to the
    /// control points inconsistently, breaks this identity.
    func testNinetyDegreeRotationEqualsSwappedRadii() {
        let rotated = samples("M2 3 A10 5 90 0 1 14 9", per: 40)
        let swapped = samples("M2 3 A5 10 0 0 1 14 9", per: 40)
        XCTAssertEqual(rotated.count, swapped.count)
        for (a, b) in zip(rotated, swapped) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
        }
    }

    func testRotationOfACircleIsANoOp() {
        // A circle is rotation-invariant; if phi leaked into the radii instead of
        // the frame, these would diverge.
        assertBounds("M0 0 A10 10 0 0 1 10 10", CGRect(x: 0, y: 0, width: 10, height: 10))
        assertBounds("M0 0 A10 10 37 0 1 10 10", CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: Degenerate input (F.6.2 / F.6.6)

    func testZeroRadiusDegradesToAStraightLine() {
        let d = "M2 2 A0 0 0 0 1 10 10"
        assertBounds(d, CGRect(x: 2, y: 2, width: 8, height: 8))
        // Every sample sits on the chord: y == x for this segment.
        for point in samples(d) {
            XCTAssertEqual(point.y, point.x, accuracy: 0.0001, "zero-radius arc left the straight line")
        }
    }

    func testCoincidentEndpointsDrawNothing() {
        // F.6.2: an arc whose endpoints coincide is omitted entirely. The move is
        // still recorded, so the path is a single point, not a stray loop.
        let box = drawnBounds("M6 6 A4 4 0 1 1 6 6")
        XCTAssertEqual(box.width, 0, accuracy: 0.0001)
        XCTAssertEqual(box.height, 0, accuracy: 0.0001)
    }

    func testNegativeRadiiUseTheirAbsoluteValue() {
        assertBounds("M0 0 A-10 -10 0 0 1 10 10", CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    /// F.6.6.2: radii too small to span the endpoints are scaled up, so the arc
    /// still LANDS on its endpoint. Falling back to "closest reachable" would
    /// leave a visible gap before the next command.
    func testTooSmallRadiiScaleUpAndStillReachTheEndpoint() {
        let d = "M0 0 A1 1 0 0 1 10 10"
        let end = samples(d).last!
        XCTAssertEqual(end.x, 10, accuracy: 0.0001)
        XCTAssertEqual(end.y, 10, accuracy: 0.0001)
        // Scaled to r = 7.0711 the arc is a half circle centred on the chord's
        // midpoint (5,5), so it sweeps through the circle's top and right extremes
        // — well outside the endpoints' own 10x10 box.
        let radius: CGFloat = 5 * CGFloat(2).squareRoot()
        assertBounds(d, CGRect(x: 0, y: 5 - radius, width: 5 + radius, height: 5 + radius))
        XCTAssertLessThan(distanceToCurve(d, CGPoint(x: 10, y: 0)), 0.02)
    }

    // MARK: Parser contract

    func testRelativeArcResolvesAgainstTheCurrentPoint() {
        // Same circle authored absolutely and relatively.
        XCTAssertEqual(drawnBounds("M5 4 A5 5 0 0 1 5 14"), drawnBounds("M5 4 a5 5 0 0 1 0 10"))
    }

    func testArcLeavesTheCurrentPointForTheNextCommand() {
        // The command after the arc must start from the arc's endpoint, not from
        // where the arc began.
        assertBounds("M0 0 A10 10 0 0 1 10 10 L10 20", CGRect(x: 0, y: 0, width: 10, height: 20))
    }

    func testTruncatedArcBailsWithoutSpinning() {
        // Missing the final parameter: the parser must return, not loop forever.
        let path = LucideShape(parts: [.path("M2 2 A4 4 0 0 1 10")]).path(in: grid)
        XCTAssertFalse(path.isEmpty) // the move survived
        XCTAssertEqual(path.boundingRect.width, 0, accuracy: 0.0001)
    }

    // MARK: Shipped glyphs

    /// The shipped `undo-2`, asserted on the glyph itself rather than on a `d`
    /// string retyped here: what has to hold is that the icon the note cards draw
    /// still contains a real loop. This is the one failure the rest of the suite
    /// cannot see — a flattened arc keeps its ENDPOINTS, so the glyph would still
    /// render, still fill the grid, still pass every non-empty/in-bounds check, and
    /// simply stop looking like undo. Off-screen, nothing else would notice.
    func testShippedUndoGlyphDrawsARealLoop() {
        let strings = pathData(.undo2)
        XCTAssertEqual(strings.count, 2, "undo2 is an arrowhead plus a loop")
        let loop = strings[1]

        // The loop spans from the shaft's start out to the circle's right and
        // bottom extremes — centre (14.5, 14.5), radius 5.5.
        let box = drawnBounds(loop)
        XCTAssertEqual(box.minX, 4, accuracy: 0.02)
        XCTAssertEqual(box.maxX, 20, accuracy: 0.02, "the loop never reached the circle's right extreme")
        XCTAssertEqual(box.minY, 9, accuracy: 0.02)
        XCTAssertEqual(box.maxY, 20, accuracy: 0.02, "the loop never reached the circle's bottom extreme")

        // Both quarters' 45-degree points are ON the curve...
        let offset: CGFloat = 5.5 / CGFloat(2).squareRoot()
        XCTAssertLessThan(distanceToCurve(loop, CGPoint(x: 14.5 + offset, y: 14.5 - offset)), 0.02)
        XCTAssertLessThan(distanceToCurve(loop, CGPoint(x: 14.5 + offset, y: 14.5 + offset)), 0.02)
        // ...and the chord midpoints a straight-line arc would pass through are
        // 1.61 units AWAY from it. This pair is the assertion with teeth: the
        // bounding box above survives flattening, these do not.
        XCTAssertGreaterThan(distanceToCurve(loop, CGPoint(x: 17.25, y: 11.75)), 1.5, "the first quarter is a chord")
        XCTAssertGreaterThan(distanceToCurve(loop, CGPoint(x: 17.25, y: 17.25)), 1.5, "the second quarter is a chord")
    }

    /// Every `a`-carrying glyph must still land inside the 24-unit design grid —
    /// the F.6.6.2 scale-up on `pencil`'s r=1 eraser arc and on `send`'s r=.5
    /// corners is what could plausibly push one out of bounds, and a glyph that
    /// spills is clipped by the 16pt frame rather than drawn small.
    func testArcCarryingGlyphsStayOnTheDesignGrid() {
        let glyphs: [(String, LucideIcon)] = [
            ("pencil", .pencil), ("mousePointer", .mousePointer), ("squareDashed", .squareDashed),
            ("undo2", .undo2), ("send", .send),
        ]
        for (name, icon) in glyphs {
            var points: [CGPoint] = []
            for case .path(let d) in icon.parts { points += samples(d) }
            XCTAssertFalse(points.isEmpty, "\(name) drew no arcs or lines")
            for point in points {
                XCTAssertGreaterThanOrEqual(point.x, -0.5, "\(name) spills left")
                XCTAssertGreaterThanOrEqual(point.y, -0.5, "\(name) spills up")
                XCTAssertLessThanOrEqual(point.x, 24.5, "\(name) spills right")
                XCTAssertLessThanOrEqual(point.y, 24.5, "\(name) spills down")
            }
        }
    }

    /// `square-dashed`'s corner strokes are 90-degree rounds, previously drawn as
    /// diagonals. Pinning one corner's mid-sweep point keeps a future parser
    /// change from silently flattening them again.
    func testSquareDashedCornersRenderAsRounds() {
        let d = "M5 3a2 2 0 0 0-2 2"
        let offset: CGFloat = 2 - 2 / CGFloat(2).squareRoot() // 0.586 units off the chord
        XCTAssertLessThan(distanceToCurve(d, CGPoint(x: 3 + offset, y: 3 + offset)), 0.02)
        assertBounds(d, CGRect(x: 3, y: 3, width: 2, height: 2))
    }
}
