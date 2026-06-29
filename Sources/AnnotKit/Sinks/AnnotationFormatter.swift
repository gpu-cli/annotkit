import Foundation

/// Serializes notes to the `AGENTATION_NOTES.md` markdown format that the
/// `process-agentation-notes` skill consumes, and to JSON. Pure and
/// platform-independent so it is unit-testable without any IO or UI.
///
/// Markdown block shape (one per note, separated by `---`):
///
///     ## [<id>] <route> - <selector>
///     **Timestamp**: <iso8601>
///     **Element Path**: <path>
///     **Selected Text**: "<text>"   (omitted when absent)
///
///     <comment>
public enum AnnotationFormatter {
    /// A full `AGENTATION_NOTES.md` document: header plus every note block.
    public static func markdown(_ notes: [AnnotationNote]) -> String {
        var out = "# Agentation Notes\n"
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
        lines.append("**Element Path**: \(note.elementPath)")
        if let selected = note.selectedText, !selected.isEmpty {
            lines.append("**Selected Text**: \"\(selected)\"")
        }
        lines.append("")
        lines.append(note.comment)
        return lines.joined(separator: "\n")
    }

    /// Pretty-printed JSON array of notes. The raw screenshot bytes are omitted
    /// (only the pixel dimensions are kept) so the payload stays small.
    public static func json(_ notes: [AnnotationNote]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(notes.map(NoteDTO.init))
        return String(decoding: data, as: UTF8.self)
    }

    private struct NoteDTO: Codable {
        let id: String
        let route: String?
        let selector: String
        let elementPath: String
        let selectedText: String?
        let comment: String
        let timestamp: String
        let screenshotPixelWidth: Int?
        let screenshotPixelHeight: Int?

        init(_ note: AnnotationNote) {
            id = note.id
            route = note.route
            selector = note.selector
            elementPath = note.elementPath
            selectedText = note.selectedText
            comment = note.comment
            timestamp = note.timestamp
            screenshotPixelWidth = note.screenshot?.pixelWidth
            screenshotPixelHeight = note.screenshot?.pixelHeight
        }
    }
}
