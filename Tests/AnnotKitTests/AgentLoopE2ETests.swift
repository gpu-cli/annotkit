#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import AnnotKit
@testable import AnnotKitMCP

/// The epic's acceptance test, run against real processes rather than in-memory
/// doubles: two isolated embedding hosts are launched with NOTHING but an
/// environment, and the four things an agent needs are asserted from outside
/// them — that it can REPRODUCE the world a note was made in, LOCATE the note
/// where the launcher put it, REACT to it without being told, and never be
/// handed one instance's notes while reading another's.
///
/// `AnnotKitEnvProbe` is the host: the AnnotKitDemo story with the human taken
/// out. It mounts through the same `Annotation.install` path the demo uses, so
/// what is under test here is the shipping embedding contract and not a fixture.
final class AgentLoopE2ETests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the embedding e2e mounts an overlay; it needs a GUI session")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: Self.probeBinary.path),
                      "AnnotKitEnvProbe was not built at \(Self.probeBinary.path)")
        root = NSTemporaryDirectory() + "annotkit-e2e-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
    }

    /// `.build/<config>/AnnotKitEnvProbe`, found relative to the test bundle so it
    /// works for debug, release and a derived-data build alike.
    private static var probeBinary: URL {
        URL(fileURLWithPath: Bundle(for: AgentLoopE2ETests.self).bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AnnotKitEnvProbe")
    }

    /// One isolated instance's world: its own directory, its own three files.
    private struct World {
        let persona: String
        let directory: String
        var markdown: String { directory + "/notes.md" }
        var store: String { directory + "/notes.json" }
        var events: String { directory + "/events.jsonl" }

        func environment(comment: String, sharedEvents: String? = nil) -> [String: String] {
            [
                "ANNOTKIT_NOTES_MD": markdown,
                "ANNOTKIT_NOTES": store,
                "ANNOTKIT_EVENTS": sharedEvents ?? events,
                "ANNOTKIT_ROUTE": "Settings/\(persona)",
                "ANNOTKIT_CONTEXT_PERSONA": persona,
                "ANNOTKIT_CONTEXT": "appearance=dark,build=hmr-7",
                "ANNOTKIT_PROBE_COMMENT": comment
            ]
        }
    }

    private func world(_ persona: String) throws -> World {
        let directory = root + "/" + persona
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return World(persona: persona, directory: directory)
    }

    /// Launch the probe with EXACTLY this environment — `PATH` and the rest of the
    /// inherited env deliberately dropped, so a variable the developer happens to
    /// have exported cannot be what makes the test pass.
    private func launch(_ environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = Self.probeBinary
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func events(at path: String) throws -> [AnnotationEvent] {
        try read(path).split(separator: "\n").map {
            try JSONDecoder().decode(AnnotationEvent.self, from: Data($0.utf8))
        }
    }

    // MARK: -

    func testTwoIsolatedInstancesEachServeTheirOwnAgentLoop() throws {
        let ada = try world("ada")
        let grace = try world("grace")

        // (3) A `tail -f` style watcher, attached BEFORE anything is captured — the
        // agent is waiting, not polling. The log is touched first so `tail` can
        // follow it with kqueue from the start rather than falling back to its
        // once-a-second retry for a file that does not exist yet; a launcher that
        // creates the file it intends to watch is doing the ordinary thing, and the
        // sink opens it `O_CREAT|O_APPEND` either way.
        FileManager.default.createFile(atPath: ada.events, contents: nil)
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        watcher.arguments = ["-F", "-n", "0", ada.events]
        let tap = Pipe()
        watcher.standardOutput = tap
        watcher.standardError = Pipe()
        let firstLine = expectation(description: "the watcher is woken by a captured note")
        let seen = Locked<(line: Data, at: Date)?>(nil)
        tap.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            if seen.exchange((chunk, Date())) == nil { firstLine.fulfill() }
        }
        try watcher.run()
        defer { watcher.terminate() }

        // Both instances at once: cross-writing is a concurrency failure, so give it
        // the concurrency.
        let instances = [
            launch(ada.environment(comment: "the contrast is too low here")),
            launch(grace.environment(comment: "this label wraps at 320pt"))
        ]
        for instance in instances { try instance.run() }
        instances[0].waitUntilExit()
        // The probe exports and exits, so its exit is an upper bound on when the
        // capture hit the disk — and, unlike the event's own ISO-8601 stamp (whole
        // seconds, so up to a second of rounding in the wrong direction), it is a
        // measurement rather than a label.
        let capturedNoLaterThan = Date()
        instances[1].waitUntilExit()
        for instance in instances {
            XCTAssertEqual(instance.terminationStatus, 0, "the probe's own checks passed")
        }

        // (3) ...and the line arrived, without anyone telling the watcher to look.
        wait(for: [firstLine], timeout: 10)
        let (line, arrival) = try XCTUnwrap(seen.value)
        let event = try JSONDecoder().decode(
            AnnotationEvent.self,
            from: Data(String(decoding: line, as: UTF8.self).split(separator: "\n").first!.utf8)
        )
        XCTAssertLessThan(arrival.timeIntervalSince(capturedNoLaterThan), 1.0,
                          "an agent tailing the stream reacts within a second of the capture")
        XCTAssertEqual(event.event, .captured)
        XCTAssertEqual(event.note.context?["persona"], "ada")
        XCTAssertEqual(event.snapshot, ada.markdown,
                       "the line names the snapshot to open, so a fleet can share one log")

        // ...and the snapshot the line points at ALREADY has the note in it: the
        // stream may only wake a reader for something it can then actually read.
        XCTAssertTrue(try read(event.snapshot!).contains(event.note.comment))

        // (1) Both outputs carry the world, from the launcher and from the running
        // app together.
        let markdown = try read(ada.markdown)
        XCTAssertTrue(markdown.contains("## [\(event.id)] Settings/ada - #SaveButton"), markdown)
        XCTAssertTrue(
            markdown.contains(#"**Context**: appearance="dark", build="hmr-7", persona="ada", window="400x300""#),
            markdown
        )
        let store = try read(ada.store)
        XCTAssertTrue(store.contains("\"persona\" : \"ada\""), store)
        XCTAssertTrue(store.contains("\"window\" : \"400x300\""), "the provider's live value, not just the launcher's")

        // (2) The MCP bridge, pointed at the same store the launcher named, serves
        // the context to the agent.
        let dispatcher = MCPDispatcher(provider: FileNotesStore(path: ada.store))
        let response = try XCTUnwrap(dispatcher.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"annotation_get_pending","arguments":{}}}"#
        ))
        XCTAssertTrue(response.contains("the contrast is too low here"), response)
        XCTAssertTrue(response.contains("persona=ada"), response)
        XCTAssertFalse(response.contains("grace"), "one instance's bridge never serves another's notes")

        // (4) Neither instance touched the other's files.
        XCTAssertFalse(try read(ada.markdown).contains("grace"))
        XCTAssertFalse(try read(ada.markdown).contains("wraps at 320pt"))
        XCTAssertFalse(try read(grace.markdown).contains("ada"))
        XCTAssertFalse(try read(grace.markdown).contains("contrast is too low"))
        XCTAssertEqual(try events(at: ada.events).count, 1, "one capture, one line, in each world")
        XCTAssertEqual(try events(at: grace.events).map { $0.note.context?["persona"] }, ["grace"])
    }

    /// The other half of the multi-instance story: a fleet CHOOSING to share one
    /// event log, so a single watcher covers every world at once. The lines must
    /// survive being appended by two processes with no coordination between them.
    func testAFleetCanShareOneEventLogWithoutTearingItsLines() throws {
        let ada = try world("ada")
        let grace = try world("grace")
        let shared = root + "/fleet.jsonl"

        let instances = [
            launch(ada.environment(comment: "contrast", sharedEvents: shared)),
            launch(grace.environment(comment: "wrapping", sharedEvents: shared))
        ]
        for instance in instances { try instance.run() }
        for instance in instances { instance.waitUntilExit() }

        let recorded = try events(at: shared)
        XCTAssertEqual(recorded.count, 2, "both lines are present and both still parse")
        XCTAssertEqual(Set(recorded.compactMap { $0.note.context?["persona"] }), ["ada", "grace"])
        XCTAssertEqual(Set(recorded.compactMap(\.snapshot)), [ada.markdown, grace.markdown],
                       "each line sends the watcher to the right world's snapshot")
    }
}

/// A tiny box so the pipe's reader thread and the test thread can share one value
/// without a data race. XCTest's own expectation is the synchronization point;
/// this only guards the handoff.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// Store `next` and return what was there, so the caller can tell the FIRST
    /// write from the rest without a second lock acquisition.
    func exchange(_ next: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let previous = stored
        stored = next
        return previous
    }
}
#endif
