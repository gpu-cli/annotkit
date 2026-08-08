import CoreGraphics
import XCTest
@testable import AnnotKit

/// The marquee rule, exercised on synthetic candidate arrays so the decision is
/// verified without a live AX tree. The macOS/iOS adapters build the same
/// `[MarqueeCandidate]` from their platform node types, so what these tests pin
/// down is what a real drag resolves to.
final class MarqueeTargetRuleTests: XCTestCase {
    // A plausible window-sized stage: the panel below spans it, the cards sit
    // inside it.
    private let windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func candidate(
        _ frame: CGRect,
        role: String = "AXGroup",
        identifier: String = "",
        label: String = "",
        value: String = "",
        isActionable: Bool = false,
        isChrome: Bool = false,
        isContainerRoot: Bool = false,
        isWindowGhost: Bool = false,
        depth: Int = 1
    ) -> MarqueeCandidate {
        MarqueeCandidate(
            element: TargetCandidate(
                role: role,
                identifier: identifier,
                label: label,
                value: value,
                isActionable: isActionable,
                isChrome: isChrome,
                isContainerRoot: isContainerRoot,
                isWindowGhost: isWindowGhost
            ),
            frame: frame,
            depth: depth
        )
    }

    /// The point of the feature: dragging a rectangle around a card means "I mean
    /// this whole card", so the card must beat the title and the button drawn
    /// inside it — the exact opposite of the deepest-wins point rule.
    func testLargestSurroundedCandidateWinsOverItsOwnChildren() {
        let candidates = [
            candidate(CGRect(x: 100, y: 100, width: 200, height: 24), value: "Models", depth: 3),
            candidate(CGRect(x: 100, y: 60, width: 300, height: 200), identifier: "Settings.Models", depth: 2),
            candidate(CGRect(x: 260, y: 200, width: 80, height: 28), label: "Edit", isActionable: true, depth: 3),
        ]
        let resolution = MarqueeTargetRule.resolve(marquee: CGRect(x: 90, y: 50, width: 320, height: 220), in: candidates)
        XCTAssertEqual(resolution, MarqueeTargetRule.Resolution(index: 1, match: .surrounded), "the card, not its label")
    }

    /// The 0.85 boundary is inclusive, with exact geometry on both sides of it:
    /// the small card is covered to exactly 0.85 and counts as surrounded; the
    /// larger card the drag merely clips at 0.84 does not, even though it would
    /// win on area if it did.
    func testContainmentThresholdBoundaryIsInclusive() {
        let small = candidate(CGRect(x: 0, y: 0, width: 100, height: 100), label: "Small") // area 10_000
        let large = candidate(CGRect(x: 200, y: 0, width: 200, height: 100), label: "Large") // area 20_000

        // x 15…368: small keeps 85×100 = 8_500 / 10_000 = 0.85 exactly (in);
        // large keeps 168×100 = 16_800 / 20_000 = 0.84 (out).
        let atBoundary = MarqueeTargetRule.resolve(
            marquee: CGRect(x: 15, y: 0, width: 353, height: 100), in: [small, large])
        XCTAssertEqual(atBoundary, MarqueeTargetRule.Resolution(index: 0, match: .surrounded),
                       "0.85 counts, 0.84 does not")

        // Two points wider: large keeps 170×100 = 17_000 / 20_000 = 0.85, and now
        // outranks the small card on area.
        let justOver = MarqueeTargetRule.resolve(
            marquee: CGRect(x: 15, y: 0, width: 355, height: 100), in: [small, large])
        XCTAssertEqual(justOver, MarqueeTargetRule.Resolution(index: 1, match: .surrounded))
    }

    /// AX regularly reports collapsed or not-yet-laid-out elements with an empty
    /// frame. They must never win, and — the reason the positive-area check is
    /// load-bearing — must not put a 0/0 NaN into the coverage ratio and corrupt
    /// the comparison for everyone else.
    func testZeroAreaCandidatesAreIgnored() {
        let real = candidate(CGRect(x: 100, y: 100, width: 50, height: 50), label: "Real")
        let flat = candidate(CGRect(x: 100, y: 100, width: 0, height: 50), identifier: "Collapsed")
        let empty = candidate(.zero, identifier: "Unlaid")
        let marquee = CGRect(x: 0, y: 0, width: 400, height: 400)

        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: marquee, in: [flat, empty, real]),
                       MarqueeTargetRule.Resolution(index: 2, match: .surrounded))
        XCTAssertNil(MarqueeTargetRule.resolve(marquee: marquee, in: [flat, empty]),
                     "nothing eligible remains, and no NaN slipped through")
    }

    /// A drag across the whole window sweeps up the window itself, its
    /// `NSHostingView` ghost group, and the traffic lights. None of them locates
    /// app code, so none may be selected — the same exclusions the point rule
    /// applies, reused via `isEligibleMeaningful`.
    func testChromeContainerRootAndWindowGhostAreNeverSelected() {
        let candidates = [
            candidate(windowFrame, role: "AXWindow", label: "Settings", isContainerRoot: true, depth: 0),
            candidate(windowFrame, role: "AXGroup", isWindowGhost: true, depth: 1),
            candidate(CGRect(x: 8, y: 8, width: 14, height: 14), role: "AXButton",
                      label: "close", isActionable: true, isChrome: true, depth: 2),
            candidate(CGRect(x: 100, y: 100, width: 300, height: 200), identifier: "Settings.Models", depth: 3),
        ]
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: windowFrame, in: candidates),
                       MarqueeTargetRule.Resolution(index: 3, match: .surrounded),
                       "the card, though the window and ghost are larger and fully inside")

        XCTAssertNil(MarqueeTargetRule.resolve(marquee: windowFrame, in: Array(candidates.prefix(3))))
    }

    /// The dominant VirgilHUD pattern: `.axCardSurface(id)` puts the card's
    /// identifier on a clear `Color.clear` background leaf that is EXACTLY
    /// coextensive with the card's content group. A frame around the card
    /// surrounds both identically; the seeded one is the one whose identifier
    /// locates the code.
    func testSeededBeatsUnseededAtExactlyEqualArea() {
        let cardFrame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let candidates = [
            candidate(cardFrame, role: "AXGroup", label: "Models", depth: 3), // content group
            candidate(cardFrame, role: "AXUnknown", identifier: "Settings.Models", depth: 3), // .axCardSurface leaf
        ]
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: CGRect(x: 90, y: 90, width: 320, height: 220), in: candidates),
                       MarqueeTargetRule.Resolution(index: 1, match: .surrounded),
                       "the seeded surface, not the coextensive content group")
    }

    /// Geometry and seeding have run out, so the shallower node wins — the
    /// container rather than the pass-through wrapper SwiftUI stacked inside it.
    /// Determinism only; the index tie-break is deliberately not what decides it.
    func testShallowerBeatsDeeperAtEqualAreaAndEqualSeeding() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let candidates = [
            candidate(frame, label: "Wrapper", depth: 7),
            candidate(frame, label: "Container", depth: 2),
        ]
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: CGRect(x: 0, y: 0, width: 600, height: 600), in: candidates),
                       MarqueeTargetRule.Resolution(index: 1, match: .surrounded))
    }

    /// Two candidates indistinguishable on every ranked key must resolve to the
    /// lowest index, always. This is why the fold replaces the incumbent only on a
    /// STRICT improvement: `max(by:)` makes no first-wins promise, and the same
    /// drag resolving to a different element run to run is the bug being
    /// prevented.
    func testTotalTieResolvesToLowestIndex() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let candidates = [
            candidate(frame, identifier: "A", depth: 4),
            candidate(frame, identifier: "B", depth: 4),
            candidate(frame, identifier: "C", depth: 4),
        ]
        let marquee = CGRect(x: 90, y: 90, width: 320, height: 220)
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: marquee, in: candidates),
                       MarqueeTargetRule.Resolution(index: 0, match: .surrounded))
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: marquee, in: Array(candidates.reversed())),
                       MarqueeTargetRule.Resolution(index: 0, match: .surrounded),
                       "position in the array decides, nothing else")
    }

    /// A frame scribbled over a card's empty padding surrounds nothing, so it
    /// binds to the TIGHTEST thing containing it — the card. The window-spanning
    /// panel contains it too and must lose; this is the rect generalization of the
    /// point-region path, which likewise refuses to resolve to the whole window.
    func testEnclosingFallbackPicksTheTightestContainer() {
        let candidates = [
            candidate(CGRect(x: 0, y: 0, width: 1000, height: 780), identifier: "Settings.Panel", depth: 2),
            candidate(CGRect(x: 100, y: 100, width: 300, height: 200), identifier: "Settings.Models", depth: 3),
            candidate(CGRect(x: 500, y: 100, width: 300, height: 200), identifier: "Settings.Keys", depth: 3),
        ]
        XCTAssertEqual(
            MarqueeTargetRule.resolve(marquee: CGRect(x: 150, y: 250, width: 60, height: 30), in: candidates),
            MarqueeTargetRule.Resolution(index: 1, match: .enclosing),
            "the card, not the panel that also contains the scribble")
    }

    /// When the drag both surrounds a control and sits inside a card, surrounding
    /// wins: the user drew AROUND something, which is a statement of intent, while
    /// being inside something is merely where the pointer happened to be.
    func testSurroundedIsPreferredOverEnclosing() {
        let candidates = [
            candidate(CGRect(x: 100, y: 100, width: 300, height: 200), identifier: "Settings.Models", depth: 2),
            candidate(CGRect(x: 150, y: 150, width: 80, height: 28), label: "Edit", isActionable: true, depth: 3),
        ]
        XCTAssertEqual(
            MarqueeTargetRule.resolve(marquee: CGRect(x: 140, y: 140, width: 100, height: 48), in: candidates),
            MarqueeTargetRule.Resolution(index: 1, match: .surrounded),
            "the surrounded button, though the enclosing card is also a valid answer")
    }

    /// A frame drawn over empty chrome-free decoration matches nothing either way.
    /// nil is the handoff: the session falls back to a region note anchored near
    /// the frame rather than dropping the drag.
    func testNilWhenNothingIsEligible() {
        let candidates = [
            candidate(windowFrame, role: "AXWindow", isContainerRoot: true, depth: 0),
            candidate(CGRect(x: 100, y: 100, width: 40, height: 2), role: "AXUnknown", depth: 4), // a divider
        ]
        XCTAssertNil(MarqueeTargetRule.resolve(marquee: CGRect(x: 600, y: 600, width: 50, height: 50), in: candidates))
    }

    /// A press-and-release with no movement, or a drag along a single axis, is a
    /// click — not a marquee. Without the guard the degenerate rect is contained
    /// by everything and the enclosing pass would bind a note to an arbitrary
    /// container.
    func testDegenerateMarqueeReturnsNil() {
        let candidates = [candidate(CGRect(x: 0, y: 0, width: 400, height: 400), identifier: "Panel", depth: 1)]
        XCTAssertNil(MarqueeTargetRule.resolve(marquee: CGRect(x: 200, y: 200, width: 0, height: 0), in: candidates))
        XCTAssertNil(MarqueeTargetRule.resolve(marquee: CGRect(x: 200, y: 200, width: 0, height: 80), in: candidates))
        XCTAssertNil(MarqueeTargetRule.resolve(marquee: CGRect(x: 200, y: 200, width: 80, height: 0), in: candidates))
    }

    /// Dragging up-and-left is as natural as down-and-right and arrives with
    /// negative width/height, where `contains` and `intersection` degenerate. Both
    /// directions must describe the same rectangle and resolve identically.
    func testReversedDragResolvesIdenticallyToTheStandardizedOne() {
        let candidates = [
            candidate(CGRect(x: 100, y: 100, width: 200, height: 24), value: "Models", depth: 3),
            candidate(CGRect(x: 100, y: 60, width: 300, height: 200), identifier: "Settings.Models", depth: 2),
        ]
        let forward = CGRect(x: 90, y: 50, width: 320, height: 220)
        // Same rectangle, dragged from its bottom-right corner back to its top-left.
        let reversed = CGRect(x: 410, y: 270, width: -320, height: -220)
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: reversed, in: candidates),
                       MarqueeTargetRule.resolve(marquee: forward, in: candidates))
        XCTAssertEqual(MarqueeTargetRule.resolve(marquee: reversed, in: candidates),
                       MarqueeTargetRule.Resolution(index: 1, match: .surrounded))
    }
}
