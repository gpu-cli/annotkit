import CoreGraphics
import XCTest
@testable import AnnotKit

/// The two pure decisions behind a recalled mark: WHICH note the pointer is asking
/// about, and WHAT that note's mark looks like.
///
/// Both exist as rules rather than as code inside a SwiftUI closure precisely so
/// these can be assertions instead of things a human checks by moving a mouse
/// around — which is the only way "hovering pin 3 shows note 3's frame" was ever
/// going to be verified otherwise.
final class RecalledMarkTests: XCTestCase {
    private func note(
        id: String,
        anchorRect: CGRect? = CGRect(x: 100, y: 200, width: 40, height: 20),
        drawnRect: CGRect? = nil,
        component: String? = nil,
        unseeded: Bool? = nil,
        elementRole: String? = nil,
        elementText: String? = nil,
        selector: String = "#SaveButton"
    ) -> AnnotationNote {
        AnnotationNote(
            id: id,
            selector: selector,
            elementPath: "AXWindow > AXButton",
            component: component,
            elementRole: elementRole,
            elementText: elementText,
            unseeded: unseeded,
            comment: "c",
            timestamp: "t",
            anchorRect: anchorRect,
            drawnRect: drawnRect
        )
    }

    // MARK: - PinAttentionRule

    func testAPointOnAPinAttendsThatNote() {
        let notes = [note(id: "a", anchorRect: CGRect(x: 100, y: 200, width: 40, height: 20))]
        XCTAssertEqual(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 100, y: 200), in: notes), "a",
                       "the pin is centred on the anchor rect's ORIGIN, not its centre")
    }

    /// The reason the radius is larger than the pin, stated as a test. In point mode
    /// the pin is a live button above the catcher, so the ONLY points the catcher
    /// ever reports near a pin are the ones outside it — a radius equal to the pin's
    /// own would make recall unreachable in the default mode.
    func testAPointJustOutsideTheDrawnPinStillAttendsIt() {
        let notes = [note(id: "a", anchorRect: CGRect(x: 100, y: 200, width: 40, height: 20))]
        let justOutsideTheCircle = CGPoint(x: 100 + PinAttentionRule.pinDiameter / 2 + 2, y: 200)
        XCTAssertGreaterThan(PinAttentionRule.attentionRadius, PinAttentionRule.pinDiameter / 2,
                             "the attention radius must exceed the pin's own, or the catcher can never see an attending point")
        XCTAssertEqual(PinAttentionRule.attendedNote(atWindowPoint: justOutsideTheCircle, in: notes), "a")
    }

    func testAPointBeyondTheAttentionRadiusAttendsNothing() {
        let notes = [note(id: "a")]
        let far = CGPoint(x: 100 + PinAttentionRule.attentionRadius + 1, y: 200)
        XCTAssertNil(PinAttentionRule.attendedNote(atWindowPoint: far, in: notes))
        XCTAssertNil(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 900, y: 900), in: notes))
    }

    /// Distance is the hypotenuse, not per-axis: a point 15pt right and 15pt down of
    /// a pin is ~21pt away and outside a 20pt radius, while a per-axis test would
    /// call it inside on both axes.
    func testAttentionIsRadial() {
        let notes = [note(id: "a", anchorRect: CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertNil(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 15, y: 15), in: notes))
        XCTAssertEqual(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 12, y: 12), in: notes), "a")
    }

    /// Pins are drawn in `pending` order, so a later one is painted ON TOP. The user
    /// can only mean the pin they can see.
    func testOverlappingPinsResolveToTheOneDrawnOnTop() {
        let notes = [
            note(id: "first", anchorRect: CGRect(x: 100, y: 100, width: 10, height: 10)),
            note(id: "second", anchorRect: CGRect(x: 103, y: 103, width: 10, height: 10))
        ]
        XCTAssertEqual(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 101, y: 101), in: notes), "second")
    }

    func testNotesWithoutGeometryAreSkippedRatherThanMatched() {
        // A note decoded from disk has no rects (they are deliberately not
        // persisted). It draws no pin, so no point can be resting on one.
        let notes = [note(id: "decoded", anchorRect: nil), note(id: "live")]
        XCTAssertEqual(PinAttentionRule.attendedNote(atWindowPoint: CGPoint(x: 100, y: 200), in: notes), "live")
        XCTAssertNil(PinAttentionRule.attendedNote(atWindowPoint: .zero, in: [note(id: "decoded", anchorRect: nil)]))
    }

    // MARK: - RecalledMark

    /// An AREA note: the two rects agree, so the mark is the swept rectangle drawn
    /// solid with NO name tag — exactly what live state 2 (the committed frame) puts
    /// on screen, and for the same reason: a tag here would be a second,
    /// differently-shaped claim next to the rectangle the user actually drew.
    func testAnAreaNoteRecallsTheSweptRectangleWithNoNameTag() {
        let drawn = CGRect(x: 10, y: 20, width: 300, height: 90)
        let mark = RecalledMark.resolve(note(id: "a", anchorRect: drawn, drawnRect: drawn))
        XCTAssertEqual(mark?.rect, drawn)
        XCTAssertNil(mark?.dimmedRect, "nothing to dim: the binding never moved off the drawn frame")
        XCTAssertNil(mark?.name)
    }

    /// An ELEMENT note: the anchor rect, named. There is exactly one mark on screen,
    /// so unlike an always-on layer there is no ambiguity about what the tag labels.
    func testAnElementNoteRecallsItsRectWithANameTag() {
        let mark = RecalledMark.resolve(note(id: "a", component: "Settings.Models", unseeded: false, elementRole: "AXButton"))
        XCTAssertEqual(mark?.rect, CGRect(x: 100, y: 200, width: 40, height: 20))
        XCTAssertNil(mark?.dimmedRect)
        XCTAssertEqual(mark?.name, "Settings.Models")
    }

    /// The case the whole "store the rects, do not derive them" argument turns on.
    /// After Parent/Child the note is filed against the ELEMENT while the drawn rect
    /// is still what the user swept, so the mark shows both — the binding solid, the
    /// gesture dimmed beneath it, mirroring live state 3.
    func testANavigatedFramedNoteRecallsBothRects() {
        let element = CGRect(x: 0, y: 0, width: 500, height: 400)
        let drawn = CGRect(x: 40, y: 60, width: 120, height: 80)
        let mark = RecalledMark.resolve(note(id: "a", anchorRect: element, drawnRect: drawn,
                                             component: "Dashboard.Today", unseeded: false))
        XCTAssertEqual(mark?.rect, element, "the SOLID rect is what the note is filed against")
        XCTAssertEqual(mark?.dimmedRect, drawn, "the swept rect survives, dimmed, as what the note records")
        XCTAssertEqual(mark?.name, "Dashboard.Today", "and the bound element is named, as live state 3 names it")
    }

    func testANoteWithNoStoredGeometryRecallsNothing() {
        XCTAssertNil(RecalledMark.resolve(note(id: "a", anchorRect: nil)),
                     "a note decoded from disk carries no rects and must draw nothing rather than guess")
    }

    /// `component` holds an ANCESTOR's identifier when the note's own target was
    /// unseeded, and labelling a small element with the name of the card around it
    /// would claim a binding the note does not have. The fallbacks mirror the live
    /// highlight's order: identifier, then the displayed text, then the role.
    func testTheNameTagOnlyUsesTheComponentWhenTheTargetItselfWasSeeded() {
        XCTAssertEqual(
            RecalledMark.resolve(note(id: "a", component: "Card", unseeded: true, elementRole: "AXStaticText"))?.name,
            "AXStaticText", "an unseeded target must not borrow its ancestor's name")
        XCTAssertEqual(
            RecalledMark.resolve(note(id: "a", component: "Card", unseeded: true,
                                      elementRole: "AXStaticText", elementText: "gpt-5"))?.name,
            "gpt-5")
        XCTAssertEqual(RecalledMark.resolve(note(id: "a", selector: "#Fallback"))?.name, "#Fallback",
                       "with nothing else frozen on the note, the selector is what the edit card shows too")
    }
}
