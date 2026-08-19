import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit

/// The watchable half of the loop: the append-only JSONL stream that exists
/// purely so an agent hears about a note instead of polling for one.
final class EventStreamTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "annotkit-events-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func path(_ name: String) -> String { directory + "/" + name }

    private func note(
        id: String = "abc123",
        comment: String = "Contrast is too low here.",
        context: [String: String]? = nil
    ) -> AnnotationNote {
        AnnotationNote(
            id: id, route: "Settings/Models", selector: "#SaveButton",
            elementPath: "AXWindow > AXButton[0]", comment: comment,
            timestamp: "2026-06-29T10:25:00Z", context: context
        )
    }

    private func events(at path: String) throws -> [AnnotationEvent] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(AnnotationEvent.self, from: Data($0.utf8))
        }
    }

    func testEachLifecycleStageProducesExactlyOneLine() throws {
        let log = path("events.jsonl")
        let sink = JSONLEventSink(path: log, snapshot: path("notes.md"), timestamp: { "T" })

        try sink.flush([note(id: "one")])
        try sink.flush([note(id: "one"), note(id: "two")])
        try sink.flush([note(id: "one", comment: "actually the spacing"), note(id: "two")])
        try sink.flush([note(id: "two")])

        let recorded = try events(at: log)
        XCTAssertEqual(recorded.map(\.event), [.captured, .captured, .edited, .deleted])
        XCTAssertEqual(recorded.map(\.id), ["one", "two", "one", "one"])
        XCTAssertEqual(recorded.last?.note.comment, "actually the spacing",
                       "a delete carries the note as it last stood, so a reader need not have kept it")
        XCTAssertEqual(recorded[0].snapshot, path("notes.md"),
                       "each line says which snapshot to open — the point of a shared log")
    }

    /// The snapshot sinks re-write the SAME full set on every export, so a stream
    /// that echoed each flush would announce the same note again and again and
    /// train an agent to ignore it.
    func testAReExportOfAnUnchangedSetSaysNothing() throws {
        let log = path("events.jsonl")
        let sink = JSONLEventSink(path: log, timestamp: { "T" })
        try sink.flush([note()])
        let afterFirst = try Data(contentsOf: URL(fileURLWithPath: log))
        try sink.flush([note()])
        try sink.flush([note()])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: log)), afterFirst,
                       "nothing changed, so not one byte was appended")
    }

    /// A scroll moves every pin in the window. None of that is visible to an agent,
    /// so none of it may wake one.
    func testMovingANoteOnScreenIsNotAnEdit() throws {
        let log = path("events.jsonl")
        let sink = JSONLEventSink(path: log, timestamp: { "T" })
        var scrolled = note()
        scrolled.anchorRect = CGRect(x: 10, y: 10, width: 100, height: 20)
        try sink.flush([note()])
        let afterFirst = try Data(contentsOf: URL(fileURLWithPath: log))
        try sink.flush([scrolled])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: log)), afterFirst)

        // ...while the comment the agent reads IS an edit.
        try sink.flush([note(comment: "changed")])
        XCTAssertEqual(try events(at: log).map(\.event), [.captured, .edited])
    }

    func testTheStreamIsAppendOnlyAcrossSinkLifetimes() throws {
        let log = path("events.jsonl")
        try JSONLEventSink(path: log, timestamp: { "T" }).flush([note(id: "one")])
        // A fresh sink (a relaunched instance) appends; it never truncates.
        try JSONLEventSink(path: log, timestamp: { "T" }).flush([note(id: "two")])
        XCTAssertEqual(try events(at: log).map(\.id), ["one", "two"])
    }

    func testEveryLineIsOneLineEvenWhenTheCommentIsNot() throws {
        let log = path("events.jsonl")
        try JSONLEventSink(path: log, timestamp: { "T" })
            .flush([note(comment: "first line\nsecond line\n\nthird")])
        let raw = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertEqual(raw.filter { $0 == "\n" }.count, 1, "a multi-line comment must not become four events")
        XCTAssertEqual(try events(at: log).first?.note.comment, "first line\nsecond line\n\nthird")
    }

    func testTheWorldContextRidesOnTheEventLineToo() throws {
        let log = path("events.jsonl")
        try JSONLEventSink(path: log, timestamp: { "T" })
            .flush([note(context: ["persona": "ada", "appearance": "dark"])])
        XCTAssertEqual(try events(at: log).first?.note.context, ["persona": "ada", "appearance": "dark"],
                       "a woken agent knows which world to relaunch from the line alone")
    }

    /// A line that has to be readable by `tail`, `jq` and a `while read` loop
    /// cannot carry a base64 PNG — the pixels are in the snapshot for whoever
    /// wants them.
    func testAScreenshotNeverGoesOnTheWire() throws {
        let log = path("events.jsonl")
        var shot = note()
        shot.screenshot = CapturedImage(pngData: Data(repeating: 0xAB, count: 4096),
                                        pixelWidth: 120, pixelHeight: 32)
        let sink = JSONLEventSink(path: log, timestamp: { "T" })
        try sink.flush([shot])
        let raw = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertFalse(raw.contains("pngData"), raw.prefix(200).description)
        XCTAssertLessThan(raw.count, 1024, "one line, not one image")

        // ...and re-encoding the image is not an edit either.
        var reshot = shot
        reshot.screenshot = CapturedImage(pngData: Data(repeating: 0xCD, count: 4096),
                                          pixelWidth: 120, pixelHeight: 32)
        try sink.flush([reshot])
        XCTAssertEqual(try events(at: log).map(\.event), [.captured])
    }

    // MARK: - Fan-out

    func testTheSnapshotAndTheStreamAreWrittenByTheSameFlush() throws {
        let markdown = path("notes.md")
        let store = path("notes.json")
        let log = path("events.jsonl")
        let sink = MultiSink([
            NotesFileSink(path: markdown),
            JSONFileSink(path: store),
            JSONLEventSink(path: log, snapshot: markdown, timestamp: { "T" })
        ])
        try sink.flush([note(context: ["persona": "ada"])])

        XCTAssertTrue(try String(contentsOfFile: markdown, encoding: .utf8).contains("persona=\"ada\""))
        XCTAssertTrue(try String(contentsOfFile: store, encoding: .utf8).contains("\"persona\" : \"ada\""))
        XCTAssertEqual(try events(at: log).count, 1,
                       "the reader the line wakes always finds the note already in the snapshot")
    }

    /// A full disk on the optional event stream must not cost the user the note.
    func testAFailingSinkDoesNotStopTheOthers() throws {
        let markdown = path("notes.md")
        let unwritable = "/dev/null/nope/events.jsonl"
        let sink = MultiSink([JSONLEventSink(path: unwritable), NotesFileSink(path: markdown)])
        XCTAssertThrowsError(try sink.flush([note()]), "the failure is reported, not swallowed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdown),
                      "and the snapshot — the record that matters — was still written")
    }

    /// The claim in ``JSONLEventSink``'s header, tested rather than asserted: several
    /// isolated instances can share one log and a single watcher sees a whole fleet.
    func testConcurrentAppendsFromManyInstancesInterleaveWithoutTearing() throws {
        let log = path("fleet.jsonl")
        let instances = (0..<8).map { index in
            (index, JSONLEventSink(path: log, snapshot: path("world-\(index).md"), timestamp: { "T" }))
        }
        DispatchQueue.concurrentPerform(iterations: instances.count) { slot in
            let (index, sink) = instances[slot]
            try? sink.flush([note(id: "note-\(index)", context: ["persona": "p\(index)"])])
        }
        let recorded = try events(at: log)
        XCTAssertEqual(Set(recorded.map(\.id)).count, 8, "every line survived, and every line still parses")
        XCTAssertEqual(Set(recorded.compactMap(\.snapshot)).count, 8, "each names its own world's snapshot")
    }
}
