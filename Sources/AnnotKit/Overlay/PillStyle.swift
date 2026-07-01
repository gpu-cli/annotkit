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
/// destructive hover. The toggle-active and count-badge fills reuse
/// `Color.accentColor` to stay consistent with the highlight stroke.
enum PillStyle {
    static let background = Color(hex: "1A1A1A")
    static let border = Color.white.opacity(0.08)
    static let iconIdle = Color.white.opacity(0.4)
    static let iconHover = Color.white.opacity(0.8)
    static let hoverBackground = Color.white.opacity(0.1)
    static let destructive = Color(hex: "EF4444")
    static let divider = Color.white.opacity(0.08)
}

// MARK: - Lucide icon model

/// A primitive on Lucide's 24x24 design grid. Modeling each glyph as a small
/// union of primitives (instead of shipping a general SVG renderer for six static
/// icons) keeps them offline, dependency-free, and unit-testable — the
/// no-speculative-abstraction rule from CLAUDE.md. `path` backs the few glyphs
/// that need real curves, parsed from an SVG `d` string.
enum IconPart {
    case path(String)
    case circle(CGPoint, CGFloat)
    case line(CGPoint, CGPoint)
    case rrect(CGRect, CGFloat)
}

/// The Lucide glyphs the toolbar pill uses, authored on the 24x24 viewBox. The
/// `d` strings are copied from lucide.dev so the rendered shape matches the
/// sibling Agentation nav bar; the rest use primitives (`copy`'s rounded rect and
/// the straight strokes of `pencil`/`download`/`close`) so no elliptical-arc
/// parsing is needed.
struct LucideIcon {
    let parts: [IconPart]

    /// The annotate-toggle glyph (an annotate-indicative `pencil`). Authored from
    /// straight strokes only — Lucide's real `pencil` and `square-dashed-mouse-
    /// pointer` are arc-heavy, and the primitive `d`-parser implements no
    /// elliptical arc (`A`) command, so this follows the existing `download`
    /// precedent: a diagonal shaft with a triangular tip, plus a collar band.
    static let pencil = LucideIcon(parts: [
        .path("M4 20 L4 16 L14 6 L18 10 L8 20 Z"),
        .line(CGPoint(x: 13, y: 7), CGPoint(x: 17, y: 11)),
    ])

    static let check = LucideIcon(parts: [.path("M20 6 9 17l-5-5")])

    /// Lucide `download` — export to a file. Drawn with straight strokes only
    /// (the real glyph's rounded tray uses SVG arc commands the primitive parser
    /// does not implement): an open-top tray plus a down arrow into it.
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

    // MARK: SVG `d`-string parser (M/L/H/V/C/Q/Z, absolute + relative)

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
            case "Z", "z":
                path.closeSubpath()
                current = subStart
            default:
                return
            }
            if index == progress { return } // no token consumed -> malformed; bail rather than spin
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
