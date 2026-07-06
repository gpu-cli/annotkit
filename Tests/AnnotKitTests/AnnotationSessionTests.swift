import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit

/// A canned ElementSource so the session can be tested without a window.
@MainActor
private final class StubSource: ElementSource {
    let element: Element
    init(_ element: Element) { self.element = element }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { element }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

@MainActor
final class AnnotationSessionTests: XCTestCase {
    private func makeElement() -> Element {
        Element(
            id: "SaveButton", role: "AXButton", type: "AXButton", label: "Save", value: "",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10), isVisible: true, isActionable: true,
            path: [
                PathComponent(role: "AXWindow", label: "W", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXButton", label: "Save", identifier: "SaveButton", indexAmongRole: 0)
            ]
        )
    }

    func testClearHoverDropsHighlightButKeepsSelection() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.hover(atAXPoint: .zero)
        XCTAssertEqual(session.hovered?.id, "SaveButton", "hover resolves the element")
        session.select(atAXPoint: .zero)
        session.clearHover()
        XCTAssertNil(session.hovered, "clearHover drops the hover highlight")
        XCTAssertEqual(session.selected?.id, "SaveButton", "clearHover must not touch the selection (open composer)")
    }

    func testSelectIsGatedOnAnnotatingMode() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        XCTAssertNil(session.select(atAXPoint: .zero), "select before start must be nil")
        session.start()
        XCTAssertEqual(session.select(atAXPoint: .zero)?.id, "SaveButton")
    }

    func testAddNoteBuildsAgentationFields() {
        let session = AnnotationSession(
            source: StubSource(makeElement()),
            sink: NotesFileSink(path: "/dev/null"),
            route: { "Settings/Models" },
            timestamp: { "2026-06-29T00:00:00Z" },
            makeID: { "fixed1" }
        )
        session.start()
        session.select(atAXPoint: .zero)
        let note = session.addNote(comment: "low contrast")
        XCTAssertEqual(note?.id, "fixed1")
        XCTAssertEqual(note?.route, "Settings/Models")
        XCTAssertEqual(note?.selector, "#SaveButton")
        XCTAssertEqual(note?.elementPath, "AXWindow[0] > #SaveButton")
        XCTAssertEqual(session.pending.count, 1)
        XCTAssertNil(session.selected, "selection clears after capture")
    }

    /// A session whose ids auto-increment (id1, id2, ...) so a captured set is
    /// distinguishable in the exported file.
    private func makeSession(path: String) -> AnnotationSession {
        var counter = 0
        return AnnotationSession(
            source: StubSource(makeElement()), sink: NotesFileSink(path: path),
            timestamp: { "T" }, makeID: { counter += 1; return "id\(counter)" }
        )
    }

    private func capture(_ session: AnnotationSession, comment: String) {
        session.select(atAXPoint: .zero)
        session.addNote(comment: comment)
    }

    func testAddNoteAppendsAndRetains() {
        let session = makeSession(path: "/dev/null")
        session.start()
        capture(session, comment: "one")
        capture(session, comment: "two")
        capture(session, comment: "three")
        // addNote APPENDS; nothing auto-clears the retained set.
        XCTAssertEqual(session.pending.map(\.id), ["id1", "id2", "id3"])
        XCTAssertEqual(session.pending.map(\.comment), ["one", "two", "three"])
    }

    func testExportWritesFullSetAndRetains() throws {
        let path = NSTemporaryDirectory() + "annotkit-session-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = makeSession(path: path)
        session.start()
        capture(session, comment: "hello")
        capture(session, comment: "world")

        try session.export()
        // Export retains the set (does NOT clear) so it can be exported/copied again.
        XCTAssertEqual(session.pending.count, 2, "export must not clear the retained set")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("## [id1]") && contents.contains("hello"))
        XCTAssertTrue(contents.contains("## [id2]") && contents.contains("world"))
    }

    func testCopyRendersFullSetWithoutClearing() throws {
        let session = makeSession(path: "/dev/null")
        session.start()
        capture(session, comment: "alpha")
        capture(session, comment: "beta")
        // Copy is a render of the retained set through ClipboardSink; it reads
        // `pending` and must not mutate it (same set stays copyable + exportable).
        let copied = try ClipboardSink(format: .markdown).render(session.pending)
        XCTAssertTrue(copied.contains("alpha") && copied.contains("beta"))
        XCTAssertEqual(session.pending.count, 2, "copy must not clear the retained set")
    }

    func testOnlyClearEmptiesTheRetainedSet() throws {
        let path = NSTemporaryDirectory() + "annotkit-clear-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = makeSession(path: path)
        session.start()
        capture(session, comment: "keep me")
        try session.export()
        _ = try ClipboardSink().render(session.pending)
        XCTAssertEqual(session.pending.count, 1, "neither export nor copy clears")
        session.clear()
        XCTAssertTrue(session.pending.isEmpty, "clear empties the set")
    }

    func testExportIsIdempotentAcrossReExportAndMoreNotes() throws {
        let path = NSTemporaryDirectory() + "annotkit-idem-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = makeSession(path: path)
        session.start()
        capture(session, comment: "one")

        // Re-exporting the same set must not duplicate it.
        try session.export()
        try session.export()
        var contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "## [id1]").count, 2, "note appears exactly once after double export")
        XCTAssertEqual(contents.components(separatedBy: "# Agentation Notes").count, 2, "single header")

        // Capturing more then re-exporting yields the FULL set, first note still once.
        capture(session, comment: "two")
        try session.export()
        contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "## [id1]").count, 2, "first note still appears once")
        XCTAssertTrue(contents.contains("## [id2]") && contents.contains("two"))
        XCTAssertEqual(contents.components(separatedBy: "# Agentation Notes").count, 2, "still a single header")
    }
}
