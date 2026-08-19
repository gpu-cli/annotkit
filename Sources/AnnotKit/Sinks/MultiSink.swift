import Foundation

/// Fans one flush out to several sinks — the markdown snapshot an agent reads,
/// the JSON store the MCP bridge serves, the JSONL stream that wakes a watcher —
/// so a host configured from its environment can have all three without the
/// overlay knowing there is more than one destination.
///
/// EVERY sink is attempted even after one throws, and the FIRST error is the one
/// re-thrown. A full disk on the optional event stream must not cost the user the
/// note they just wrote: the snapshot is the record, the stream is a convenience,
/// and short-circuiting would silently make the least important destination the
/// one that decides whether the most important one gets written.
public struct MultiSink: AnnotationSink {
    public let sinks: [AnnotationSink]

    public init(_ sinks: [AnnotationSink]) {
        self.sinks = sinks
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        var first: Error?
        for sink in sinks {
            do { try sink.flush(notes) } catch { first = first ?? error }
        }
        if let first { throw first }
    }
}
