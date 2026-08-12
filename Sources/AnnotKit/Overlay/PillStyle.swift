import SwiftUI

// MARK: - Hex color

extension Color {
    /// Build a color from a 6-digit RGB hex string (with or without a leading
    /// `#`). Backs the pill's fixed dark palette, mirrored from the Agentation nav
    /// bar. Unknown input falls back to `.clear`, so a typo can never crash a host.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .clear
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Pill palette (extracted from agentation@3.0.2)

/// The compact-pill palette, lifted from the Agentation nav bar's dist so the two
/// sibling tools read the same: an opaque `#1A1A1A` container (the AnnotKit
/// overlay is transparent, so material would show desktop through it), hairline
/// white borders, low-opacity white glyphs that brighten on hover, and a red
/// destructive hover. The count-badge fill reuses `Color.accentColor` to stay
/// consistent with the highlight stroke; the active selection tool is marked with
/// a full-white glyph instead, so the accent keeps meaning "notes exist".
enum PillStyle {
    static let background = Color(hex: "1A1A1A")
    static let border = Color.white.opacity(0.08)
    static let iconIdle = Color.white.opacity(0.4)
    static let iconHover = Color.white.opacity(0.8)
    static let hoverBackground = Color.white.opacity(0.1)
    static let destructive = Color(hex: "EF4444")
    static let success = Color(hex: "22C55E")
    /// The glyph of the ACTIVE tool in the selection-tool segment. Full white, not
    /// an accent chip: the pill's only other lit state is the count badge, and a
    /// second accent-colored thing in the row would read as another notification
    /// rather than as "this tool is armed".
    static let iconActive = Color.white
    /// Hairline rule separating the tool segment from the note actions. The same
    /// white-on-dark weight as ``border`` but a touch stronger, so it reads as a
    /// deliberate group boundary at 1pt instead of disappearing into the capsule.
    static let divider = Color.white.opacity(0.1)

    /// Blank space the toolbar panel keeps AROUND the pill, for the chrome that
    /// draws OUTSIDE the control's own layout bounds and would otherwise be clipped
    /// by a snug window: the drop shadow (radius 12, offset 8 DOWN, hence the taller
    /// bottom) and the count badge, which is hung 5pt past the pill's top-left
    /// corner.
    ///
    /// This is the whole remaining cost of the panel being hit-testable. macOS does
    /// not route mouse events through a window's transparent parts — measured, and
    /// true even of a panel drawing nothing at all — so every pixel the panel covers
    /// is a pixel the host app cannot be clicked through. Sizing the panel to the
    /// pill reduces that to this band, which hugs the control and reads as part of
    /// it. It was a permanently-mounted 240x104 rect over the host's bottom-right
    /// corner, dead in BOTH modes, of which the pill used 8% when idle.
    ///
    /// Shared with ``OverlayPlacement/toolbarFrame(hostFrame:visibleFrame:panelSize:)``,
    /// which subtracts it to keep the pill at the same inset from the host's corner
    /// it has always had: the panel changing size must not move the control.
    static let panelChrome = EdgeInsets(top: 14, leading: 14, bottom: 20, trailing: 14)

    /// The pill's inset from the visible region's bottom-right corner. Unchanged
    /// from when it was padding INSIDE a fixed 240x104 panel, so the control sits
    /// exactly where it always has.
    static let cornerInset: CGFloat = 20
}

// MARK: - Icon-button palette

/// The colours a single ``IconButton`` needs, so ONE implementation of the button's
/// mechanics (hover wash, disabled dim, press scale, tooltip + accessibility label)
/// can serve two surfaces that must not look alike. The pill is an opaque `#1A1A1A`
/// capsule, where white-on-dark is the only legible treatment; the note cards are
/// `.regularMaterial`, where that same white glyph would all but vanish against a
/// light desktop showing through. Parameterising the eight colours is what keeps
/// the second surface from becoming a second copy of the interaction logic — which
/// is the part that would actually drift.
struct IconButtonPalette: Sendable {
    let idle: Color
    let hover: Color
    /// The lit member of a segmented control (the pill's tool pair). The cards have
    /// no persistent-state control, so this is simply never reached there.
    let active: Color
    /// Disabled is a colour, not an opacity modifier, because the two surfaces dim
    /// from different starting points: white-at-0.4 on the pill, the system's
    /// secondary label on the cards.
    let disabled: Color
    let destructiveIdle: Color
    /// Glyph colour once the destructive fill is behind it — it has to survive a
    /// saturated red, so it is not simply ``hover``.
    let destructiveHover: Color
    let hoverFill: Color
    let destructiveFill: Color
}

extension IconButtonPalette {
    /// The pill's palette, byte-identical to what ``PillStyle`` already drove: the
    /// destructive glyph at rest is deliberately the SAME dim white as every other
    /// glyph, because on the pill "this one deletes" is announced by the red hover
    /// wash alone and a permanently red glyph in that row would read as an error.
    static let pill = IconButtonPalette(
        idle: PillStyle.iconIdle,
        hover: PillStyle.iconHover,
        active: PillStyle.iconActive,
        disabled: PillStyle.iconIdle.opacity(0.4),
        destructiveIdle: PillStyle.iconIdle,
        destructiveHover: .white,
        hoverFill: PillStyle.hoverBackground,
        destructiveFill: PillStyle.destructive
    )

    /// The note cards' palette: system label colours, so the glyphs track the
    /// viewer's appearance the way the `.regularMaterial` behind them already does.
    /// Hard-coding the pill's white here is the specific failure this exists to
    /// prevent — it is invisible on a light background, which is most of them.
    ///
    /// The card's destructive glyph IS red at rest, unlike the pill's: it replaces a
    /// `Label("Delete")` that was already `.red`, and the card has no second red
    /// element for it to be confused with.
    static let card = IconButtonPalette(
        idle: .secondary,
        hover: .primary,
        active: .primary,
        disabled: Color.secondary.opacity(0.4),
        destructiveIdle: .red,
        destructiveHover: .white,
        hoverFill: Color.primary.opacity(0.08),
        destructiveFill: .red
    )
}

// MARK: - Lucide icon model

/// A primitive on Lucide's 24x24 design grid. Modeling each glyph as a small
/// union of primitives (instead of shipping a general SVG renderer for a handful
/// of static icons) keeps them offline, dependency-free, and unit-testable — the
/// no-speculative-abstraction rule from CLAUDE.md. `path` backs the few glyphs
/// that need real curves, parsed from an SVG `d` string.
enum IconPart {
    case path(String)
    case circle(CGPoint, CGFloat)
    case line(CGPoint, CGPoint)
    case rrect(CGRect, CGFloat)
}

/// The Lucide glyphs the toolbar pill uses, authored on the 24x24 viewBox. The
/// `d` strings are copied verbatim from lucide.dev so the rendered shape matches
/// the sibling Agentation nav bar — including their elliptical arcs, which the
/// parser now converts to real cubics. A few glyphs (`copy`'s rounded rect,
/// `download`'s tray) stay hand-built from primitives because the primitive form
/// is simpler to read, not because the parser cannot handle their `d`.
struct LucideIcon {
    let parts: [IconPart]

    /// Lucide `pencil` — the idle pill's ENTER-annotate-mode glyph. The real
    /// Lucide `d` strings, arcs included. Its eraser end is an `a` with r=1 across
    /// a 5.6-unit chord, so it only closes into a round butt once the parser
    /// applies the F.6.6.2 radius scale-up; the nib and shoulder arcs are ordinary
    /// small rounds.
    static let pencil = LucideIcon(parts: [
        .path("M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"),
        .path("m15 5 4 4"),
    ])

    static let check = LucideIcon(parts: [.path("M20 6 9 17l-5-5")])

    /// Lucide `download` — export to a file. A deliberate simplification of the
    /// real glyph: an open-top tray plus a down arrow, with square tray corners
    /// instead of Lucide's arc-rounded ones. The corners are square by choice (the
    /// parser handles arcs now); swapping in the upstream `d` is a glyph change,
    /// not a parser one.
    static let download = LucideIcon(parts: [
        .line(CGPoint(x: 4, y: 15), CGPoint(x: 4, y: 20)),
        .line(CGPoint(x: 4, y: 20), CGPoint(x: 20, y: 20)),
        .line(CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 15)),
        .line(CGPoint(x: 12, y: 3), CGPoint(x: 12, y: 15)),
        .line(CGPoint(x: 7, y: 10), CGPoint(x: 12, y: 15)),
        .line(CGPoint(x: 17, y: 10), CGPoint(x: 12, y: 15)),
    ])

    static let copy = LucideIcon(parts: [
        .rrect(CGRect(x: 8, y: 8, width: 14, height: 14), 2),
        .path("M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"),
    ])

    static let trash = LucideIcon(parts: [
        .path("M3 6h18"),
        .path("M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"),
        .path("M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"),
        .line(CGPoint(x: 10, y: 11), CGPoint(x: 10, y: 17)),
        .line(CGPoint(x: 14, y: 11), CGPoint(x: 14, y: 17)),
    ])

    static let close = LucideIcon(parts: [
        .path("M18 6 6 18"),
        .path("M6 6l12 12"),
    ])

    /// Lucide `mouse-pointer-2` — the POINT tool: select by clicking. The real
    /// Lucide `d` string; its four corner arcs (`a`) render as true curves, which
    /// is what keeps the cursor's tail and notch from reading as hard mitres.
    static let mousePointer = LucideIcon(parts: [
        .path("M4.037 4.688a.495.495 0 0 1 .651-.651l16 6.5a.5.5 0 0 1-.063.947l-6.124 1.58a2 2 0 0 0-1.438 1.435l-1.579 6.126a.5.5 0 0 1-.947.063z"),
    ])

    /// Lucide `arrow-up` / `arrow-down` — the composer's tree navigation: bind the
    /// note to the enclosing component, or to one inside it. Full-shaft arrows
    /// rather than the bare `chevron.up`/`chevron.down` they replace: a lone
    /// chevron at 16pt reads as "expand/collapse a disclosure", which is the wrong
    /// promise for a control that MOVES the binding, and the shaft is what makes
    /// the pair read as travel along an axis.
    static let arrowUp = LucideIcon(parts: [
        .path("m5 12 7-7 7 7"),
        .path("M12 19V5"),
    ])

    static let arrowDown = LucideIcon(parts: [
        .path("M12 5v14"),
        .path("m19 12-7 7-7-7"),
    ])

    /// Lucide `undo-2` — dismiss the composer without capturing. Its identity is
    /// the semicircular loop, authored upstream as TWO chained 5.5-radius quarter
    /// arcs; both quarters must render as real curves or the glyph degrades to a
    /// triangular pennant that reads as nothing in particular. `LucideArcTests`
    /// pins the loop's 45-degree points for exactly that reason.
    ///
    /// Chosen over `x` for Cancel because the card's other neutral glyphs are all
    /// directional: an X would be the only "destroy" mark on a row whose
    /// destructive slot (the editor's trash) is a different button entirely.
    static let undo2 = LucideIcon(parts: [
        .path("M9 14 4 9l5-5"),
        .path("M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"),
    ])

    /// Lucide `send` — the commit action on both cards (Add note / Save). The real
    /// `d`, whose body is one closed subpath of `a`-rounded corners, so it is a
    /// filled-looking dart only because the corners are true arcs; flattened it
    /// collapses into a scalene triangle with a nick in it.
    static let send = LucideIcon(parts: [
        .path("M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"),
        .path("m21.854 2.147-10.94 10.939"),
    ])

    /// Lucide `square-dashed` — the FRAME tool: select by drawing a frame. Twelve
    /// short strokes rather than one outline, and that is the point: the gaps echo
    /// the dashed rubber band the tool draws, so the button previews its own
    /// gesture instead of reading as a generic square.
    static let squareDashed = LucideIcon(parts: [
        .path("M5 3a2 2 0 0 0-2 2"),
        .path("M19 3a2 2 0 0 1 2 2"),
        .path("M21 19a2 2 0 0 1-2 2"),
        .path("M5 21a2 2 0 0 1-2-2"),
        .path("M9 3h1"),
        .path("M9 21h1"),
        .path("M14 3h1"),
        .path("M14 21h1"),
        .path("M3 9v1"),
        .path("M21 9v1"),
        .path("M3 14v1"),
        .path("M21 14v1"),
    ])
}

// MARK: - Shape

/// Renders a ``LucideIcon`` as a SwiftUI `Shape`, scaling the 24-grid primitives
/// to fit `rect`. The caller strokes it with round caps/joins to match Lucide's
/// stroke geometry.
struct LucideShape: Shape {
    let parts: [IconPart]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        var path = Path()
        for part in parts {
            switch part {
            case .path(let d):
                LucideShape.append(pathData: d, to: &path, scale: scale)
            case .circle(let center, let radius):
                path.addEllipse(in: CGRect(
                    x: (center.x - radius) * scale,
                    y: (center.y - radius) * scale,
                    width: radius * 2 * scale,
                    height: radius * 2 * scale
                ))
            case .line(let a, let b):
                path.move(to: CGPoint(x: a.x * scale, y: a.y * scale))
                path.addLine(to: CGPoint(x: b.x * scale, y: b.y * scale))
            case .rrect(let box, let radius):
                path.addRoundedRect(
                    in: CGRect(x: box.minX * scale, y: box.minY * scale,
                               width: box.width * scale, height: box.height * scale),
                    cornerSize: CGSize(width: radius * scale, height: radius * scale)
                )
            }
        }
        return path
    }

    // MARK: SVG `d`-string parser (M/L/H/V/C/Q/A/Z, absolute + relative)

    private enum Token { case command(Character); case number(CGFloat) }

    private static func append(pathData d: String, to path: inout Path, scale: CGFloat) {
        let tokens = tokenize(d)
        var current = CGPoint.zero   // grid units
        var subStart = CGPoint.zero  // grid units
        var command: Character = " "
        var index = 0

        func nextNumber() -> CGFloat? {
            guard index < tokens.count, case .number(let n) = tokens[index] else { return nil }
            index += 1
            return n
        }
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

        while index < tokens.count {
            let progress = index
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            switch command {
            case "M", "m":
                guard let a = nextNumber(), let b = nextNumber() else { return }
                let p = command == "m" ? CGPoint(x: current.x + a, y: current.y + b) : CGPoint(x: a, y: b)
                current = p; subStart = p
                path.move(to: scaled(p))
                command = command == "m" ? "l" : "L" // extra pairs after a move are implicit lineto
            case "L", "l":
                guard let a = nextNumber(), let b = nextNumber() else { return }
                current = command == "l" ? CGPoint(x: current.x + a, y: current.y + b) : CGPoint(x: a, y: b)
                path.addLine(to: scaled(current))
            case "H", "h":
                guard let a = nextNumber() else { return }
                current.x = command == "h" ? current.x + a : a
                path.addLine(to: scaled(current))
            case "V", "v":
                guard let a = nextNumber() else { return }
                current.y = command == "v" ? current.y + a : a
                path.addLine(to: scaled(current))
            case "C", "c":
                guard let a = nextNumber(), let b = nextNumber(), let c = nextNumber(),
                      let d2 = nextNumber(), let e = nextNumber(), let f = nextNumber() else { return }
                let rel = command == "c"
                let c1 = rel ? CGPoint(x: current.x + a, y: current.y + b) : CGPoint(x: a, y: b)
                let c2 = rel ? CGPoint(x: current.x + c, y: current.y + d2) : CGPoint(x: c, y: d2)
                let end = rel ? CGPoint(x: current.x + e, y: current.y + f) : CGPoint(x: e, y: f)
                current = end
                path.addCurve(to: scaled(end), control1: scaled(c1), control2: scaled(c2))
            case "Q", "q":
                guard let a = nextNumber(), let b = nextNumber(),
                      let c = nextNumber(), let d2 = nextNumber() else { return }
                let rel = command == "q"
                let ctrl = rel ? CGPoint(x: current.x + a, y: current.y + b) : CGPoint(x: a, y: b)
                let end = rel ? CGPoint(x: current.x + c, y: current.y + d2) : CGPoint(x: c, y: d2)
                current = end
                path.addQuadCurve(to: scaled(end), control: scaled(ctrl))
            case "A", "a":
                // Elliptical arc (rx ry x-rotation large-arc sweep x y), converted
                // to cubics by ``appendArc``. This used to draw a straight line to
                // the endpoint, which was survivable only while every arc in the
                // set was a 1-2 unit corner round; a glyph whose whole identity is
                // a loop (Lucide `undo-2`, 5.5-radius semicircles) collapses to a
                // vertical line under that shortcut, so the flattening is gone.
                guard let rx = nextNumber(), let ry = nextNumber(), let rotation = nextNumber(),
                      let largeArc = nextNumber(), let sweep = nextNumber(),
                      let ax = nextNumber(), let ay = nextNumber() else { return }
                let end = command == "a" ? CGPoint(x: current.x + ax, y: current.y + ay) : CGPoint(x: ax, y: ay)
                appendArc(
                    from: current, to: end, rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc != 0, sweep: sweep != 0, to: &path, scale: scale
                )
                current = end
            case "Z", "z":
                path.closeSubpath()
                current = subStart
            default:
                return
            }
            if index == progress { return } // no token consumed -> malformed; bail rather than spin
        }
    }

    /// SVG 1.1 Appendix F.6.5 endpoint -> centre parameterisation, emitted as
    /// cubic Béziers. Everything here is in 24-grid units until the final
    /// `scaled` on each control point, so the ellipse maths never has to know the
    /// render size.
    private static func appendArc(
        from start: CGPoint,
        to end: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        to path: inout Path,
        scale: CGFloat
    ) {
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

        // F.6.2 out-of-range handling. Coincident endpoints mean "omit the
        // segment entirely" — emitting a zero-length line instead would round-cap
        // into a stray dot. A zero radius is a plain lineto. Both branches also
        // keep the divisions below from producing NaN control points, which would
        // silently blank the whole glyph.
        if start == end { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else {
            path.addLine(to: scaled(end))
            return
        }

        let phi = rotationDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // F.6.5.1 — the chord half-vector expressed in the ellipse's own frame.
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // F.6.6.2 — radii too small to span the endpoints are scaled UP until they
        // just reach, rather than rejected: falling back to a line here is what
        // makes an authored glyph fall short of its own endpoint and break the
        // subpath. Lucide relies on this (`pencil` asks for r=1 across a 5.6-unit
        // chord), so this branch is hot, not defensive.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let correction = sqrt(lambda)
            rx *= correction
            ry *= correction
        }

        // F.6.5.2/3 — centre, first in the rotated frame then back to user space.
        let rx2 = rx * rx, ry2 = ry * ry
        let denominator = rx2 * y1 * y1 + ry2 * x1 * x1
        let numerator = rx2 * ry2 - denominator
        var factor = denominator > 0 ? sqrt(max(0, numerator) / denominator) : 0
        if largeArc == sweep { factor = -factor }
        let cxp = factor * rx * y1 / ry
        let cyp = -factor * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        // F.6.5.5/6 — start angle and swept angle, then the flag fix-up that turns
        // the raw [-pi, pi] result into the direction `sweep` actually asked for.
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let lengths = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard lengths > 0 else { return 0 }
            let value = acos(min(1, max(-1, (ux * vx + uy * vy) / lengths)))
            return (ux * vy - uy * vx) < 0 ? -value : value
        }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 {
            delta -= 2 * .pi
        } else if sweep, delta < 0 {
            delta += 2 * .pi
        }

        // A single cubic cannot hold more than a quarter turn without visible
        // error, so split the sweep into <=90 degree pieces. `k` is the standard
        // control magnitude (4/3)*tan(theta/4), exact at the segment endpoints and
        // tangents.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        // Points and tangents are evaluated on the unrotated ellipse and then run
        // through the rotation individually — rotating a bounding box, or applying
        // phi only to the endpoints, skews the control points and gives an ellipse
        // that is the wrong shape rather than merely the wrong orientation.
        func point(_ theta: CGFloat) -> CGPoint {
            let c = cos(theta), s = sin(theta)
            return CGPoint(
                x: cx + rx * c * cosPhi - ry * s * sinPhi,
                y: cy + rx * c * sinPhi + ry * s * cosPhi
            )
        }
        func derivative(_ theta: CGFloat) -> CGPoint {
            let c = cos(theta), s = sin(theta)
            return CGPoint(
                x: -rx * s * cosPhi - ry * c * sinPhi,
                y: -rx * s * sinPhi + ry * c * cosPhi
            )
        }

        var theta = theta1
        for segment in 0..<segments {
            let next = theta + step
            let from = point(theta)
            // Snap the last segment onto the authored endpoint: accumulated
            // rounding (worst after an F.6.6.2 scale-up) would otherwise leave a
            // sub-unit gap before the next command's `current`.
            let to = segment == segments - 1 ? end : point(next)
            let d1 = derivative(theta), d2 = derivative(next)
            path.addCurve(
                to: scaled(to),
                control1: scaled(CGPoint(x: from.x + k * d1.x, y: from.y + k * d1.y)),
                control2: scaled(CGPoint(x: to.x - k * d2.x, y: to.y - k * d2.y))
            )
            theta = next
        }
    }

    private static func tokenize(_ d: String) -> [Token] {
        let commands = Set("MmLlHhVvCcSsQqTtAaZz")
        var tokens: [Token] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                i += 1
                continue
            }
            if commands.contains(c) {
                tokens.append(.command(c))
                i += 1
                continue
            }
            // Parse one SVG number. A sign or a second decimal point starts a new
            // number, so "-5-5" and "-1.1.9" tokenize into two values each.
            var str = ""
            if c == "-" || c == "+" { str.append(c); i += 1 }
            var seenDot = false
            while i < chars.count {
                let ch = chars[i]
                if ch.isNumber {
                    str.append(ch); i += 1
                } else if ch == "." && !seenDot {
                    seenDot = true; str.append(ch); i += 1
                } else if ch == "e" || ch == "E" {
                    str.append(ch); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { str.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            if let value = Double(str) {
                tokens.append(.number(CGFloat(value)))
            } else if str.isEmpty {
                i += 1 // skip an unparseable char so the scan always makes progress
            }
        }
        return tokens
    }
}

// MARK: - Tooltip

#if os(macOS)
/// A zero-content `NSView` carrying a `toolTip`, layered behind a control so the
/// hover tooltip shows reliably inside the borderless, non-activating overlay
/// panel (where SwiftUI's `.help` alone can fail to render).
private struct ToolTipBacking: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = text
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = text
    }
}
#endif

extension View {
    /// Hover tooltip for an icon-only control (pill or note card): SwiftUI `.help`
    /// plus (on macOS) an NSView-backed `toolTip` for reliability inside the overlay
    /// panel. Both surfaces need the AppKit backing — the cards live in the same
    /// borderless, non-activating panel the pill does, where `.help` alone can fail
    /// to render, and a card button is now the ONLY place its action is named.
    @ViewBuilder
    func iconToolTip(_ text: String) -> some View {
        #if os(macOS)
        help(text).background(ToolTipBacking(text: text))
        #else
        help(text)
        #endif
    }
}
