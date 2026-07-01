import Foundation

/// Writes the full set of notes to an `AGENTATION_NOTES.md` file, OVERWRITING
/// any previous contents, in the format the `process-agentation-notes` skill
/// reads. This is the primary sink: it hands the agent loop a file it already
/// knows how to process. Overwriting (rather than appending) is what makes
/// export idempotent — the caller (``AnnotationSession``) retains the whole set
/// and re-exports it, so re-writing after more notes were captured replaces the
/// file with the current full set: no duplicates, no stale notes. The native
/// source-location adaptation (resolving the AX selector to Swift
/// `accessibilityIdentifier` call sites) is tracked in F4.2.
public struct NotesFileSink: AnnotationSink {
    /// Destination path. Defaults to `AGENTATION_NOTES.md` in the working
    /// directory, matching the skill's expectation.
    public let path: String

    public init(path: String = "AGENTATION_NOTES.md") {
        self.path = path
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        guard !notes.isEmpty else { return }
        try AnnotationFormatter.markdown(notes).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
