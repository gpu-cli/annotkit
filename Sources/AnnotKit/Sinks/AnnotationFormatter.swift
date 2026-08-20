import Foundation

/// Serializes notes to the `ANNOTKIT_NOTES.md` markdown format that the
/// `process-agentation-notes` skill consumes, and to JSON. Pure and
/// platform-independent so it is unit-testable without any IO or UI.
///
/// Markdown block shape (one per note, separated by `---`):
///
///     ## [<id>] <route> - <selector>
///     **Timestamp**: <iso8601>
///     **Context**: key="value", key="value"   (omitted when the host registers none)
///     **Element Path**: <path>
///     **Selected Text**: "<text>"   (omitted when absent)
///
///     <comment>
public enum AnnotationFormatter {
    /// A full `ANNOTKIT_NOTES.md` document: header plus every note block.
    public static func markdown(_ notes: [AnnotationNote]) -> String {
        var out = "# AnnotKit Notes\n"
        for note in notes {
            out += "\n---\n\n" + markdownBlock(note) + "\n"
        }
        return out
    }

    /// One note as a markdown block (no leading separator).
    static func markdownBlock(_ note: AnnotationNote) -> String {
        var lines: [String] = []
        let route = note.route ?? ""
        lines.append("## [\(note.id)] \(route) - \(note.selector)")
        lines.append("**Timestamp**: \(note.timestamp)")
        // Directly under the timestamp: the two together answer "when, and in which
        // world" before a single word about the element, which is the order an agent
        // has to reconstruct things in — relaunch the world, then find the view.
        if let context = contextLine(note.context) {
            lines.append("**Context**: \(context)")
        }
        lines.append("**Element Path**: \(note.elementPath)")
        if let component = note.component, !component.isEmpty {
            lines.append("**Component**: #\(component)")
        }
        if let role = note.elementRole, !role.isEmpty {
            var element = role
            if let text = note.elementText, !text.isEmpty { element += " \"\(text)\"" }
            lines.append("**Element**: \(element)")
        }
        if note.unseeded == true {
            lines.append("**Unseeded**: the clicked element has no accessibilityIdentifier — locate it via the Component above, then narrow by the Element role/text; consider seeding it")
        }
        // `else if`, not a second `if`: the two locators are mutually exclusive by
        // construction (a note is framed or it is a point, never both), and the
        // chain is what documents that — two independent lines would let a future
        // leak of one into the other print a self-contradicting block instead of
        // failing loudly.
        if let rect = note.regionRect {
            lines.append("**Region**: framed \(Int(rect.width))x\(Int(rect.height)) at (x: \(Int(rect.minX)), y: \(Int(rect.minY))) from the top-left of \(note.selector)")
        } else if let region = note.regionOffset {
            lines.append("**Region**: (x: \(Int(region.x)), y: \(Int(region.y))) from the top-left of \(note.selector)")
        }
        if let selected = note.selectedText, !selected.isEmpty {
            lines.append("**Selected Text**: \"\(selected)\"")
        }
        lines.append("")
        lines.append(note.comment)
        return lines.joined(separator: "\n")
    }

    /// `key="value"` pairs in KEY ORDER, or nil for an absent/empty snapshot.
    ///
    /// Sorted, because a dictionary's iteration order is not stable across runs and
    /// an export whose bytes shuffle between two identical captures is a diff no
    /// reviewer can read. Quoted and backslash-escaped, because these are host
    /// strings — a persona named `Ada, "the countess"` must not silently become two
    /// context entries in whatever parses this line.
    static func contextLine(_ context: [String: String]?) -> String? {
        guard let context, !context.isEmpty else { return nil }
        return context.keys.sorted().map { key in
            let value = context[key]!
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(value)\""
        }.joined(separator: ", ")
    }

    /// Pretty-printed JSON array of notes. The raw screenshot bytes are omitted
    /// (only the pixel dimensions are kept) so the payload stays small.
    public static func json(_ notes: [AnnotationNote]) throws -> String {
        let encoder = JSONEncoder()
        // `withoutEscapingSlashes`: routes and context values are full of paths,
        // and `Settings\/Models` is noise in a payload whose whole job is to be read.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(notes.map(NoteDTO.init))
        return String(decoding: data, as: UTF8.self)
    }

    private struct NoteDTO: Codable {
        let id: String
        let route: String?
        let selector: String
        let elementPath: String
        let component: String?
        let elementRole: String?
        let elementText: String?
        let unseeded: Bool?
        let selectedText: String?
        let comment: String
        let timestamp: String
        let context: [String: String]?
        let regionOffsetX: Int?
        let regionOffsetY: Int?
        let regionRectX: Int?
        let regionRectY: Int?
        let regionRectWidth: Int?
        let regionRectHeight: Int?
        let screenshotPixelWidth: Int?
        let screenshotPixelHeight: Int?

        init(_ note: AnnotationNote) {
            id = note.id
            route = note.route
            selector = note.selector
            elementPath = note.elementPath
            component = note.component
            elementRole = note.elementRole
            elementText = note.elementText
            unseeded = note.unseeded
            selectedText = note.selectedText
            comment = note.comment
            timestamp = note.timestamp
            // Also normalized here, because a decoded note bypasses the property
            // observer that normally keeps an empty snapshot from existing.
            context = (note.context?.isEmpty == true) ? nil : note.context
            regionOffsetX = note.regionOffset.map { Int($0.x) }
            regionOffsetY = note.regionOffset.map { Int($0.y) }
            regionRectX = note.regionRect.map { Int($0.minX) }
            regionRectY = note.regionRect.map { Int($0.minY) }
            regionRectWidth = note.regionRect.map { Int($0.width) }
            regionRectHeight = note.regionRect.map { Int($0.height) }
            screenshotPixelWidth = note.screenshot?.pixelWidth
            screenshotPixelHeight = note.screenshot?.pixelHeight
        }
    }
}
