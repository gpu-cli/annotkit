import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One line of the event stream: what happened, to which note, when.
///
/// A named, `Codable` type rather than an ad-hoc dictionary because this IS the
/// contract an agent watches — a watcher decodes these lines, and a field renamed
/// by accident should break a build here rather than a jq expression in someone
/// else's repository.
public struct AnnotationEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// A note the stream had never seen before.
        case captured
        /// A note whose agent-visible record changed (the pin editor's Save).
        case edited
        /// A note that was in the previous flush and is not in this one.
        case deleted
    }

    public var event: Kind
    /// Hoisted out of ``note`` so a watcher can filter on it without decoding the
    /// whole record — `grep '"id":"a1b2c3"'` is a reasonable thing to do to a log.
    public var id: String
    public var timestamp: String
    /// The snapshot file this instance writes, when the host configured one. The
    /// point of the stream is to send a reader somewhere else: a shared event log
    /// with several isolated instances appending to it is only actionable if each
    /// line says which world's snapshot to open.
    public var snapshot: String?
    public var note: AnnotationNote

    public init(event: Kind, id: String, timestamp: String, snapshot: String? = nil, note: AnnotationNote) {
        self.event = event
        self.id = id
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.note = note
    }
}

/// An APPEND-ONLY JSONL log of what happened to the notes, written beside the
/// snapshot sinks — one line per capture, edit and delete.
///
/// It exists because the snapshot sinks are unwatchable BY DESIGN.
/// ``NotesFileSink`` writes atomically (`write(toFile:atomically:)` renames a
/// temporary file over the destination), which is exactly right for a file an
/// agent may read at any moment — a reader never sees half a document — and
/// exactly wrong for `tail -f`, which follows the inode it opened and goes silent
/// the first time the file is replaced underneath it. So an agent had two options:
/// poll, or be told. This is the third.
///
/// The division of labour is strict, and worth keeping strict: **the snapshot is
/// the source of truth; the stream only wakes the reader.** Both are written by
/// the same flush, so a watcher that reacts to a line and then reads the snapshot
/// always finds the note that woke it. Nothing here is a substitute for the
/// snapshot — a stream replayed from the beginning would double-count edits and
/// resurrect deletes, and the `process-agentation-notes` skill still reads the
/// markdown.
///
/// Events are DERIVED, by diffing each flush against the previous one, rather
/// than pushed from the session's capture/edit/delete calls. That is what makes
/// the two files agree: an event exists only when a flush actually happened, so
/// the stream cannot promise a note the snapshot has not yet been given. A note
/// typed but not yet exported produces no line, which is correct — the user has
/// not sent it.
///
/// Comparison is against the note's ENCODED record, not the struct: the overlay's
/// window-local rects change whenever the host scrolls, and a note that merely
/// moved on screen must not read as edited. What the agent can see changed, or
/// nothing changed.
///
/// **Concurrent appends are safe across processes.** Lines are written with a
/// single `write(2)` to a descriptor opened `O_APPEND`, which the kernel does not
/// interleave for a write this small — so several isolated instances can share one
/// event file and one `tail -f` can watch a whole fleet.
public struct JSONLEventSink: AnnotationSink {
    public let path: String
    public let snapshotPath: String?
    private let timestamp: @Sendable () -> String
    private let memory = Memory()

    /// - Parameters:
    ///   - path: the `.jsonl` log. Created on first write; never truncated.
    ///   - snapshot: the snapshot file a reader woken by these lines should open.
    public init(
        path: String,
        snapshot: String? = nil,
        timestamp: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.path = path
        self.snapshotPath = snapshot
        self.timestamp = timestamp
    }

    public func flush(_ notes: [AnnotationNote]) throws {
        // Deliberately NOT guarded on `notes.isEmpty` the way the snapshot sinks
        // are: an empty set can be the true outcome of deleting the last note, and
        // that is precisely a thing a watcher needs to hear about.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let now = timestamp()

        // The screenshot NEVER goes on the wire here. A JSONL line is read by
        // `tail`, by `jq`, by a `while read` loop — a base64 PNG would put
        // megabytes on a single line of a file whose whole value is that it can be
        // followed cheaply, and the pixels are already in the snapshot for whoever
        // wants them. Stripping it also keeps a re-encoded image from reading as an
        // edit. (``AnnotationFormatter/json(_:)`` drops it for the same reason.)
        let lean = notes.map { note -> AnnotationNote in
            guard note.screenshot != nil else { return note }
            var copy = note
            copy.screenshot = nil
            return copy
        }

        let events = try memory.diff(lean, encoder: encoder) { kind, note in
            AnnotationEvent(event: kind, id: note.id, timestamp: now, snapshot: snapshotPath, note: note)
        }
        guard !events.isEmpty else { return }

        var payload = Data()
        for event in events {
            payload.append(try encoder.encode(event))
            payload.append(0x0A)
        }
        try Self.append(payload, to: path)
    }

    /// The previous flush, held so the next one can be diffed against it.
    ///
    /// Starts EMPTY on every launch, which is not an approximation: `pending` is
    /// in-process state that also starts empty, so every note this instance flushes
    /// really is one it captured. A relaunch over an existing log appends the new
    /// session's captures without re-announcing the old ones, because the old ones
    /// are not in `pending` either.
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var previous: [(note: AnnotationNote, record: Data)] = []

        /// Diff and commit under ONE lock. Two flushes racing must not both read the
        /// same "previous" and both emit `captured` for the same note — and the
        /// lock doubles as the ordering guarantee for the writes that follow.
        func diff(
            _ notes: [AnnotationNote],
            encoder: JSONEncoder,
            make: (AnnotationEvent.Kind, AnnotationNote) -> AnnotationEvent
        ) throws -> [AnnotationEvent] {
            lock.lock()
            defer { lock.unlock() }

            let current = try notes.map { (note: $0, record: try encoder.encode($0)) }
            var was: [String: Data] = [:]
            for entry in previous { was[entry.note.id] = entry.record }

            var events: [AnnotationEvent] = []
            for entry in current {
                guard let seen = was[entry.note.id] else {
                    events.append(make(.captured, entry.note))
                    continue
                }
                if seen != entry.record { events.append(make(.edited, entry.note)) }
            }
            // Deletions last and in their ORIGINAL order: a reader replaying one
            // flush's lines sees the surviving set before it sees what left it.
            let survivors = Set(current.map(\.note.id))
            for entry in previous where !survivors.contains(entry.note.id) {
                events.append(make(.deleted, entry.note))
            }

            previous = current
            return events
        }
    }

    /// Append with a single `O_APPEND` write. `FileHandle.seekToEnd` + `write`
    /// would be two syscalls with a window between them, which is a lost line the
    /// moment a second instance shares the file.
    private static func append(_ data: Data, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "AnnotKit: cannot open event log at \(path): \(String(cString: strerror(errno)))"
            ])
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                // A short write is only expected here if a signal interrupted the
                // call; loop rather than assume, and surface anything else.
                guard written > 0 else {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                        NSLocalizedDescriptionKey: "AnnotKit: cannot write event log at \(path): \(String(cString: strerror(errno)))"
                    ])
                }
                offset += written
            }
        }
    }
}
