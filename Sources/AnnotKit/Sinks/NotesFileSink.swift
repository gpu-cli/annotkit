import Foundation

/// Appends notes to an `AGENTATION_NOTES.md` file (created with a header if
/// absent), in the format the `process-agentation-notes` skill reads. This is
/// the primary sink: it hands the agent loop a file it already knows how to
/// process. The native source-location adaptation (resolving the AX selector to
/// Swift `accessibilityIdentifier` call sites) is tracked in F4.2.
public struct NotesFileSink: AnnotationSink {
    /// Destination path. Defaults to `AGENTATION_NOTES.md` in the working
    /// directory, matching the skill's expectation.
    public let path: String

    public init(path: String = "AGENTATION_NOTES.md") {
        self.path = path
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        guard !notes.isEmpty else { return }
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "# Agentation Notes\n"
        let blocks = notes
            .map { "\n---\n\n" + AnnotationFormatter.markdownBlock($0) + "\n" }
            .joined()
        try (existing + blocks).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
