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

    func testFlushWritesAndClears() throws {
        let path = NSTemporaryDirectory() + "annotkit-session-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = AnnotationSession(
            source: StubSource(makeElement()), sink: NotesFileSink(path: path),
            timestamp: { "T" }, makeID: { "id1" }
        )
        session.start()
        session.select(atAXPoint: .zero)
        session.addNote(comment: "hello")
        try session.flush()
        XCTAssertTrue(session.pending.isEmpty)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("## [id1]"))
        XCTAssertTrue(contents.contains("hello"))
    }
}
