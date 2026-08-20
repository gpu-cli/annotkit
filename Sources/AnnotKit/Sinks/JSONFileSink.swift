import Foundation

/// Persists notes as a JSON array (merging with any existing file). This is the
/// shared store the optional `annotkit-mcp` bridge reads, so an agent can query
/// pending annotations over MCP instead of parsing the markdown file.
///
/// Merging is BY ID, not by appending: the session retains its whole set and
/// re-flushes all of it on every export, so a plain append turned a second press
/// of Export into a second copy of every note — and the agent read each one twice.
/// An id already in the file is REPLACED in place (so an edited comment lands
/// where the note already was, keeping the file's order stable), and ids only in
/// the file survive, which is what lets the store accumulate across launches and
/// lets `annotation_resolve` take a note out of it.
public struct JSONFileSink: AnnotationSink {
    public let path: String

    public init(path: String = "ANNOTKIT_NOTES.json") {
        self.path = path
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        guard !notes.isEmpty else { return }
        var all: [AnnotationNote] = []
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([AnnotationNote].self, from: data) {
            all = decoded
        }
        for note in notes {
            if let existing = all.firstIndex(where: { $0.id == note.id }) {
                all[existing] = note
            } else {
                all.append(note)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(all).write(to: URL(fileURLWithPath: path))
    }
}
