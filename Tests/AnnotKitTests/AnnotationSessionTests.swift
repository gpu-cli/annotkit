import CoreGraphics
import Foundation
import XCTest
@testable import AnnotKit

/// A canned ElementSource so the session can be tested without a window.
///
/// Counts hit-tests, because "no highlight appeared" is a weaker assertion than the
/// behaviour actually wanted: a suppressed highlight that still ran the query would
/// pass it while burning one cross-process AX round trip per pointer-motion event.
@MainActor
private final class StubSource: ElementSource {
    let element: Element
    private(set) var hitTests = 0
    init(_ element: Element) { self.element = element }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? {
        hitTests += 1
        return element
    }
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

/// A source that hit-tests to a leaf and exposes a component ladder (leaf, then
/// enclosing components), driving upward-navigation tests.
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

/// A ladder source that ALSO answers child queries, so one test can drive a
/// selection both up and down the tree. Records every query so a test can prove
/// the session cached instead of re-asking (and that a region never asks at all).
@MainActor
private final class NavigableSource: ElementSource, ComponentLadderSource, ChildNavigationSource, RegionAnchorSource {
    let ladder: [Element]
    let anchor: Element?
    /// Children keyed by the parent's id, so a test can shape a whole subtree —
    /// and swap a branch mid-test to prove a re-descent does NOT re-query.
    var childrenByID: [String: [Element]]
    private(set) var childQueries: [String] = []
    private(set) var lastHint: CGPoint?

    init(ladder: [Element], childrenByID: [String: [Element]] = [:], anchor: Element? = nil) {
        self.ladder = ladder
        self.childrenByID = childrenByID
        self.anchor = anchor
    }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { ladder.first }
    func componentLadder(at point: CGPoint) -> [Element] { ladder }
    func regionAnchor(at point: CGPoint) -> Element? { anchor }
    func children(of element: Element, near hint: CGPoint?) -> [Element] {
        childQueries.append(element.id)
        lastHint = hint
        return childrenByID[element.id] ?? []
    }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

/// A source that serves a marquee ladder AND a point hit-test (and optionally a
/// region anchor), so one test can interleave drags and clicks — the mixed flow
/// the catcher actually produces, and the one that surfaces stale per-selection
/// state.
@MainActor
private final class MarqueeSource: ElementSource, MarqueeTargetSource, RegionAnchorSource {
    var ladder: [Element]
    var hit: Element?
    var anchor: Element?
    /// The last rect handed to ``marqueeLadder(in:)`` — lets a test assert the
    /// session normalized before delegating.
    private(set) var lastRect: CGRect?

    init(ladder: [Element], hit: Element? = nil, anchor: Element? = nil) {
        self.ladder = ladder
        self.hit = hit
        self.anchor = anchor
    }
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { hit }
    func marqueeLadder(in rect: CGRect) -> [Element] {
        lastRect = rect
        return ladder
    }
    func regionAnchor(at point: CGPoint) -> Element? { anchor }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

@MainActor
final class AnnotationSessionTests: XCTestCase {
    private func makeLadderElement(_ id: String, frame: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10)) -> Element {
        Element(
            id: id, role: "AXGroup", type: "AXGroup", label: id, value: "",
            frame: frame, isVisible: true, isActionable: false,
            path: [PathComponent(role: "AXGroup", label: id, identifier: id, indexAmongRole: 0)]
        )
    }

    func testSelectParentStepsUpTheSelectionPath() {
        let ladder = [makeLadderElement("Leaf"), makeLadderElement("Settings.Models"), makeLadderElement("Settings")]
        let session = AnnotationSession(source: LadderSource(ladder: ladder), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "Leaf", "selection starts at the hit-test target")
        XCTAssertTrue(session.canSelectParent)
        XCTAssertFalse(session.canSelectChild, "nothing below the deepest rung, and no history yet")

        XCTAssertEqual(session.selectParent()?.id, "Settings.Models", "parent -> enclosing component")
        XCTAssertTrue(session.canSelectParent)
        XCTAssertEqual(session.selectParent()?.id, "Settings", "parent -> broader component")
        XCTAssertFalse(session.canSelectParent, "no stepping past the broadest rung")
        XCTAssertNil(session.selectParent(), "parent at the top is a no-op")
    }

    /// The overshoot case the one-way Widen button could not undo: every upward
    /// step must be walkable back down through HISTORY, with no source involved.
    func testSelectChildWalksBackDownThroughHistory() {
        let ladder = [makeLadderElement("Leaf"), makeLadderElement("Settings.Models"), makeLadderElement("Settings")]
        let source = NavigableSource(ladder: ladder)
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        session.selectParent()
        session.selectParent()
        XCTAssertEqual(session.selected?.id, "Settings")
        XCTAssertTrue(session.canSelectChild, "an ascended selection can always come back down")

        XCTAssertEqual(session.selectChild()?.id, "Settings.Models", "child -> back down one rung")
        XCTAssertEqual(session.selectChild()?.id, "Leaf", "child -> back to the original target")
        XCTAssertFalse(session.canSelectChild, "the leaf has no children and no history left")
        XCTAssertNil(session.selectChild(), "child at a childless deepest rung is a no-op")
    }

    /// Below the deepest KNOWN rung there is no history, so the source is asked —
    /// and the answer is PREPENDED, keeping index 0 "the deepest known rung" and
    /// leaving the original target reachable with Parent.
    func testSelectChildDescendsBelowTheDeepestRungAndKeepsTheParentReachable() {
        let target = makeLadderElement("Card")
        let row = makeLadderElement("Card.Row")
        let source = NavigableSource(ladder: [target, makeLadderElement("Page")],
                                     childrenByID: ["Card": [row]])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: CGPoint(x: 7, y: 9))
        XCTAssertEqual(source.lastHint, CGPoint(x: 7, y: 9), "the click point is handed on as the ordering hint")
        XCTAssertTrue(session.canSelectChild, "a cached child enables descent")

        XCTAssertEqual(session.selectChild()?.id, "Card.Row", "child -> the source's most likely child")
        XCTAssertTrue(session.canSelectParent, "the original target is still one rung up")
        XCTAssertEqual(session.selectParent()?.id, "Card", "parent returns to the original target")
        XCTAssertEqual(session.selectParent()?.id, "Page", "and keeps climbing the original ladder")
    }

    /// The reason descent PREPENDS instead of re-querying: under a live UI the
    /// source's "most likely child" can change between presses, so a re-query would
    /// make Parent-then-Child land somewhere the user never chose.
    func testReDescentReplaysHistoryRatherThanReQueryingTheSource() {
        let target = makeLadderElement("Card")
        let source = NavigableSource(ladder: [target], childrenByID: ["Card": [makeLadderElement("Card.Row")]])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selectChild()?.id, "Card.Row")

        // The UI moves on: the same query would now answer differently.
        source.childrenByID["Card"] = [makeLadderElement("Card.Chevron")]
        XCTAssertEqual(session.selectParent()?.id, "Card")
        XCTAssertEqual(session.selectChild()?.id, "Card.Row",
                       "the round trip returns to the child actually visited, not to a fresh guess")
    }

    func testNavigationResetsOnNewSelectionAndCapture() {
        let ladder = [makeLadderElement("Leaf"), makeLadderElement("Card")]
        let session = AnnotationSession(source: LadderSource(ladder: ladder), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        session.selectParent()
        XCTAssertEqual(session.selected?.id, "Card")
        // A fresh selection restarts the path at the leaf — including the history
        // that would otherwise let Child step down into the PREVIOUS selection.
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "Leaf")
        XCTAssertTrue(session.canSelectParent)
        XCTAssertFalse(session.canSelectChild, "a new selection carries no navigation history")
        // Capturing clears the path (nothing to navigate with nothing selected).
        session.addNote(comment: "note")
        XCTAssertFalse(session.canSelectParent)
        XCTAssertFalse(session.canSelectChild)
    }

    /// `canSelectChild` is read on every SwiftUI render, so it must answer from the
    /// cache. One query per bound-element change is the budget; a per-render walk
    /// would be a serious regression.
    func testChildAvailabilityIsAnsweredFromCacheNotTheSource() {
        let source = NavigableSource(ladder: [makeLadderElement("Card")],
                                     childrenByID: ["Card": [makeLadderElement("Card.Row")]])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertEqual(source.childQueries, ["Card"], "exactly one query when the selection is made")
        for _ in 0 ..< 50 { _ = session.canSelectChild }
        XCTAssertEqual(source.childQueries, ["Card"], "reading the property must never reach the source")
    }

    /// An unseeded target whose enclosing card is only reachable via the GEOMETRIC
    /// path (a `.axCardSurface` sibling, not an ancestor) still gets its
    /// `component` set to that card — the path's tightest enclosing entry, not
    /// the target's ancestry.
    func testUnseededTargetTakesComponentFromGeometricPath() {
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

    /// Descending below an UNSEEDED target must not hand the agent a grep target
    /// that matches nothing.
    ///
    /// This pins the bug prepending created. `component` used to be
    /// `path.dropFirst().first?.id` — index 0 is the target, index 1 is its
    /// enclosing component — which held only while the path was strictly upward,
    /// because every upward rung is seeded by construction. Insert a child at 0
    /// and index 1 becomes the ORIGINAL TARGET, which may carry no identifier at
    /// all; an unseeded `Element.id` is a slash-joined path string, so the note
    /// would have exported `#AXWindow[0]/AXGroup[0]` as the thing to grep for and
    /// looked entirely plausible doing it. The derivation must skip to the first
    /// SEEDED rung above the bound one.
    func testDescendingBelowAnUnseededTargetStillNamesASeededComponent() {
        let unseededTarget = Element(
            id: "AXWindow[0]/AXGroup[0]", role: "AXGroup", type: "AXGroup",
            label: "", value: "", frame: CGRect(x: 0, y: 0, width: 40, height: 40),
            isVisible: true, isActionable: false,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXGroup", label: "", identifier: nil, indexAmongRole: 0),
            ]
        )
        let child = Element(
            id: "AXWindow[0]/AXGroup[0]/AXStaticText[0]", role: "AXStaticText", type: "AXStaticText",
            label: "", value: "Connect", frame: CGRect(x: 4, y: 4, width: 20, height: 10),
            isVisible: true, isActionable: false,
            path: [
                PathComponent(role: "AXWindow", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXGroup", label: "", identifier: nil, indexAmongRole: 0),
                PathComponent(role: "AXStaticText", label: "", identifier: nil, indexAmongRole: 0),
            ]
        )
        let seededCard = makeLadderElement("Dashboard.FirstRun")
        let source = NavigableSource(
            ladder: [unseededTarget, seededCard],
            childrenByID: [unseededTarget.id: [child]]
        )
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selectChild()?.id, child.id, "descends below the unseeded target")

        let note = session.addNote(comment: "wrong copy here")
        XCTAssertEqual(note?.component, "Dashboard.FirstRun",
                       "skips the unseeded target to the first SEEDED rung above the bound one")
        XCTAssertNotEqual(note?.component, unseededTarget.id,
                          "a slash-path id must never be exported as the component to grep")
        XCTAssertFalse(note?.component?.contains("/") ?? false, "no component is ever a path string")
        XCTAssertEqual(note?.unseeded, true, "the bound child carries no identifier of its own")
    }

    /// A region is a synthetic marker, not a node in anyone's tree, so BOTH
    /// navigation controls stay disabled. The empty `selectionPath` is what
    /// guarantees it: `canSelectChild` refuses to query a source for the children
    /// of an element that does not exist in the hierarchy.
    func testRegionSelectionCannotNavigate() {
        let anchor = makeElement()
        let session = AnnotationSession(
            source: EmptyWithAnchorSource(anchor: anchor), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        session.select(atAXPoint: CGPoint(x: 5, y: 5))
        XCTAssertEqual(session.selected?.role, "AXRegion")
        XCTAssertFalse(session.canSelectParent, "a region has no selection path to climb")
        XCTAssertFalse(session.canSelectChild, "and none to descend into")
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

    // MARK: - Marquee selection

    func testMarqueeBindsToLadderTargetAndCapturesTheLadder() {
        let ladder = [makeLadderElement("Card"), makeLadderElement("Settings.Models")]
        let session = AnnotationSession(source: MarqueeSource(ladder: ladder), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        let drawn = CGRect(x: 110, y: 120, width: 40, height: 20)
        XCTAssertEqual(session.select(inAXRect: drawn)?.id, "Card", "a marquee binds to the ladder's first rung")
        XCTAssertEqual(session.selectedMarqueeRect, drawn, "the drawn frame is kept absolute")
        XCTAssertNil(session.selectedRegionOffset, "a framed note carries no point locator")
        XCTAssertTrue(session.canSelectParent, "the marquee ladder drives navigation like the point ladder")
    }

    func testMarqueeNormalizesABackwardsDrag() {
        // A bottom-right -> top-left drag arrives with negative extents. The
        // session must normalize BEFORE delegating, or the source sees a rect whose
        // `contains` degenerates and the persisted frame gets a negative size.
        let source = MarqueeSource(ladder: [makeLadderElement("Card")])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(inAXRect: CGRect(x: 150, y: 140, width: -40, height: -20))
        XCTAssertEqual(source.lastRect, CGRect(x: 110, y: 120, width: 40, height: 20))
        XCTAssertEqual(session.selectedMarqueeRect, CGRect(x: 110, y: 120, width: 40, height: 20))
    }

    func testMarqueeThenClickDropsTheStaleFrame() {
        // The 7993a67 hazard, marquee edition: the catcher stays live behind an
        // open composer, so drag-then-click WITHOUT capturing is a supported flow.
        // The click's note must not inherit the drag's frame — the `selected`
        // didSet cannot help, because the value is replaced, never nilled.
        let leaf = makeLadderElement("Card", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let source = MarqueeSource(ladder: [leaf])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(inAXRect: CGRect(x: 110, y: 120, width: 40, height: 20))
        XCTAssertNotNil(session.selectedMarqueeRect)

        source.hit = makeElement()
        source.ladder = []
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "SaveButton", "the click re-selects a real element")
        XCTAssertNil(session.selectedMarqueeRect, "the drawn frame must not survive re-selection")
        XCTAssertNil(session.addNote(comment: "click after drag")?.regionRect,
                     "a click note must not inherit the stale marquee frame")
    }

    func testRegionClickThenMarqueeDropsTheStaleOffset() {
        // The other direction: a no-hit CLICK lands a point-region (setting
        // `selectedRegionOffset`), then a drag lands a framed note. The framed note
        // must carry exactly one locator — the rect — or the formatter would have
        // two mutually exclusive Region lines to choose between.
        let anchor = makeElement()
        let source = MarqueeSource(ladder: [makeLadderElement("Card")], hit: nil, anchor: anchor)
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: CGPoint(x: 22, y: 14))
        XCTAssertEqual(session.selectedRegionOffset, CGPoint(x: 22, y: 14), "the click lands a point-region")

        session.select(inAXRect: CGRect(x: 110, y: 120, width: 40, height: 20))
        XCTAssertEqual(session.selected?.id, "Card", "the drag re-selects a real element")
        XCTAssertNil(session.selectedRegionOffset, "the region offset must not survive re-selection")
        let note = session.addNote(comment: "drag after region click")
        XCTAssertNil(note?.regionOffset, "a framed note must not inherit the stale point offset")
        XCTAssertNotNil(note?.regionRect)
    }

    func testSelectParentAfterAMarqueeReRelativizesTheFrame() {
        // The frame is stored ABSOLUTE precisely so widening stays correct: the
        // note rebinds to a bigger element with a different origin AFTER the drag,
        // so the persisted rect must be measured against the widened element. A
        // frame relativized at selection time would keep the leaf's numbers.
        let leaf = makeLadderElement("Leaf", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let card = makeLadderElement("Card", frame: CGRect(x: 80, y: 60, width: 200, height: 150))
        let session = AnnotationSession(
            source: MarqueeSource(ladder: [leaf, card]), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 110, y: 120, width: 40, height: 20)
        session.select(inAXRect: drawn)
        XCTAssertEqual(session.selectParent()?.id, "Card")
        XCTAssertEqual(session.selectedMarqueeRect, drawn, "widening keeps the absolute drawn frame")
        let note = session.addNote(comment: "framed then widened")
        XCTAssertEqual(note?.selector, "#Card")
        XCTAssertEqual(note?.regionRect, CGRect(x: 30, y: 60, width: 40, height: 20),
                       "origin re-measured from the widened element; size unchanged")
    }

    func testCaptureClearsTheMarqueeFrame() {
        // The didSet path (selection -> nil), distinct from the re-selection path
        // above: after a capture the NEXT note must start frame-free.
        let source = MarqueeSource(ladder: [makeLadderElement("Card", frame: CGRect(x: 100, y: 100, width: 60, height: 40))])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(inAXRect: CGRect(x: 110, y: 120, width: 40, height: 20))
        XCTAssertNotNil(session.addNote(comment: "framed")?.regionRect)
        XCTAssertNil(session.selectedMarqueeRect, "capture clears the drawn frame")

        source.hit = makeElement()
        session.select(atAXPoint: .zero)
        XCTAssertNil(session.addNote(comment: "plain")?.regionRect, "the next note carries no frame")
    }

    func testMarqueeWithoutMarqueeSourceFallsBackToAnAnchoredRegion() {
        // No `MarqueeTargetSource` conformance: the drag degrades to a region note,
        // but the FRAME survives — and it is measured from the ANCHOR, because the
        // synthetic element's own frame IS the drawn rect and would trivially
        // relativize to (0, 0), locating nothing.
        let anchor = Element(
            id: "SaveButton", role: "AXButton", type: "AXButton", label: "Save", value: "",
            frame: CGRect(x: 10, y: 5, width: 100, height: 40), isVisible: true, isActionable: true,
            path: [PathComponent(role: "AXButton", label: "Save", identifier: "SaveButton", indexAmongRole: 0)]
        )
        let session = AnnotationSession(
            source: EmptyWithAnchorSource(anchor: anchor), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 22, y: 14, width: 30, height: 12)
        let selected = session.select(inAXRect: drawn)
        XCTAssertEqual(selected?.role, "AXRegion")
        XCTAssertEqual(selected?.frame, drawn, "the highlight shows the frame the user drew")
        XCTAssertEqual(selected?.label, "Region 30x12 at (12, 9) in Save")
        XCTAssertNil(session.selectedRegionOffset, "a framed region carries the rect, not a point offset")

        let note = session.addNote(comment: "gap looks off")
        XCTAssertNil(note?.regionOffset)
        XCTAssertEqual(note?.regionRect, CGRect(x: 12, y: 9, width: 30, height: 12))
        XCTAssertNotEqual(note?.regionRect?.origin, .zero,
                          "measured from the anchor, NOT from the synthetic element (which would be 0,0)")
    }

    func testDegenerateMarqueeSelectsNothing() {
        // A press that never moved (or moved on one axis only) is a click, not a
        // marquee. It must not even reach the region fallback, or a stray press
        // would plant a zero-area framed note.
        let anchor = makeElement()
        let source = MarqueeSource(ladder: [makeLadderElement("Card")], anchor: anchor)
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        XCTAssertNil(session.select(inAXRect: CGRect(x: 10, y: 10, width: 0, height: 20)))
        XCTAssertNil(session.select(inAXRect: CGRect(x: 10, y: 10, width: 20, height: 0)))
        XCTAssertNil(session.select(inAXRect: .zero))
        XCTAssertNil(session.selected, "a degenerate drag selects nothing at all")
        XCTAssertNil(source.lastRect, "the source is never consulted for a degenerate frame")
    }

    func testSelectInRectIsGatedOnAnnotatingMode() {
        let session = AnnotationSession(
            source: MarqueeSource(ladder: [makeLadderElement("Card")]), sink: NotesFileSink(path: "/dev/null")
        )
        let drawn = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertNil(session.select(inAXRect: drawn), "a drag before start must be nil")
        session.start()
        XCTAssertEqual(session.select(inAXRect: drawn)?.id, "Card")
    }

    // MARK: - Selection tool

    /// Point selection is the default, so a host that never touches the tool keeps
    /// the click-to-annotate behaviour that predates frame selection.
    func testSelectionToolDefaultsToPoint() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        XCTAssertEqual(session.tool, .point)
    }

    func testSetToolSwitchesBetweenPointAndFrame() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.setTool(.frame)
        XCTAssertEqual(session.tool, .frame)
        session.setTool(.point)
        XCTAssertEqual(session.tool, .point)
    }

    /// The tool is a PREFERENCE, not per-selection state: it must survive leaving
    /// annotate mode, clearing the notes, and capturing. Resetting it on any of
    /// these would silently drop the user back to point selection mid-session —
    /// and the next drag would then do nothing at all, since a drag in point mode
    /// is treated as a click.
    func testSelectionToolSurvivesStopClearAndCapture() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.setTool(.frame)

        session.select(atAXPoint: .zero)
        session.addNote(comment: "captured")
        XCTAssertEqual(session.tool, .frame, "capturing a note must not reset the tool")

        session.clear()
        XCTAssertEqual(session.tool, .frame, "clearing the notes must not reset the tool")

        session.stop()
        XCTAssertEqual(session.tool, .frame, "leaving annotate mode must not reset the tool")

        session.start()
        XCTAssertEqual(session.tool, .frame, "re-entering annotate mode keeps the chosen tool")
    }

    /// Frame mode selects from a swept rectangle, so a hover highlight there
    /// advertises a point-selection no press in that mode can make — the reported
    /// symptom was a whole card lit up with its name tag before anything was drawn.
    /// The hit-test count is the load-bearing half: suppressing the highlight while
    /// still running the query would leave one cross-process AX round trip per
    /// pointer-motion event.
    func testHoverIsInertInFrameMode() {
        let source = StubSource(makeElement())
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.setTool(.frame)

        session.hover(atAXPoint: .zero)
        XCTAssertNil(session.hovered, "frame mode must not resolve a hover highlight")
        XCTAssertEqual(source.hitTests, 0, "and must not even ask the source — the AX query is the cost")

        session.setTool(.point)
        session.hover(atAXPoint: .zero)
        XCTAssertEqual(session.hovered?.id, "SaveButton", "point mode hovers exactly as before")
        XCTAssertEqual(source.hitTests, 1)
    }

    /// A highlight resolved in point mode must not SURVIVE the switch to frame mode:
    /// it would sit there — lit element, name tag, no relation to the next gesture —
    /// until the pointer happened to leave the catcher. Everything else about the
    /// tool's "touch nothing" contract still holds, because the user may be
    /// mid-note when they reach for the other tool.
    func testSetToolClearsTheHoverHighlightAndNothingElse() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        session.addNote(comment: "already captured")
        session.hover(atAXPoint: .zero)
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.hovered?.id, "SaveButton")

        session.setTool(.frame)
        XCTAssertNil(session.hovered, "the stale point-mode highlight must go with the tool")
        XCTAssertEqual(session.tool, .frame)
        XCTAssertEqual(session.selected?.id, "SaveButton", "an open composer survives a tool change")
        XCTAssertEqual(session.pending.count, 1, "and so do the retained notes")
    }

    // MARK: - Frame anchoring

    /// The other half of the report: the drawn frame was thrown away VISUALLY the
    /// moment it resolved, because every anchor derived from `selected.frame`. The
    /// frame is the anchor while it is still the truth of the selection — and the
    /// note payload is untouched by any of it.
    func testMarqueeAnchorsTheOverlayToTheDrawnFrame() {
        let leaf = makeLadderElement("Leaf", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let card = makeLadderElement("Card", frame: CGRect(x: 80, y: 60, width: 200, height: 150))
        let session = AnnotationSession(
            source: MarqueeSource(ladder: [leaf, card]), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 110, y: 120, width: 40, height: 20)
        session.select(inAXRect: drawn)

        XCTAssertEqual(session.selectionAnchorFrame, drawn, "the overlay anchors to the frame the user drew")
        XCTAssertNotEqual(session.selectionAnchorFrame, session.selected?.frame,
                          "and NOT to the element it resolved to — the whole bug")

        let note = session.addNote(comment: "framed")
        XCTAssertEqual(note?.selector, "#Leaf", "the binding is unchanged: still the resolved element")
        XCTAssertEqual(note?.component, "Leaf")
        XCTAssertEqual(note?.regionRect, CGRect(x: 10, y: 20, width: 40, height: 20),
                       "and the payload is unchanged: the frame relative to the bound element")
        XCTAssertNil(session.selectionAnchorFrame, "capture clears the anchor with the selection")
    }

    /// A click carries no drawn frame, so it must never claim one — otherwise the
    /// composer would point at a rectangle from an earlier gesture.
    func testPointSelectionHasNoAnchorFrame() {
        let session = AnnotationSession(source: StubSource(makeElement()), sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(atAXPoint: .zero)
        XCTAssertNil(session.selectionAnchorFrame)
    }

    /// The region fallback needs NO anchor flag, and this pins that: its synthetic
    /// element's own `frame` IS the drawn rect, so `selected.frame` already anchors
    /// everything to the frame. A later refactor that "fixed" this branch by
    /// setting the flag too would give one rectangle two sources of truth.
    func testRegionFallbackFrameAnchorsThroughItsSyntheticElement() {
        let anchor = makeElement()
        let session = AnnotationSession(
            source: EmptyWithAnchorSource(anchor: anchor), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 22, y: 14, width: 30, height: 12)
        session.select(inAXRect: drawn)

        XCTAssertNil(session.selectionAnchorFrame, "no flag here by design")
        XCTAssertEqual(session.selected?.frame, drawn, "because the selection's own frame is already the drawn rect")
    }

    /// Pressing Parent/Child is the user explicitly asking WHICH element, so the
    /// answer becomes visible: the anchor drops to the chosen element. The drawn
    /// frame itself stays — it is still what the note records, and the overlay draws
    /// it dimmed underneath.
    func testNavigationDropsTheFrameAnchorButKeepsTheDrawnFrame() {
        let leaf = makeLadderElement("Leaf", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let card = makeLadderElement("Card", frame: CGRect(x: 80, y: 60, width: 200, height: 150))
        let session = AnnotationSession(
            source: MarqueeSource(ladder: [leaf, card]), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 110, y: 120, width: 40, height: 20)
        session.select(inAXRect: drawn)
        XCTAssertEqual(session.selectionAnchorFrame, drawn)

        XCTAssertEqual(session.selectParent()?.id, "Card")
        XCTAssertNil(session.selectionAnchorFrame, "the chosen element becomes the anchor")
        XCTAssertEqual(session.selectedMarqueeRect, drawn, "but the note still records the drawn frame")

        XCTAssertEqual(session.selectChild()?.id, "Leaf", "coming back down is still a CHOSEN element")
        XCTAssertNil(session.selectionAnchorFrame, "so the anchor stays on the element, not the frame")
        XCTAssertEqual(session.selectedMarqueeRect, drawn)

        // The note is unaffected by any of the anchoring: still the bound element's
        // selector, still the frame measured against it.
        let note = session.addNote(comment: "framed then navigated")
        XCTAssertEqual(note?.selector, "#Leaf")
        XCTAssertEqual(note?.regionRect, CGRect(x: 10, y: 20, width: 40, height: 20))
    }

    /// The `7993a67` regression, anchor edition: frame -> navigate -> new click. The
    /// navigation clears the flag and the click clears the frame, so if either site
    /// were missed the next note would place its composer and pin against a
    /// rectangle drawn for the previous one.
    func testFrameThenNavigateThenClickLeavesNoStaleAnchor() {
        let leaf = makeLadderElement("Leaf", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let card = makeLadderElement("Card", frame: CGRect(x: 80, y: 60, width: 200, height: 150))
        let source = MarqueeSource(ladder: [leaf, card])
        let session = AnnotationSession(source: source, sink: NotesFileSink(path: "/dev/null"))
        session.start()
        session.select(inAXRect: CGRect(x: 110, y: 120, width: 40, height: 20))
        session.selectParent()

        source.hit = makeElement()
        source.ladder = []
        session.select(atAXPoint: .zero)
        XCTAssertEqual(session.selected?.id, "SaveButton", "the click re-selects a real element")
        XCTAssertNil(session.selectionAnchorFrame, "no anchor may survive into the next selection")
        XCTAssertNil(session.selectedMarqueeRect)
        XCTAssertNil(session.addNote(comment: "click after frame and navigate")?.regionRect,
                     "and the next note carries no trace of the drawn frame")
    }

    /// The anchor is per-SELECTION, so every path that ends a selection must drop it
    /// — cancel and stop go through the `selected` didSet, which is the one clear
    /// site no `select` call can cover.
    func testCancellingAndStoppingClearTheFrameAnchor() {
        let leaf = makeLadderElement("Leaf", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        let session = AnnotationSession(
            source: MarqueeSource(ladder: [leaf]), sink: NotesFileSink(path: "/dev/null")
        )
        session.start()
        let drawn = CGRect(x: 110, y: 120, width: 40, height: 20)
        session.select(inAXRect: drawn)
        session.cancelSelection()
        XCTAssertNil(session.selectionAnchorFrame, "cancelling the composer drops the anchor")

        session.select(inAXRect: drawn)
        session.stop()
        XCTAssertNil(session.selectionAnchorFrame, "and so does leaving annotate mode")
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
