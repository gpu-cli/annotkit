import Foundation
import XCTest
@testable import AnnotKit

final class SinkTests: XCTestCase {
    private func note(
        id: String = "abc123",
        route: String? = "Settings/Models",
        selector: String = "#SaveButton",
        elementPath: String = "AXWindow > AXGroup[1] > AXButton[0]",
        selectedText: String? = nil,
        comment: String = "Contrast is too low here."
    ) -> AnnotationNote {
        AnnotationNote(
            id: id, route: route, selector: selector, elementPath: elementPath,
            selectedText: selectedText, comment: comment,
            timestamp: "2026-06-29T10:25:00Z"
        )
    }

    func testMarkdownBlockMatchesAgentationFormat() {
        let md = AnnotationFormatter.markdown([note(selectedText: "Upgrade to Pro")])
        XCTAssertTrue(md.hasPrefix("# Agentation Notes"))
        XCTAssertTrue(md.contains("\n---\n"))
        XCTAssertTrue(md.contains("## [abc123] Settings/Models - #SaveButton"))
        XCTAssertTrue(md.contains("**Timestamp**: 2026-06-29T10:25:00Z"))
        XCTAssertTrue(md.contains("**Element Path**: AXWindow > AXGroup[1] > AXButton[0]"))
        XCTAssertTrue(md.contains("**Selected Text**: \"Upgrade to Pro\""))
        XCTAssertTrue(md.contains("Contrast is too low here."))
    }

    func testMarkdownOmitsSelectedTextWhenAbsent() {
        let md = AnnotationFormatter.markdown([note(selectedText: nil)])
        XCTAssertFalse(md.contains("Selected Text"))
    }

    func testJSONOmitsRawScreenshotButKeepsDimensions() throws {
        var n = note()
        n.screenshot = CapturedImage(pngData: Data([0, 1, 2, 3]), pixelWidth: 120, pixelHeight: 32)
        let json = try AnnotationFormatter.json([n])
        XCTAssertTrue(json.contains("\"screenshotPixelWidth\" : 120"))
        XCTAssertFalse(json.contains("pngData"))
        XCTAssertFalse(json.contains("AAEC")) // base64 of the bytes must not appear
    }

    func testClipboardSinkRenderMarkdownAndJSON() throws {
        XCTAssertTrue(try ClipboardSink(format: .markdown).render([note()]).contains("## [abc123]"))
        XCTAssertTrue(try ClipboardSink(format: .json).render([note()]).contains("\"id\" : \"abc123\""))
    }

    func testNotesFileSinkWritesFullSetIdempotently() throws {
        let path = NSTemporaryDirectory() + "annotkit-sink-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = NotesFileSink(path: path)

        // Writing the full set produces the document under a single header.
        try sink.flush([note(id: "first"), note(id: "second")])
        var contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("# Agentation Notes"))
        XCTAssertTrue(contents.contains("## [first]"))
        XCTAssertTrue(contents.contains("## [second]"))
        XCTAssertEqual(contents.components(separatedBy: "# Agentation Notes").count, 2)

        // Re-writing the SAME set overwrites (idempotent) — no duplication.
        try sink.flush([note(id: "first"), note(id: "second")])
        contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "## [first]").count, 2, "first appears exactly once")
        XCTAssertEqual(contents.components(separatedBy: "# Agentation Notes").count, 2, "single header")

        // Writing a superset replaces the file with the full current set, and the
        // earlier notes are still present exactly once.
        try sink.flush([note(id: "first"), note(id: "second"), note(id: "third")])
        contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("## [third]"))
        XCTAssertEqual(contents.components(separatedBy: "## [first]").count, 2)

        // Writing a subset replaces (notes no longer in the set drop out).
        try sink.flush([note(id: "third")])
        contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains("## [first]"), "overwrite drops notes no longer in the set")
        XCTAssertTrue(contents.contains("## [third]"))
    }

    func testEmptyFlushIsNoop() throws {
        let path = NSTemporaryDirectory() + "annotkit-empty-\(UUID().uuidString).md"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try NotesFileSink(path: path).flush([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
