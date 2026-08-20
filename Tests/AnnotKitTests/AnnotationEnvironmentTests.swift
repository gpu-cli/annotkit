import Foundation
import XCTest
@testable import AnnotKit

/// The launch-time embedding contract. Every case here is a thing a host that
/// runs many isolated instances of one binary has to be able to say in the env
/// dict it builds — and each is asserted against a literal dictionary, never
/// against the real process environment, which is neither thread-safe to mutate
/// nor reversible between tests.
final class AnnotationEnvironmentTests: XCTestCase {
    func testAnEmptyEnvironmentIsTheOldDefaults() {
        let environment = AnnotationEnvironment([:])
        XCTAssertEqual(environment.notesPath, "ANNOTKIT_NOTES.md")
        XCTAssertNil(environment.storePath, "the JSON store is opt-in — no second file appears unasked")
        XCTAssertNil(environment.eventsPath, "and so is the event stream")
        XCTAssertNil(environment.route)
        XCTAssertEqual(environment.context, [:])
    }

    func testEachDestinationIsNamedIndependently() {
        let environment = AnnotationEnvironment([
            "ANNOTKIT_NOTES_MD": "/w/ada/notes.md",
            "ANNOTKIT_NOTES": "/w/ada/notes.json",
            "ANNOTKIT_EVENTS": "/w/ada/events.jsonl"
        ])
        XCTAssertEqual(environment.notesPath, "/w/ada/notes.md")
        XCTAssertEqual(environment.storePath, "/w/ada/notes.json")
        XCTAssertEqual(environment.eventsPath, "/w/ada/events.jsonl")
    }

    /// `ANNOTKIT_NOTES` is the variable `annotkit-mcp` already reads for the JSON
    /// store. If it ever came to mean the markdown file here, a host wiring an
    /// instance to its agent by passing one env dict to both processes would point
    /// them at two different files and the bridge would silently serve nothing.
    func testAnnotkitNotesNamesTheJSONStoreTheMCPServerReads() {
        let environment = AnnotationEnvironment(["ANNOTKIT_NOTES": "/w/ada/notes.json"])
        XCTAssertEqual(environment.storePath, "/w/ada/notes.json")
        XCTAssertEqual(environment.notesPath, "ANNOTKIT_NOTES.md", "and it does NOT move the markdown")
    }

    func testAnEmptyValueMeansUnsetRatherThanAPathCalledEmptyString() {
        let environment = AnnotationEnvironment([
            "ANNOTKIT_EVENTS": "", "ANNOTKIT_NOTES": "   ", "ANNOTKIT_ROUTE": ""
        ])
        XCTAssertNil(environment.eventsPath)
        XCTAssertNil(environment.storePath)
        XCTAssertNil(environment.route)
    }

    func testAPathTildeIsExpanded() {
        let environment = AnnotationEnvironment(["ANNOTKIT_NOTES_MD": "~/notes.md"])
        XCTAssertFalse(environment.notesPath.hasPrefix("~"), environment.notesPath)
        XCTAssertTrue(environment.notesPath.hasSuffix("/notes.md"))
    }

    func testContextComesFromEitherSpellingAndPerKeyWins() {
        let environment = AnnotationEnvironment([
            "ANNOTKIT_CONTEXT": "persona=ada, appearance=dark,build=hmr-7",
            "ANNOTKIT_CONTEXT_PERSONA": "grace",
            "ANNOTKIT_CONTEXT_WINDOW_SIZE": "1280x800"
        ])
        XCTAssertEqual(environment.context, [
            "persona": "grace",          // the specific statement beats the list
            "appearance": "dark",
            "build": "hmr-7",
            "window_size": "1280x800"    // key lowercased out of the shouted env name
        ])
    }

    func testMalformedContextEntriesAreDroppedRatherThanGuessedAt() {
        let environment = AnnotationEnvironment(["ANNOTKIT_CONTEXT": "persona,=orphan,build=,route=/settings"])
        XCTAssertEqual(environment.context, ["route": "/settings"])
    }

    /// The provider runs at capture and the environment was frozen at launch, so on
    /// a shared key the provider is simply the newer measurement.
    func testTheHostProviderWinsOverTheLauncherOnASharedKey() {
        let environment = AnnotationEnvironment([
            "ANNOTKIT_CONTEXT": "persona=ada,appearance=dark"
        ])
        XCTAssertEqual(environment.merging(["appearance": "light", "window": "400x300"]), [
            "persona": "ada", "appearance": "light", "window": "400x300"
        ])
        XCTAssertEqual(environment.merging([:]), ["persona": "ada", "appearance": "dark"],
                       "a host that registers no provider keeps exactly what it launched with")
    }

    func testTheGateIsOverriddenByTheEnvironmentAndDisableWins() {
        XCTAssertTrue(AnnotationEnvironment([:]).isEnabled(byDefault: true))
        XCTAssertFalse(AnnotationEnvironment([:]).isEnabled(byDefault: false))
        XCTAssertTrue(AnnotationEnvironment(["ANNOTKIT_ENABLE": "1"]).isEnabled(byDefault: false))
        XCTAssertFalse(AnnotationEnvironment(["ANNOTKIT_DISABLE": "1"]).isEnabled(byDefault: true))
        XCTAssertFalse(
            AnnotationEnvironment(["ANNOTKIT_ENABLE": "1", "ANNOTKIT_DISABLE": "1"]).isEnabled(byDefault: true),
            "a launcher can suppress the overlay without auditing the env it inherited"
        )
    }

    // MARK: - What install() would write

    @MainActor
    func testTheDefaultInstallWritesOnlyTheMarkdownSnapshot() {
        let sink = Annotation.sink(for: AnnotationEnvironment([:]))
        let notes = try? XCTUnwrap(sink as? NotesFileSink)
        XCTAssertEqual(notes?.path, "ANNOTKIT_NOTES.md")
        XCTAssertNil(sink as? MultiSink, "no fan-out until the environment asks for one")
    }

    @MainActor
    func testAFullyConfiguredInstanceWritesAllThreeDestinations() throws {
        let sink = Annotation.sink(for: AnnotationEnvironment([
            "ANNOTKIT_NOTES_MD": "/w/ada/notes.md",
            "ANNOTKIT_NOTES": "/w/ada/notes.json",
            "ANNOTKIT_EVENTS": "/w/ada/events.jsonl"
        ]))
        let multi = try XCTUnwrap(sink as? MultiSink)
        XCTAssertEqual((multi.sinks[0] as? NotesFileSink)?.path, "/w/ada/notes.md")
        XCTAssertEqual((multi.sinks[1] as? JSONFileSink)?.path, "/w/ada/notes.json")
        let events = try XCTUnwrap(multi.sinks[2] as? JSONLEventSink)
        XCTAssertEqual(events.path, "/w/ada/events.jsonl")
        XCTAssertEqual(events.snapshotPath, "/w/ada/notes.md",
                       "every event names the snapshot a woken reader should open")
    }
}
