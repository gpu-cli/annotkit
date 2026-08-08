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

    func testMarkdownIncludesRegionLineForRegionNotes() {
        var n = note()
        n.regionOffset = CGPoint(x: 22, y: 114)
        let md = AnnotationFormatter.markdown([n])
        XCTAssertTrue(md.contains("**Region**: (x: 22, y: 114) from the top-left of #SaveButton"))
        XCTAssertFalse(AnnotationFormatter.markdown([note()]).contains("**Region**"),
                       "element notes have no region line")
    }

    func testMarkdownIncludesFramedRegionLineForMarqueeNotes() {
        // The exact shape a consuming skill parses — do not reword.
        var n = note(selector: "#Settings.Models")
        n.regionRect = CGRect(x: 12, y: 40, width: 320, height: 48)
        let md = AnnotationFormatter.markdown([n])
        XCTAssertTrue(
            md.contains("**Region**: framed 320x48 at (x: 12, y: 40) from the top-left of #Settings.Models"),
            md
        )
    }

    func testMarkdownKeepsThePointRegionLineUnchangedWithoutARect() {
        // The framed branch must not disturb the existing point-offset line: notes
        // captured before marquee existed still render exactly as they did.
        var n = note()
        n.regionOffset = CGPoint(x: 22, y: 114)
        XCTAssertTrue(AnnotationFormatter.markdown([n])
            .contains("**Region**: (x: 22, y: 114) from the top-left of #SaveButton"))
        XCTAssertFalse(AnnotationFormatter.markdown([n]).contains("framed"))
    }

    func testJSONCarriesTheFramedRectAsIntegers() throws {
        var n = note()
        n.regionRect = CGRect(x: 12, y: 40, width: 320, height: 48)
        let json = try AnnotationFormatter.json([n])
        XCTAssertTrue(json.contains("\"regionRectX\" : 12"))
        XCTAssertTrue(json.contains("\"regionRectY\" : 40"))
        XCTAssertTrue(json.contains("\"regionRectWidth\" : 320"))
        XCTAssertTrue(json.contains("\"regionRectHeight\" : 48"))
        XCTAssertFalse(try AnnotationFormatter.json([note()]).contains("regionRect"),
                       "click notes gain no rect keys")
    }

    func testRegionRectSurvivesAJSONRoundTrip() throws {
        var n = note()
        n.regionRect = CGRect(x: 12, y: 40, width: 320, height: 48)
        let data = try JSONEncoder().encode([n])
        let decoded = try JSONDecoder().decode([AnnotationNote].self, from: data)
        XCTAssertEqual(decoded[0].regionRect, CGRect(x: 12, y: 40, width: 320, height: 48),
                       "regionRect is PERSISTED, unlike `anchor`")
    }

    func testMarkdownIncludesComponentRoleAndUnseededHints() {
        var n = note()
        n.component = "Settings.Models"
        n.elementRole = "AXStaticText"
        n.elementText = "gpt-5"
        n.unseeded = true
        let md = AnnotationFormatter.markdown([n])
        XCTAssertTrue(md.contains("**Component**: #Settings.Models"))
        XCTAssertTrue(md.contains("**Element**: AXStaticText \"gpt-5\""))
        XCTAssertTrue(md.contains("**Unseeded**:"))

        // A seeded target omits the unseeded line; a note with no hints omits all.
        var seeded = note()
        seeded.unseeded = false
        seeded.component = "SaveButton"
        XCTAssertFalse(AnnotationFormatter.markdown([seeded]).contains("**Unseeded**"))
        XCTAssertFalse(AnnotationFormatter.markdown([note()]).contains("**Component**"))
    }

    func testJSONIncludesCodeHintsAndOmitsNilOnes() throws {
        var n = note()
        n.component = "Settings.Models"
        n.unseeded = true
        let json = try AnnotationFormatter.json([n])
        XCTAssertTrue(json.contains("\"component\" : \"Settings.Models\""))
        XCTAssertTrue(json.contains("\"unseeded\" : true"))
        // Nil hints are omitted, not encoded as null.
        XCTAssertFalse(try AnnotationFormatter.json([note()]).contains("component"))
    }

    func testOldShapeNoteDecodesWithNilRegionAndRoundTrips() throws {
        // A pre-region on-disk note (no regionOffset key) must decode with a nil
        // region and re-encode without gaining one.
        let old = Data("""
        [{"id":"a1","selector":"#X","elementPath":"AXWindow[0]","comment":"c","timestamp":"t"}]
        """.utf8)
        let notes = try JSONDecoder().decode([AnnotationNote].self, from: old)
        XCTAssertNil(notes[0].regionOffset)
        XCTAssertNil(notes[0].regionRect, "JSON predating the marquee field decodes with no rect")
        let reencoded = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("regionOffset"))
        XCTAssertFalse(reencoded.contains("regionRect"))
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
