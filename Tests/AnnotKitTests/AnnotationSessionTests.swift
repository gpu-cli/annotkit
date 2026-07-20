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

/// A source whose hit-test result can be swapped mid-test: nil first (region
/// path), then a real element (re-selection path).
@MainActor
private final class SwitchableSource: ElementSource, RegionAnchorSource {
    let anchor: Element
    var hit: Element?
    init(anchor: Element) { self.anchor = anchor }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { hit }
    func regionAnchor(at point: CGPoint) -> Element? { anchor }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

/// A source with NO element anywhere but a fixed nearby anchor, driving the
/// region-fallback path.
@MainActor
private final class EmptyWithAnchorSource: ElementSource, RegionAnchorSource {
    let anchor: Element
    init(anchor: Element) { self.anchor = anchor }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { nil }
    func regionAnchor(at point: CGPoint) -> Element? { anchor }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

/// A source that hit-tests to a leaf and exposes a widening ladder (leaf, then
/// enclosing components), driving selection-widening tests.
@MainActor
private final class LadderSource: ElementSource, ComponentLadderSource {
    let ladder: [Element]
    init(ladder: [Element]) { self.ladder = ladder }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { ladder.first }
    func componentLadder(at point: CGPoint) -> [Element] { ladder }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

@MainActor
final class AnnotationSessionTests: XCTestCase {
    private func makeLadderElement(_ id: String) -> Element {
        Element(
            id: id, role: "AXGroup", type: "AXGroup", label: id, value: "",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10), isVisible: true, isActionable: false,
            path: [PathComponent(role: "AXGroup", label: id, identifier: id, indexAmongRole: 0)]
        )
    }

    func testWidenSelectionStepsUpTheComponentLadder() {
        let ladder = [makeLadderElement("Leaf"), makeLadderElement("Settings.Models"), makeLadderElement("Settings")]
        let session = AnnotationSession(source: LadderSource(ladder: ladder), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "Leaf", "selection starts at the hit-test target")
        XCTAssertTrue(session.canWidenSelection)

        XCTAssertEqual(session.widenSelection()?.id, "Settings.Models", "widen -> enclosing component")
        XCTAssertTrue(session.canWidenSelection)
        XCTAssertEqual(session.widenSelection()?.id, "Settings", "widen -> broader component")
        XCTAssertFalse(session.canWidenSelection, "no widening past the broadest rung")
        XCTAssertNil(session.widenSelection(), "widen at the top is a no-op")
    }

    func testWideningResetsOnNewSelectionAndCapture() {
        let ladder = [makeLadderElement("Leaf"), makeLadderElement("Card")]
        let session = AnnotationSession(source: LadderSource(ladder: ladder), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        session.widenSelection()
        XCTAssertEqual(session.selected?.id, "Card")
        // A fresh selection restarts the ladder at the leaf.
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "Leaf")
        XCTAssertTrue(session.canWidenSelection)
        // Capturing clears the ladder (no widening with nothing selected).
        session.addNote(comment: "note")
        XCTAssertFalse(session.canWidenSelection)
    }

    /// An unseeded target whose enclosing card is only reachable via the GEOMETRIC
    /// ladder (a `.axCardSurface` sibling, not an ancestor) still gets its
    /// `component` set to that card — the ladder's tightest enclosing entry, not
    /// the target's ancestry.
    func testUnseededTargetTakesComponentFromGeometricLadder() {
        // Leaf with no identifier of its own; the card is a separate ladder entry
        // (as a sibling surface would be), not in the leaf's path.
        let leaf = Element(
            id: "AXWindow[0]/AXStaticText[0]", role: "AXStaticText", type: "AXStaticText",
            label: "", value: "9:00 Standup", frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            isVisible: true, isActionable: false,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXStaticText", label: "", identifier: nil, indexAmongRole: 0),
            ]
        )
        let card = makeLadderElement("Dashboard.Today")
        let session = AnnotationSession(
            source: LadderSource(ladder: [leaf, card]), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        session.select(atAXPoint: .zero)
        let note = session.addNote(comment: "c")
        XCTAssertEqual(note?.unseeded, true)
        XCTAssertEqual(note?.component, "Dashboard.Today", "component comes from the enclosing ladder entry, not ancestry")
        XCTAssertEqual(note?.elementText, "9:00 Standup")
    }

    func testRegionSelectionCannotWiden() {
        let anchor = makeElement()
        let session = AnnotationSession(
            source: EmptyWithAnchorSource(anchor: anchor), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        session.select(atAXPoint: CGPoint(x: 5, y: 5))
        XCTAssertEqual(session.selected?.role, "AXRegion")
        XCTAssertFalse(session.canWidenSelection, "region notes have no widening ladder")
    }

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

    func testRegionFallbackCapturesAnchoredNote() {
        // A source with NO element at any point but a nearby anchor — the
        // region-fallback case (decoration, dividers, gaps).
        let anchor = makeElement()
        let session = AnnotationSession(
            source: EmptyWithAnchorSource(anchor: anchor),
            sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let selected = session.select(atAXPoint: CGPoint(x: 22, y: 14))
        XCTAssertEqual(selected?.role, "AXRegion", "a no-hit click selects a synthetic region")
        XCTAssertEqual(selected?.id, "SaveButton", "the region carries the anchor's id")
        XCTAssertEqual(session.selectedRegionOffset, CGPoint(x: 22, y: 14), "offset from the anchor's top-left")
        let note = session.addNote(comment: "gap looks off")
        XCTAssertEqual(note?.selector, "#SaveButton", "region note anchors to the nearest meaningful element")
        XCTAssertEqual(note?.regionOffset, CGPoint(x: 22, y: 14))
        XCTAssertNil(session.selectedRegionOffset, "offset clears with the selection")
    }

    func testElementSelectionCarriesNoRegionOffset() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertNil(session.selectedRegionOffset)
        let note = session.addNote(comment: "plain")
        XCTAssertNil(note?.regionOffset, "ordinary element notes have no region")
    }

    func testRegionThenElementReselectionDropsTheStaleOffset() {
        // The catcher stays active behind an open composer, so region -> element
        // re-selection without cancelling is a supported flow; the element note
        // must NOT inherit the region's offset.
        let anchor = makeElement()
        let source = SwitchableSource(anchor: anchor)
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: CGPoint(x: 22, y: 14))
        XCTAssertEqual(session.selected?.role, "AXRegion", "first click lands the region")
        source.hit = anchor
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.role, "AXButton", "second click re-selects a real element")
        XCTAssertNil(session.selectedRegionOffset, "the region offset must not survive re-selection")
        let note = session.addNote(comment: "element after region")
        XCTAssertNil(note?.regionOffset, "element note must not inherit the stale region offset")
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

    func testAddNotePopulatesCodeHintsForSeededTarget() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        let note = session.addNote(comment: "c")
        XCTAssertEqual(note?.component, "SaveButton", "the target's own identifier is the component")
        XCTAssertEqual(note?.unseeded, false, "a seeded target is not flagged unseeded")
        XCTAssertEqual(note?.elementRole, "AXButton")
    }

    func testAddNoteFlagsUnseededTargetAndAnchorsToNearestSeededAncestor() {
        let unseededLeaf = Element(
            id: "AXWindow[0]/#Settings.Models/AXStaticText[0]", role: "AXStaticText", type: "AXStaticText",
            label: "", value: "gpt-5", frame: CGRect(x: 0, y: 0, width: 4, height: 4),
            isVisible: true, isActionable: false,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXGroup", label: "", identifier: "Settings.Models", indexAmongRole: 0),
                PathComponent(role: "AXStaticText", label: "", identifier: nil, indexAmongRole: 0),
            ]
        )
        let session = AnnotationSession(source: StubSource(unseededLeaf), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        let note = session.addNote(comment: "c")
        XCTAssertEqual(note?.component, "Settings.Models", "anchors to the nearest seeded ancestor")
        XCTAssertEqual(note?.unseeded, true, "an id-less target is flagged for seeding")
        XCTAssertEqual(note?.elementText, "gpt-5")
        XCTAssertEqual(note?.elementRole, "AXStaticText")
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
