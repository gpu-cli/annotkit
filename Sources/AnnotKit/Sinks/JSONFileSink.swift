import Foundation

/// Persists notes as a JSON array (merging with any existing file). This is the
/// shared store the optional `annotkit-mcp` bridge reads, so an agent can query
/// pending annotations over MCP instead of parsing the markdown file.
public struct JSONFileSink: AnnotationSink {
    public let path: String

    public init(path: String = "AGENTATION_NOTES.json") {
        self.path = path
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        guard !notes.isEmpty else { return }
        var all: [AnnotationNote] = []
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([AnnotationNote].self, from: data) {
            all = decoded
        }
        all.append(contentsOf: notes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: URL(fileURLWithPath: path))
    }
}
