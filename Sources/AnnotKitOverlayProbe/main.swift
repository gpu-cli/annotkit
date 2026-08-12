#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI
import AnnotKit

// ============================================================================
// AnnotKitOverlayProbe
//
// A headless (off-screen NSApplication) harness that reproduces the REAL
// annotate-mode overlay path — the gap AnnotKitProbe never covered. AnnotKitProbe
// only ever sees the IDLE 380x130 corner panel, so it can never observe what the
// EXPANDED full-window child panel does to the AX point query.
//
// This harness:
//   Phase 1  builds a host window of identified controls, records a baseline
//            (idle) hit-test, then calls Annotation.install() + Annotation.start()
//            so the child panel EXPANDS to the host's full frame, and:
//     (a) MacElementSource().snapshot() -> logs every AX window, flagging any
//         untitled window whose frame matches the host (the overlay panel
//         shadowing the host in kAXWindows).
//     (b) fires AXUIElementCopyElementAtPosition at a known control's AX point
//         THROUGH the expanded overlay and logs the FULL ancestor chain + which
//         top-level AXWindow the hit belongs to (control? panel? host? app?).
//     Also compares the controller's axOrigin transform against the host's real
//     AX window origin to check for a title-bar offset.
//   Phase 2  drives a real select -> addNote on a directly-constructed
//            OverlayController (public API, identical to Annotation.install's
//            internals) and inspects the child panel's window state before/after
//            the note, to test the "pill disappears because the non-activating
//            panel resigns key / the app deactivates" hypothesis (issue 1).
//
// Run:  swift run AnnotKitOverlayProbe
// ============================================================================

// MARK: - Raw AX helpers (local, so we can LOG what the point query returns)

@MainActor
enum AX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        (copy(element, attribute) as? String) ?? ""
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func windows(_ element: AXUIElement) -> [AXUIElement] {
        (copy(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func parent(_ element: AXUIElement) -> AXUIElement? {
        guard let value = copy(element, kAXParentAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var result = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &result) ? result : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var result = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &result) ? result : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        CGRect(origin: point(element, kAXPositionAttribute) ?? .zero,
               size: size(element, kAXSizeAttribute) ?? .zero)
    }

    /// One-line description of an AX element for logging.
    static func describe(_ element: AXUIElement) -> String {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let id = string(element, kAXIdentifierAttribute)
        let title = string(element, kAXTitleAttribute)
        let desc = string(element, kAXDescriptionAttribute)
        let f = frame(element)
        var parts = ["role=\(role.isEmpty ? "?" : role)"]
        if !subrole.isEmpty { parts.append("subrole=\(subrole)") }
        if !id.isEmpty { parts.append("id=\(id)") }
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !desc.isEmpty { parts.append("desc=\"\(desc)\"") }
        parts.append("frame=\(fmt(f))")
        return parts.joined(separator: " ")
    }

    /// Walk parents to the top-level AXWindow (or the topmost node reached).
    static func topWindow(from element: AXUIElement) -> AXUIElement {
        var current = element
        var depth = 0
        while depth < 256 {
            if string(current, kAXRoleAttribute) == "AXWindow" { return current }
            guard let up = parent(current) else { return current }
            current = up
            depth += 1
        }
        return current
    }
}

func fmt(_ r: CGRect) -> String {
    String(format: "(%.0f, %.0f, %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
}

/// Mirrors `AXIntrospection.overlayWindowIdentifier` (internal to the AnnotKit
/// module, so re-declared here rather than widening the library's API for a test).
/// It is the AX identifier `OverlayController` stamps on its overlay panel window.
let overlayWindowIdentifier = "com.annotkit.overlay-window"

func approxEqual(_ a: CGRect, _ b: CGRect, tol: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol &&
    abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}

func approxEqualPt(_ a: CGPoint, _ b: CGPoint, tol: CGFloat = 2) -> Bool {
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
}

/// The idle pill's panel frame for a given host frame — MUST mirror
/// `OverlayController.frame(for: .idle)` (a 240x104 panel pinned to the host's
/// bottom-right corner). Phase 3 asserts the pill re-anchors here after a silent
/// post-layout growth.
/// Where the PILL belongs for a given host frame: inset from the host's
/// bottom-right corner. Asserted instead of the panel frame, because the panel is
/// sized to the control now — idle is one pencil, annotate a six-control row — so
/// its own edges move while the pill's do not. Mirrors `PillStyle.cornerInset`.
func pillCorner(forHost host: CGRect) -> CGPoint {
    CGPoint(x: host.maxX - 20, y: host.minY + 20)
}

/// The pill's own bottom-right corner inside a placed panel.
func pillCorner(inPanel frame: CGRect) -> CGPoint {
    let pill = pillRect(inPanel: frame)
    return CGPoint(x: pill.maxX, y: pill.minY)
}

// Phase 3 frames: a tiny pre-layout frame that grows to a large final frame,
// mirroring the real capture (host attached at ~109x113, real final frame
// 1291x887). Off-screen so the harness never disturbs the display.
let resizeSmall = NSRect(x: -12000, y: -12000, width: 120, height: 100)
let resizeLarge = NSRect(x: -12000, y: -12000, width: 1291, height: 887)

/// AX top-left screen rect of a Cocoa (bottom-left) window frame.
@MainActor
func axRect(ofCocoa frame: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
}

/// AX top-left center point of an AppKit control, matching AnnotKitProbe's math.
@MainActor
func axCenter(of view: NSView) -> CGPoint {
    let inWindow = view.convert(view.bounds, to: nil)
    let inScreen = view.window!.convertToScreen(inWindow)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: inScreen.midX, y: primaryHeight - inScreen.midY)
}

// MARK: - Host window factory

@MainActor
struct HostControls {
    let window: NSWindow
    let primary: NSButton
    let secondary: NSButton
    let field: NSTextField
}

@MainActor
func makeHostWindow(title: String) -> HostControls {
    // Off-screen, like AnnotKitProbe, so the harness never disturbs the screen.
    let window = NSWindow(
        contentRect: NSRect(x: -12000, y: -12000, width: 480, height: 360),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title

    let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))

    let primary = NSButton(title: "Primary action", target: nil, action: nil)
    primary.setAccessibilityIdentifier("Demo.PrimaryButton")
    primary.frame = NSRect(x: 40, y: 260, width: 160, height: 32)

    let secondary = NSButton(title: "Secondary", target: nil, action: nil)
    secondary.setAccessibilityIdentifier("Demo.SecondaryButton")
    secondary.frame = NSRect(x: 220, y: 260, width: 140, height: 32)

    let field = NSTextField(string: "")
    field.placeholderString = "A text field to annotate"
    field.setAccessibilityIdentifier("Demo.TextField")
    field.frame = NSRect(x: 40, y: 200, width: 320, height: 24)

    content.addSubview(primary)
    content.addSubview(secondary)
    content.addSubview(field)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    return HostControls(window: window, primary: primary, secondary: secondary, field: field)
}

// MARK: - Plain host factory (Phase 3 regression)

/// On-screen layout for the Phase 3 growth: an origin + grown size chosen so BOTH
/// the host and the grown overlay panel stay fully on the main screen with margin. A
/// partially off-screen window gets constrained by AppKit (host AND child panel),
/// which would confound the geometry assertions; a fully on-screen frame grows
/// exactly as asked. The origin is shared by the small and grown frames, so the
/// growth is a pure resize (no move) and the child pill is never dragged by
/// parent-move glue — WITHOUT the fix the pill provably stays at the small attach
/// corner. Grown size aims for the real capture's 1291x887, clamped to fit.
@MainActor
func resizeLayout() -> (origin: CGPoint, grownSize: CGSize) {
    let vis = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let grownSize = CGSize(
        width: min(resizeLarge.width, vis.width - 240),
        height: min(resizeLarge.height, vis.height - 240)
    )
    let origin = CGPoint(x: vis.midX - grownSize.width / 2, y: vis.midY - grownSize.height / 2)
    return (origin, grownSize)
}

/// A minimal titled host at the small pre-layout frame, anchored at the grown frame's
/// origin so the growth is a pure, fully-on-screen resize. No controls needed —
/// Phase 3 inspects only the overlay panel's geometry, not the host's AX tree. A
/// fully REAL window (it really moves/resizes) so the overlay's child-window glue,
/// axOrigin math, and hit-test all see real geometry — a fake overridden `frame`
/// desynced the real backing window from what the controller read and corrupted the
/// child glue.
@MainActor
func makeResizeHost(title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: resizeSmall,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.contentView = NSView(frame: NSRect(origin: .zero, size: resizeSmall.size))
    window.makeKeyAndOrderFront(nil)
    window.setFrameOrigin(resizeLayout().origin)
    return window
}

/// Model the diagnosed condition: the host's post-layout growth does NOT deliver
/// `didMove`/`didResize` to the controller. In the real bug the content-driven
/// growth simply never posts them (verified: a plain `setFrame`/`setContentSize`
/// DOES post, and the existing observers already handle that — which is exactly why
/// it could not reproduce this bug). Detaching the controller's geometry observers
/// reproduces that "notification never arrives" state, leaving the post-attach
/// settle poll (the fix) as the ONLY re-sync path — precisely what this regression
/// must exercise. The observers are pre-existing code, NOT part of the fix, so
/// removing them is a faithful stand-in for the growth that never notified them.
@MainActor
func detachGeometryObservers(_ controller: OverlayController, from host: NSWindow) {
    let center = NotificationCenter.default
    center.removeObserver(controller, name: NSWindow.didMoveNotification, object: host)
    center.removeObserver(controller, name: NSWindow.didResizeNotification, object: host)
    center.removeObserver(controller, name: NSWindow.didChangeScreenNotification, object: host)
}

/// The host's FINAL frame: the same origin as the attached frame, grown to the (fit)
/// large size. Keeping the origin fixed means the child overlay panel is not dragged
/// by the parent-move glue, so WITHOUT the fix the panel provably stays at the small
/// attach position (the regression), and WITH it the settle poll re-anchors it.
@MainActor
func grownFrame(from base: CGRect) -> CGRect {
    CGRect(origin: base.origin, size: resizeLayout().grownSize)
}

// MARK: - Hosts that hang off the visible screen (Phase 9)

/// A window that really goes where it is put, bypassing AppKit's
/// keep-the-title-bar-below-the-menu-bar constraint. Needed ONLY by 9d: `setFrame`
/// silently pins any window's top to `visibleFrame.maxY` (measured — a borderless one
/// too), so a host tucked UNDER the menu bar, the one direction in which clamping moves
/// the AX origin, cannot be built any other way. The window is genuinely there — real
/// backing store at a real frame — so every assertion still reads real geometry.
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A real scroller whose clip offset is the 9c witness.
///
/// The panel now scrolls the host by driving the enclosing `NSScrollView`'s clip view
/// DIRECTLY by the event's deltas — never by handing the event object into the host's
/// view tree, because NSScrollView answers a phase `began` (every trackpad scroll) by
/// engaging event tracking against `event.window`, and cross-window that tracking
/// wedges the panel's event delivery and display. A welcome side effect for the probe:
/// the clip offset moves for a SYNTHESIZED event too (the old event-delivery path
/// ignored synthetic wheels), so 9c can assert actual scrolling, not mere routing.
/// Flipped like every real host document (SwiftUI documents are flipped); an
/// unflipped one starts at the content's end, where a downward scroll is a no-op.
final class FlippedProbeDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
func makeScrollPane(frame: NSRect, markerID: String) -> (scroll: NSScrollView, marker: NSButton) {
    let scroll = NSScrollView(frame: frame)
    let document = FlippedProbeDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height * 6))
    // A control INSIDE the scroller, near the top of its document. A note captured
    // on it is a note about SCROLLED CONTENT, which is the only kind whose stored
    // geometry can go stale — and therefore the only witness for "a recalled mark
    // lands on the content it was made on" after the wheel moves it.
    let marker = NSButton(title: markerID, target: nil, action: nil)
    marker.setAccessibilityIdentifier(markerID)
    // 400pt down the document, not 40: the phase scrolls this pane a few hundred
    // points before the mark-tracking measurement runs, and a marker parked at the
    // top would have left the viewport by then — the note could not even be
    // captured, and the measurement would report a missing fixture as a failure.
    marker.frame = NSRect(x: 40, y: 400, width: 220, height: 32)
    document.addSubview(marker)
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    return (scroll, marker)
}

@MainActor
struct ClampedHost {
    let window: NSWindow
    /// Lower and upper halves of the host content, each an independent scroller.
    /// Which one MOVES is the witness for the panel→host coordinate conversion: the
    /// panel re-aims the wheel through screen space before picking a target, so aiming
    /// at a point whose panel-local and host-local interpretations fall in different
    /// halves shows whether the conversion was applied.
    let lowerScroll: NSScrollView
    let upperScroll: NSScrollView
    let button: NSButton
    /// The identified control living INSIDE the upper scroller's document — the
    /// only fixture here that MOVES when the wheel turns, and therefore the one a
    /// note has to keep pointing at.
    let upperMarker: NSButton
}

/// Build a host and stock its content: two stacked scroll spies and one identified
/// button placed inside `visibleBand` (in screen coordinates) so 9b's click assertion is
/// about a control the user can actually reach.
@MainActor
func makeClampedHost(title: String, frame: NSRect, unconstrained: Bool, visibleBand: NSRect) -> ClampedHost {
    let window: NSWindow = unconstrained
        ? UnconstrainedWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        : NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = title
    window.makeKeyAndOrderFront(nil)
    window.setFrame(frame, display: true)

    let size = window.contentView?.bounds.size ?? frame.size
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    let lower = makeScrollPane(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height / 2),
                               markerID: "Clamp.LowerMarker")
    let upper = makeScrollPane(frame: NSRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2),
                               markerID: "Clamp.UpperMarker")
    content.addSubview(lower.scroll)
    content.addSubview(upper.scroll)

    // The button's y is chosen in SCREEN space and converted back, so it sits in the
    // band that survives the clamp whichever edge is being clipped.
    let button = NSButton(title: "Clamped action", target: nil, action: nil)
    button.setAccessibilityIdentifier("Clamp.Button")
    let buttonScreenY = visibleBand.midY
    let contentOriginScreenY = window.convertPoint(toScreen: .zero).y
    button.frame = NSRect(x: 60, y: buttonScreenY - contentOriginScreenY, width: 200, height: 32)
    content.addSubview(button)

    window.contentView = content
    return ClampedHost(window: window, lowerScroll: lower.scroll, upperScroll: upper.scroll,
                       button: button, upperMarker: upper.marker)
}

/// The pill's own rect inside a panel at `frame`, mirroring `OverlayView.toolbar`: the
/// bottom-right corner, 20pt padding, and the pill's real bounds (~180x44 at its widest,
/// the same numbers the 240x104 idle panel is built from). Asserting on the PILL and not
/// the panel is the whole point — the idle panel is deliberately taller than the pill,
/// so "the panel overlaps the screen" would pass while the pill itself sat under the
/// Dock.
func pillRect(inPanel frame: CGRect) -> CGRect {
    // The panel is SIZED TO THE PILL now, so the pill is simply the panel minus the
    // chrome margin its shadow and count badge draw into. These mirror
    // `PillStyle.panelChrome`, which is internal to AnnotKit and so cannot be read
    // from here — the duplication is caught rather than trusted: phase 9a clicks the
    // centre of this rect and phase 12a clicks it to open the menu, both of which
    // fail loudly if it stops describing the real control.
    CGRect(x: frame.minX + probeChrome.left,
           y: frame.minY + probeChrome.bottom,
           width: frame.width - probeChrome.left - probeChrome.right,
           height: frame.height - probeChrome.top - probeChrome.bottom)
}

/// Mirrors `PillStyle.panelChrome` (internal to AnnotKit, so not readable here).
let probeChrome = (top: 14.0, left: 14.0, bottom: 20.0, right: 14.0)

/// The size the toolbar panel used to be, fixed, in BOTH modes — and the size it
/// still starts at before the pill has been laid out. The fix is that it no longer
/// STAYS there: `OverlayPlacement.unmeasuredPanelSize`, mirrored.
let OverlayPlacementSeedSize = CGSize(width: 240, height: 104)

/// Read the overlay's private `axOrigin` / `surfaceSize` by reflection — the same trade
/// `EscapeMonitorLifecycleTests` makes for the Escape monitor. Clamping the panel severs
/// the witness Phase 3 could rely on (the panel frame equalling the host frame), and
/// widening the library's public API purely so a probe can look is a worse deal than
/// this coupling. Returns nil if the property is renamed, and every caller FAILS on nil,
/// so this can never silently assert nothing.
@MainActor
func overlayValue<T>(_ controller: OverlayController, _ label: String, as type: T.Type) -> T? {
    for child in Mirror(reflecting: controller).children where child.label == label {
        return child.value as? T
    }
    return nil
}

/// A wheel event whose `locationInWindow` is exactly `panelLocal` (Cocoa, y-up, relative
/// to the panel). `NSEvent(cgEvent:)` yields `windowNumber == 0`, and AppKit reports such
/// an event's `locationInWindow` as the CG location flipped into Cocoa screen space — so
/// writing the flipped panel-local point into the CG event reproduces exactly what a real
/// wheel delivered to the panel carries. (Verified: the round trip is exact.)
@MainActor
func makeScrollEvent(panelLocal: CGPoint, phase: Int64 = 0) -> NSEvent? {
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                           wheel1: -120, wheel2: 0, wheel3: 0) else { return nil }
    if phase != 0 {
        // A trackpad stream: phase-tagged, continuous. This is the shape that engaged
        // NSScrollView's cross-window event tracking under the old forwarding design.
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    cg.location = CGPoint(x: panelLocal.x, y: primaryHeight - panelLocal.y)
    return NSEvent(cgEvent: cg)
}

// MARK: - SwiftUI host (mirrors AnnotKitDemo's DemoView) for issue-2 coverage

/// A SwiftUI control surface identical in shape to `AnnotKitDemo.DemoView`, so the
/// issue-2 assertions exercise the SAME AX materialization the real on-screen demo
/// did: a bordered button, a plain button, a Toggle (AXCheckBox), a rounded
/// TextField, and a GroupBox list of identified rows. AppKit `NSButton`/`NSTextField`
/// (as Phase 2 uses) would not cover the Toggle or the list-row cases the mandate
/// names.
struct ProbeHostView: View {
    @State private var text = ""
    @State private var toggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AnnotKit Harness")
                .font(.largeTitle).bold()
                .accessibilityIdentifier("Demo.Title")

            HStack(spacing: 12) {
                Button("Primary action") {}
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("Demo.PrimaryButton")
                Button("Secondary") {}
                    .accessibilityIdentifier("Demo.SecondaryButton")
                Toggle("A toggle", isOn: $toggle)
                    .accessibilityIdentifier("Demo.Toggle")
            }

            TextField("A text field to annotate", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityIdentifier("Demo.TextField")

            GroupBox("A list") {
                ForEach(0 ..< 4) { index in
                    Text("Item \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("Demo.Item[\(index)]")
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 460)
    }
}

@MainActor
func makeSwiftUIHost(title: String) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.contentView = NSHostingView(rootView: ProbeHostView())
    // A titled window ordered front is pulled onto a visible screen by AppKit
    // regardless of an off-screen origin, and SwiftUI needs to render for the AX
    // tree to materialize, so center it. The process is an `.accessory` app run
    // from the CLI; the window closes as soon as the checks finish.
    window.center()
    window.makeKeyAndOrderFront(nil)
    return window
}

/// Depth-first search for the AX frame (AX top-left screen coords) of the element
/// with `id` inside a public snapshot. Used to derive each control's true center
/// as the AX point to fire the queries at.
/// The overlay now mounts TWO child panels: a permanently present TOOLBAR panel that
/// carries the pill (fixed size, pinned to the host's bottom-right, unchanged by the
/// menu opening) and a CATCHER panel that exists only while the menu is open and
/// covers the host. `childWindows.first` is therefore no longer "the overlay" — these
/// pick the one each assertion actually means.
@MainActor
func overlayCatcher(of host: NSWindow) -> NSWindow? {
    // The catcher is the host-sized one; the toolbar is the small fixed corner.
    host.childWindows?.max { lhs, rhs in
        (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
    }
}

@MainActor
func overlayToolbar(of host: NSWindow) -> NSWindow? {
    host.childWindows?.min { lhs, rhs in
        (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
    }
}

@MainActor
func frame(ofID id: String, in windows: [WindowSnapshot]) -> CGRect? {
    func walk(_ element: Element) -> CGRect? {
        if element.id == id { return element.frame }
        for child in element.children {
            if let found = walk(child) { return found }
        }
        return nil
    }
    for window in windows {
        if let found = walk(window.root) { return found }
    }
    return nil
}

func center(of rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

func fmtPoint(_ p: CGPoint) -> String { String(format: "(%.0f, %.0f)", p.x, p.y) }

// MARK: - Logging of a raw point-query result

/// Fire the RAW `AXUIElementCopyElementAtPosition` at `axPoint`, log the deepest
/// element + which top-level window owns it, and RETURN the owner label
/// ("HOST WINDOW" / "OVERLAY PANEL" / "UNKNOWN" / "NONE"). The raw query is the
/// unfixed path: it is expected to hit the OVERLAY PANEL while annotating, which
/// is precisely why `AXIntrospection.hitTest` must reject that hit and descend the
/// host subtree instead.
@discardableResult
@MainActor
func logPointQuery(_ label: String, at axPoint: CGPoint, host: NSWindow, panel: NSWindow?) -> String {
    print("  \(label) at AX point \(String(format: "(%.0f, %.0f)", axPoint.x, axPoint.y)):")

    let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

    var hit: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(app, Float(axPoint.x), Float(axPoint.y), &hit)
    guard status == .success, let deepest = hit else {
        print("    AXUIElementCopyElementAtPosition -> status=\(status.rawValue) (no element)")
        return "NONE"
    }

    print("    deepest returned: \(AX.describe(deepest))")

    // Which top-level window does the hit belong to?
    let top = AX.topWindow(from: deepest)
    let topFrame = AX.frame(top)
    let hostAX = axRect(ofCocoa: host.frame)
    let panelAX = panel.map { axRect(ofCocoa: $0.frame) }
    var owner = "UNKNOWN"
    if approxEqual(topFrame, hostAX) { owner = "HOST WINDOW" }
    if let panelAX, approxEqual(topFrame, panelAX) { owner = "OVERLAY PANEL" }
    print("    top-level window: \(AX.describe(top))")
    print("    -> hit belongs to: \(owner)")
    print("       (host AX \(fmt(hostAX)); panel AX \(panelAX.map(fmt) ?? "n/a"))")

    // Full ancestor chain, deepest -> root.
    var chain: [AXUIElement] = []
    var current: AXUIElement? = deepest
    var depth = 0
    while let node = current, depth < 256 {
        chain.append(node)
        current = AX.parent(node)
        depth += 1
    }
    print("    ancestor chain (deepest -> root), \(chain.count) node(s):")
    for (i, node) in chain.enumerated() {
        print("      [\(i)] \(AX.describe(node))")
    }
    return owner
}

// MARK: - Panel-state snapshot (issue 1)

@MainActor
func panelState(_ label: String, host: NSWindow) {
    guard let panel = host.childWindows?.first else {
        print("  \(label): NO child panel on host (childWindows empty)")
        return
    }
    let matches = approxEqual(panel.frame, host.frame)
    print("  \(label): panel visible=\(panel.isVisible) key=\(panel.isKeyWindow) " +
          "level=\(panel.level.rawValue) parent==host=\(panel.parent === host) " +
          "frame=\(fmt(panel.frame)) host=\(fmt(host.frame)) frameMatchesHost=\(matches)")
    print("           NSApp.isActive=\(NSApp.isActive) host.isKey=\(host.isKeyWindow) host.isMain=\(host.isMainWindow)")
}

// MARK: - Driver

@MainActor
final class OverlayProbeDelegate: NSObject, NSApplicationDelegate {
    var h1: NSWindow!
    // Phase 2 (issue 1) direct controller + session, kept alive for the run.
    var controller2: OverlayController?
    var session2: AnnotationSession?
    var h2: HostControls!

    // The control TYPES the mandate names: a button, a text field, a toggle
    // (AXCheckBox), and a list row. Each must resolve to ITSELF through the
    // expanded overlay — not the overlay panel and not the host AXWindow.
    let controlIDs = ["Demo.PrimaryButton", "Demo.TextField", "Demo.Toggle", "Demo.Item[0]"]
    /// AX-frame center of each control, captured from the baseline snapshot.
    var centers: [String: CGPoint] = [:]

    // ---- Issue-2 pass tracking (this is what the previous harness LACKED) ----
    var passIssue2 = true
    func check2(_ cond: Bool, _ msg: String) {
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
        passIssue2 = passIssue2 && cond
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Opt-in interactive reproduction of the vanishing-pill report: drives REAL
        // window-server events (scroll, hover on the pill, hover off) against a tall
        // SwiftUI ScrollView host, sampling the panel's visibility throughout. Kept
        // out of the default run because it needs Accessibility trust to post events
        // and takes over the pointer.
        if ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_HOVERSCROLL"] == "1" {
            runHoverScrollRepro()
            return
        }
        // Opt-in VISUAL check for recallable marks. Everything else in this file
        // measures the model and the hit-testing; a mark is a drawing, and nothing
        // else here can say whether it appears, where, or what it looks like. This
        // captures the three kinds of note, hovers each pin with the REAL pointer,
        // and writes a screenshot per state. Out of the default run because it takes
        // over the pointer and needs screen-recording permission.
        if ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_MARKS"] == "1" {
            runMarksVisual()
            return
        }
        print("=== AnnotKitOverlayProbe: EXPANDED-overlay AX diagnostic ===")
        h1 = makeSwiftUIHost(title: "AnnotKit Harness W1")
        // SwiftUI needs a beat to render before its AX tree materializes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.phase1Baseline()
        }
    }

    // ---- Interactive VISUAL check: recallable marks -----------------------

    var marksVisualHost: NSWindow?
    var marksVisualController: OverlayController?

    /// Drive the three kinds of recalled mark on a real screen and photograph each
    /// one. Hovering is done in FRAME mode on purpose: the pins are inert there, so
    /// no edit card opens over the drawing, and it demonstrates in one shot that
    /// recall survives the pins going inert (which is the whole reason it is
    /// geometric). The last state re-hovers in POINT mode, where the card and the
    /// mark are meant to appear together.
    func runMarksVisual() {
        let outDir = ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_OUT"] ?? NSTemporaryDirectory()
        print("=== MARKS VISUAL: element / area / navigated-area marks, screenshots -> \(outDir) ===")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let window = NSWindow(contentRect: NSRect(x: visible.minX + 140, y: visible.maxY - 660,
                                                  width: 620, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AnnotKit marks"
        window.contentView = NSHostingView(rootView: ProbeSpecificityView())
        window.makeKeyAndOrderFront(nil)
        marksVisualHost = window

        let session = AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()
        marksVisualController = controller

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let panel = overlayCatcher(of: window) else { print("no catcher"); exit(2) }
            let source = MacElementSource()
            let roots = source.snapshot().map(\.root)
            guard let button = self.findElement(id: "Spec.Button", in: roots),
                  let section = self.findElement(id: "Spec.Section", in: roots),
                  let cardText = self.findElement(id: "Spec.CardText", in: roots) else {
                print("fixture not found in the AX tree"); exit(2)
            }
            let axOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: panel.frame,
                                                      primaryHeight: NSScreen.screens.first?.frame.height ?? 0)

            // 1. an ELEMENT note.
            session.select(atAXPoint: center(of: button.frame))
            session.addNote(comment: "element", axOrigin: axOrigin)
            // 2. an AREA note. Swept around the SECTION, not the card: the
            //    navigated note below binds to the card, and two notes anchored to
            //    the same corner put their pins on top of each other — the mark
            //    would then always resolve to whichever is drawn on top, and the
            //    plain area case would never be seen.
            session.select(inAXRect: section.frame.insetBy(dx: -6, dy: -6))
            session.addNote(comment: "area", axOrigin: axOrigin)
            // 3. an AREA note whose binding was then moved UP off the drawn box —
            //    the one case where the note's binding and the user's gesture differ.
            session.select(inAXRect: cardText.frame.insetBy(dx: -6, dy: -6))
            session.selectParent()
            session.addNote(comment: "navigated", axOrigin: axOrigin)
            print("captured \(session.pending.count) notes: " +
                  session.pending.map { "\($0.comment)\($0.drawnRect == nil ? "(element)" : "(area)")" }.joined(separator: ", "))

            // Pin centres in SCREEN coordinates: the anchors are panel-local y-DOWN.
            let pins = session.pending.compactMap { note -> (String, CGPoint)? in
                guard let a = note.anchorRect?.origin else { return nil }
                return (note.comment, CGPoint(x: panel.frame.minX + a.x, y: panel.frame.maxY - a.y))
            }
            var steps: [(String, () -> Void)] = [
                ("0-captured-nothing-drawn", { session.setTool(.frame); self.warp(CGPoint(x: window.frame.midX, y: window.frame.minY + 20)) })
            ]
            for (index, pin) in pins.enumerated() {
                steps.append(("\(index + 1)-hover-\(pin.0)", { session.setTool(.frame); self.warp(pin.1) }))
            }
            if let first = pins.first {
                steps.append(("\(pins.count + 1)-point-mode-card-and-mark", { session.setTool(.point); self.warp(first.1) }))
            }

            var i = 0
            @MainActor func advance() {
                guard i < steps.count else {
                    print("done — screenshots in \(outDir)")
                    exit(0)
                }
                let (name, action) = steps[i]; i += 1
                // Re-assert front before EVERY step: the run photographs whatever is
                // actually on the glass, so an app that comes forward mid-run does
                // not corrupt the result quietly — it corrupts it visibly, in a file
                // that looks nothing like the fixture.
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        self.shoot(window.frame, to: "\(outDir)/marks-\(name).png")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            Task { @MainActor in advance() }
                        }
                    }
                }
            }
            advance()
        }
    }

    /// Move the REAL pointer, with a mouse-moved event so the overlay's hover
    /// actually fires (warping the cursor alone does not deliver one).
    func warp(_ cocoaPoint: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        CGWarpMouseCursorPosition(cg)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Photograph a Cocoa screen rect. `screencapture` takes a TOP-LEFT origin, so
    /// the y is flipped against the primary display's height.
    func shoot(_ cocoaRect: NSRect, to path: String) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let region = "\(Int(cocoaRect.minX)),\(Int(primaryHeight - cocoaRect.maxY))," +
                     "\(Int(cocoaRect.width)),\(Int(cocoaRect.height))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", region, path]
        try? task.run()
        task.waitUntilExit()
        print("      shot \(path)")
    }

    // ---- Interactive reproduction: scroll, hover on, hover off ------------

    var reproHost: NSWindow?
    var reproController: OverlayController?

    func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    func moveMouse(to cocoaPoint: CGPoint) {
        // CGEvent uses top-left global coords; Cocoa is bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left))
    }

    func scroll(lines: Int32) {
        post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
    }

    func sample(_ label: String) {
        guard let host = reproHost else { return }
        let panel = host.childWindows?.first
        let mode = reproController?.session.mode
        print("[\(label)] panel: exists=\(panel != nil) visible=\(panel?.isVisible ?? false) " +
              "frame=\(panel.map { fmt($0.frame) } ?? "-") parentSet=\(panel?.parent != nil) " +
              "hostChildren=\(host.childWindows?.count ?? 0) mode=\(mode.map { "\($0)" } ?? "-") " +
              "hostFrame=\(fmt(host.frame))")
    }

    func runHoverScrollRepro() {
        print("=== HOVER/SCROLL REPRO: open menu -> scroll -> hover on pill -> hover off ===")
        print("AXIsProcessTrusted=\(AXIsProcessTrusted()) (event posting needs trust; if false, events will not land)")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // A tall scrollable SwiftUI host, like the report's "scrollable screens".
        // TALL=1 makes it taller than the display so the CLAMPED placement path runs —
        // AppKit constrains the top under the menu bar but lets the bottom hang.
        let tall = ProcessInfo.processInfo.environment["TALL"] == "1"
        let window = UnconstrainedWindow(
            contentRect: tall ? NSRect(x: 300, y: -500, width: 560, height: 1800)
                              : NSRect(x: 300, y: 80, width: 560, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "AnnotKit Scroll Host"
        window.contentView = NSHostingView(rootView: ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(0 ..< 120, id: \.self) { i in
                    Text("Row \(i) — scrollable content that makes a large AX tree")
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.12))
                        .accessibilityIdentifier("Repro.Row\(i)")
                }
            }.padding(16)
        })
        window.makeKeyAndOrderFront(nil)
        reproHost = window

        let controller = OverlayController(session: AnnotationSession(
            source: MacElementSource(), sink: NotesFileSink(path: "/dev/null")
        ))
        reproController = controller

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            controller.mount(on: window)
            controller.start() // "I open the menu"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                sample("after start")
                guard let panel = window.childWindows?.first else {
                    print("NO PANEL — cannot continue"); exit(2)
                }
                // The pill sits 20pt in from the panel's bottom-right; aim at its center.
                let pill = CGPoint(x: panel.frame.maxX - 20 - 90, y: panel.frame.minY + 20 + 22)
                let content = CGPoint(x: window.frame.midX, y: window.frame.midY)
                // EXIT decides where "off the menu" goes: back onto the catcher
                // (inside), or OUT of the window — the pill hugs the corner, so a
                // real pointer plausibly leaves the window entirely.
                let exitMode = ProcessInfo.processInfo.environment["EXIT"] ?? "inside"
                let offPill: CGPoint
                switch exitMode {
                case "right": offPill = CGPoint(x: window.frame.maxX + 60, y: pill.y)
                case "below": offPill = CGPoint(x: pill.x, y: max(2, panel.frame.minY - 40))
                default: offPill = CGPoint(x: pill.x, y: pill.y + 120)
                }
                print("exit mode = \(exitMode), offPill = \(offPill), tall = \(ProcessInfo.processInfo.environment["TALL"] ?? "0")")

                var step = 0
                let script: [(String, () -> Void)] = [
                    ("move to content", { self.moveMouse(to: content) }),
                    ("scroll x5", { for _ in 0 ..< 5 { self.scroll(lines: -3) } }),
                    ("hover ON pill", { self.moveMouse(to: pill) }),
                    ("hover OFF pill", { self.moveMouse(to: offPill) }),
                    ("hover ON pill 2", { self.moveMouse(to: pill) }),
                    ("hover OFF pill 2", { self.moveMouse(to: offPill) }),
                ]
                @MainActor func advance() {
                    guard step < script.count else {
                        sample("FINAL")
                        let panelNow = window.childWindows?.first
                        let gone = panelNow == nil || !(panelNow?.isVisible ?? false)
                        print(gone ? "\n*** REPRODUCED: the panel is gone ***" : "\n*** NOT reproduced: panel still visible ***")
                        exit(gone ? 3 : 0)
                    }
                    let (name, action) = script[step]
                    step += 1
                    action()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        Task { @MainActor in
                            self.sample(name)
                            advance()
                        }
                    }
                }
                advance()
            }
        }
    }

    // ---- Phase 1: baseline (idle) -----------------------------------------
    func phase1Baseline() {
        print("\n--- Phase 1a: BASELINE (no overlay installed, idle) ---")
        let source = MacElementSource()

        let windows = source.snapshot()
        print("  snapshot() returned \(windows.count) AX window(s):")
        for w in windows {
            print("    - title=\"\(w.title)\" frame=\(fmt(w.frame)) role=\(w.root.role)")
        }

        // Record each control's true AX center from the baseline tree, and prove
        // the resolver already works with NO overlay in the way (so any expanded
        // regression is attributable to the overlay, not the harness math).
        print("  per-control baseline (no overlay):")
        for id in controlIDs {
            guard let f = frame(ofID: id, in: windows) else {
                check2(false, "\(id): NOT FOUND in baseline AX tree (cannot derive a center)")
                continue
            }
            let c = center(of: f)
            centers[id] = c
            let hit = source.hitTest(c)
            print("      \(id): frame=\(fmt(f)) center=\(String(format: "(%.0f, %.0f)", c.x, c.y)) " +
                  "-> hitTest id=\(hit?.id ?? "nil") role=\(hit?.role ?? "nil")")
            check2(hit?.id == id, "\(id): baseline hitTest resolves to the control (sanity for the harness's point math)")
        }

        // Now install + expand.
        print("\n--- Phase 1b: Annotation.install() + Annotation.start() (EXPAND) ---")
        Annotation.install()
        print("  Annotation.isInstalled=\(Annotation.isInstalled) isEnabled=\(Annotation.isEnabled)")
        Annotation.start()
        // Let the panel resize to host.frame and AppKit settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.phase1Expanded(source: source)
        }
    }

    // ---- Phase 1: expanded overlay ----------------------------------------
    func phase1Expanded(source: MacElementSource) {
        let panel = h1.childWindows?.first
        print("  child panel present=\(panel != nil) " +
              "panel.frame=\(panel.map { fmt($0.frame) } ?? "n/a") host.frame=\(fmt(h1.frame)) " +
              "expandedToHost=\(panel.map { approxEqual($0.frame, h1.frame) } ?? false)")
        check2(panel != nil && approxEqual(panel!.frame, h1.frame),
               "overlay child panel is EXPANDED to the full host frame (the full-window path is under test)")

        let hostAX = axRect(ofCocoa: h1.frame)

        // (a) window-list exclusion: the panel IS a live AX window (it would
        // shadow the host in the raw list), yet snapshot() must EXCLUDE it.
        print("\n  (a) AX window-list exclusion (raw kAXWindows vs snapshot()):")
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let rawWins = AX.windows(app)
        print("      raw kAXWindows (\(rawWins.count)):")
        for w in rawWins { print("        - \(AX.describe(w))") }
        let rawHasOverlay = rawWins.contains { AX.string($0, kAXIdentifierAttribute) == overlayWindowIdentifier }
        check2(rawHasOverlay, "overlay panel IS present in the raw kAXWindows list (a real AX window that WOULD shadow the host)")

        let windows = source.snapshot()
        print("      snapshot() returned \(windows.count) AX window(s):")
        for w in windows {
            let looksLikePanel = w.title.isEmpty && approxEqual(w.frame, hostAX)
            let flag = looksLikePanel ? "   <== UNTITLED window at host frame == OVERLAY PANEL SHADOW" : ""
            let ids = collectIDs([w.root])
            let hasControls = ids.contains("Demo.PrimaryButton")
            print("      - title=\"\(w.title)\" frame=\(fmt(w.frame)) role=\(w.root.role) " +
                  "children=\(w.root.children.count) hasDemoControls=\(hasControls)\(flag)")
        }
        let snapHasPanelShadow = windows.contains { $0.title.isEmpty && approxEqual($0.frame, hostAX) }
        let snapHasHostWithControls = windows.contains { $0.title == "AnnotKit Harness W1" && collectIDs([$0.root]).contains("Demo.PrimaryButton") }
        check2(!snapHasPanelShadow, "snapshot() EXCLUDES the overlay panel (no untitled window at the host frame)")
        check2(snapHasHostWithControls, "snapshot() still surfaces the host window WITH its controls through the expanded overlay")

        // axOrigin transform check (title-bar offset?)
        print("\n  axOrigin transform check:")
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let computedOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: h1.frame, primaryHeight: primaryHeight)
        print("      ScreenSpace.windowAXOrigin(host.frame) = \(String(format: "(%.1f, %.1f)", computedOrigin.x, computedOrigin.y))")
        print("      host AX window top-left (from frame)   = \(String(format: "(%.1f, %.1f)", hostAX.minX, hostAX.minY))")
        if let hostWin = windows.first(where: { $0.title == "AnnotKit Harness W1" }) {
            print("      host AXWindow.position (AX)             = \(String(format: "(%.1f, %.1f)", hostWin.frame.minX, hostWin.frame.minY))")
            let dx = hostWin.frame.minX - computedOrigin.x
            let dy = hostWin.frame.minY - computedOrigin.y
            print("      delta (AXWindow - computed origin)     = \(String(format: "(%.1f, %.1f)", dx, dy)) " +
                  "\(abs(dx) < 2 && abs(dy) < 2 ? "-> no title-bar offset" : "-> OFFSET present")")
            check2(abs(dx) < 2 && abs(dy) < 2, "no title-bar/axOrigin offset (computed origin matches the real host AXWindow)")
        }

        // (b) THE CRITICAL CHECK: fire the point query at EACH control through the
        // expanded overlay. The RAW query is expected to hit the OVERLAY PANEL
        // (the underlying defect); the FIXED source.hitTest must nonetheless
        // resolve to THAT control, never a window/application container.
        print("\n  (b) per-control point query THROUGH the expanded overlay:")
        for id in controlIDs {
            guard let c = centers[id] else {
                check2(false, "\(id): no baseline center recorded (skipped)")
                continue
            }
            print("    • \(id):")
            let rawOwner = logPointQuery("RAW query", at: c, host: h1, panel: panel)
            let hit = source.hitTest(c)
            print("      source.hitTest(expanded) -> id=\(hit?.id ?? "nil") role=\(hit?.role ?? "nil") label=\"\(hit?.label ?? "")\" frame=\(hit.map { fmt($0.frame) } ?? "n/a")")
            let resolvesToControl = hit?.id == id
            let notAContainer = hit?.role != "AXWindow" && hit?.role != "AXApplication"
            check2(resolvesToControl && notAContainer,
                   "\(id): resolves THROUGH the expanded overlay to the control (raw hit the \(rawOwner); fixed hitTest -> id=\(hit?.id ?? "nil") role=\(hit?.role ?? "nil"))")
        }

        // Move on to issue-1 phase. Retire W1's overlay first to reduce noise.
        Annotation.stop()
        h1.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.phase2()
        }
    }

    // ---- Phase 2: issue 1 (retention, copy/export, pill persistence) --------
    let notesPath = NSTemporaryDirectory() + "annotkit-overlayprobe.md"
    var pass1 = true
    func check1(_ cond: Bool, _ msg: String) {
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
        pass1 = pass1 && cond
    }

    // ---- Feature-1 pin-MODEL pass tracking (anchors + update + delete) ------
    var passPins = true
    func checkPins(_ cond: Bool, _ msg: String) {
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
        passPins = passPins && cond
    }

    // ---- Phase-3 pass tracking (geometry-settle / mis-placed-pill regression) ----
    var passResize = true
    func check3(_ cond: Bool, _ msg: String) {
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
        passResize = passResize && cond
    }
    var resizeController: OverlayController?
    var resizeSession: AnnotationSession?

    func phase2() {
        print("\n--- Phase 2: issue 1 — retention + copy/export + pill persistence (through the REAL overlay) ---")
        try? FileManager.default.removeItem(atPath: notesPath)
        h2 = makeHostWindow(title: "AnnotKit Harness W2")
        h2.window.makeKeyAndOrderFront(nil)

        // Direct controller == exactly what Annotation.install() news up internally.
        let session = AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: notesPath))
        let controller = OverlayController(session: session)
        controller.mount()
        controller.start()
        self.controller2 = controller
        self.session2 = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            print("  mode after start() = \(session.mode)")
            panelState("BEFORE addNote", host: h2.window)

            // Capture TWO notes through the expanded overlay (addNote appends).
            // Mirror OverlayView's REAL capture path exactly: hand `addNote` the
            // surface's axOrigin and let it snapshot the WINDOW-LOCAL rects itself
            // (it is the only place that can read them before the capture clears the
            // selection). Two DISTINCT controls yield two DISTINCT anchors, so we can
            // prove each note owns its own geometry rather than sharing one.
            let axOrigin = ScreenSpace.windowAXOrigin(
                cocoaFrame: h2.window.frame,
                primaryHeight: NSScreen.screens.first?.frame.height ?? 0
            )
            @MainActor func captureNote(_ comment: String, at view: NSView) -> AnnotationNote? {
                session.select(atAXPoint: axCenter(of: view))
                return session.addNote(comment: comment, axOrigin: axOrigin)
            }
            let noteA = captureNote("issue-1 note A", at: h2.primary)
            let noteB = captureNote("issue-1 note B", at: h2.secondary)
            print("  captured 2 notes -> pending=\(session.pending.count) mode=\(session.mode)")
            check1(session.pending.count == 2, "addNote APPENDS to a retained set (pending == 2)")

            // Feature 1 (pin MODEL): each captured note must carry a window-local
            // pin anchor, non-nil and inside the host window's bounds.
            self.verifyPinAnchors(noteA: noteA, noteB: noteB, host: self.h2.window)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                panelState("AFTER addNote", host: h2.window)
                self.verifyRetentionAndExport(session: session, controller: controller)
            }
        }
    }

    // ---- Phase 2b: retention + idempotent export + copy (non-clearing) ------
    func verifyRetentionAndExport(session: AnnotationSession, controller: OverlayController) {
        print("\n  retention / copy / export (notes PERSIST until Clear):")

        // Export twice: the file must hold the FULL set once (idempotent), and
        // the retained set must survive the export.
        try? session.export()
        try? session.export()
        let afterExport = (try? String(contentsOfFile: notesPath, encoding: .utf8)) ?? ""
        check1(session.pending.count == 2, "export does NOT clear (pending still 2)")
        check1(afterExport.components(separatedBy: "## [").count - 1 == 2, "AGENTATION_NOTES.md holds exactly 2 note blocks after double export (no dupes)")
        check1(afterExport.components(separatedBy: "# Agentation Notes").count == 2, "exported file has a single header")
        check1(afterExport.contains("issue-1 note A") && afterExport.contains("issue-1 note B"), "exported file contains BOTH note comments")

        // Copy renders the full retained set and must not clear it.
        let copied = (try? ClipboardSink(format: .markdown).render(session.pending)) ?? ""
        check1(session.pending.count == 2, "copy does NOT clear (pending still 2)")
        check1(copied.contains("issue-1 note A") && copied.contains("issue-1 note B"), "copy renders BOTH notes (the same set is copyable + exportable)")

        // Leave annotate mode: the pill must persist and the idle panel must be
        // compact so it does not swallow host clicks.
        controller.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.verifyIdlePillPersistence(session: session)
        }
    }

    // ---- Phase 2c: pill persists idle<->annotate; idle panel is pill-sized ---
    func verifyIdlePillPersistence(session: AnnotationSession) {
        print("\n  pill persistence across annotate -> idle, and idle-panel bounds:")
        check1(session.mode == .idle, "controller.stop() -> idle mode")
        check1(session.pending.count == 2, "retained notes survive leaving annotate mode (pending still 2)")

        guard let panel = overlayCatcher(of: h2.window) else {
            check1(false, "child overlay panel STILL PRESENT after stop() (pill persists)")
            verifyPinModel(session: session)
            return
        }
        check1(true, "child overlay panel still present after stop() (pill persists)")

        let host = h2.window.frame
        let compact = !approxEqual(panel.frame, host) && panel.frame.width < host.width && panel.frame.height < host.height
        print("      idle panel.frame=\(fmt(panel.frame)) host.frame=\(fmt(host))")
        check1(compact, "idle panel is COMPACT (pill-sized), not the full host frame")

        // The idle panel must not cover the host's primary button.
        let inWindow = h2.primary.convert(h2.primary.bounds, to: nil)
        let btnScreen = h2.window.convertToScreen(inWindow)
        check1(!panel.frame.intersects(btnScreen), "idle panel does NOT overlap Demo.PrimaryButton (never swallows its clicks)")

        // And a hit-test at the button, THROUGH the idle overlay, still resolves
        // to the control (the overlay window is excluded from the AX query).
        let hit = MacElementSource().hitTest(axCenter(of: h2.primary))
        print("      idle hitTest(Demo.PrimaryButton) -> \(hit.map { "id=\($0.id) role=\($0.role)" } ?? "nil")")
        check1(hit?.id == "Demo.PrimaryButton", "host control still resolves through the idle overlay")

        verifyPinModel(session: session)
    }

    // ---- Feature 1: pin anchors are present + inside the host window -------
    /// Assert both freshly-captured notes carry a non-nil window-local ANCHOR RECT
    /// that lands inside the host window's bounds and matches the element they were
    /// made on, that the two DIFFER (so a pin is per-note, not a single shared
    /// position), and that an ELEMENT note carries NO drawn rect — which is the
    /// field lookup the recalled mark uses to tell an element note from an area one.
    func verifyPinAnchors(noteA: AnnotationNote?, noteB: AnnotationNote?, host: NSWindow) {
        print("\n  Feature 1 — numbered-pin anchor RECTS (window-local, snapshot at addNote):")
        guard let noteA, let noteB else {
            checkPins(false, "both notes captured (addNote returned a note for each control)")
            return
        }
        // Window-local space: origin at the host window's top-left, so a valid
        // anchor sits within (0,0)...(width,height). Grown 1pt for float slack.
        let bounds = CGRect(origin: .zero, size: host.frame.size).insetBy(dx: -1, dy: -1)
        let source = MacElementSource()
        for (label, note, view) in [("note A (pin #1)", noteA, h2.primary), ("note B (pin #2)", noteB, h2.secondary)] {
            guard let rect = note.anchorRect else {
                checkPins(false, "\(label) carries a non-nil window-local anchorRect")
                continue
            }
            // The element's own size, read back out of the AX tree — the same space
            // the note was captured from, so this is "the note remembers the rect it
            // was made on" and not merely "a rect". Deliberately NOT the view's
            // Cocoa bounds: an NSButton's AX frame includes its bezel, so comparing
            // against `view.bounds` would be off by a couple of points for a reason
            // that has nothing to do with what is being asserted.
            let expected = source.hitTest(axCenter(of: view))?.frame.size ?? .zero
            print("      \(label) anchorRect=\(fmt(rect)) drawnRect=\(note.drawnRect.map(fmt) ?? "nil") " +
                  "element size=\(String(format: "%.0fx%.0f", expected.width, expected.height))")
            checkPins(true, "\(label) carries a non-nil window-local anchorRect")
            checkPins(bounds.contains(rect.origin), "\(label) anchorRect's origin (the pin) is inside the host window bounds")
            checkPins(abs(rect.width - expected.width) < 1 && abs(rect.height - expected.height) < 1,
                      "\(label) anchorRect is the SIZE of the element it was made on (a point could not say this)")
            checkPins(note.drawnRect == nil, "\(label) is an ELEMENT note, so it carries NO drawnRect")
        }
        if let a = noteA.anchorRect, let b = noteB.anchorRect {
            checkPins(a != b, "the two notes carry DISTINCT anchor rects (per-note, not a shared position)")
        }
        // The whole point of keeping both fields out of `CodingKeys`: the record an
        // agent reads must be byte-for-byte what it was before marks existed.
        if let json = try? AnnotationFormatter.json([noteA]) {
            checkPins(!json.contains("anchorRect") && !json.contains("drawnRect"),
                      "neither rect appears in the SERIALIZED payload (UI-only, agent-facing record unchanged)")
        } else {
            checkPins(false, "the note could be serialized for the payload check")
        }
    }

    // ---- Feature 1: updateNote edits in place; deleteNote reflows -----------
    /// Assert the pin popover's model ops: `updateNote` mutates the target note's
    /// comment in place (id/order/count unchanged), and `deleteNote` drops a note
    /// so the remaining indices AND the count re-flow (the pin number and count
    /// badge derive from `pending`'s order/size, so this is automatic).
    func verifyPinModel(session: AnnotationSession) {
        print("\n  Feature 1 — pin edit (updateNote) + delete (deleteNote reflow):")
        guard session.pending.count == 2 else {
            checkPins(false, "two notes retained going into the pin-model checks (have \(session.pending.count))")
            finish()
            return
        }
        // pending order IS the reflow order: pending[0] renders as pin #1.
        let first = session.pending[0]
        let second = session.pending[1]

        // updateNote (the popover's Save) edits the comment in place only.
        session.updateNote(id: first.id, comment: "edited via pin popover")
        let editedFirst = session.pending.first { $0.id == first.id }
        checkPins(editedFirst?.comment == "edited via pin popover", "updateNote changes the target note's comment in place")
        checkPins(session.pending.count == 2, "updateNote leaves the retained count unchanged (still 2)")
        checkPins(session.pending.first?.id == first.id, "updateNote preserves order/identity (still pin #1)")
        // updateNote on an unknown id is a no-op (does not append or clear).
        session.updateNote(id: "no-such-id", comment: "ignored")
        checkPins(session.pending.count == 2, "updateNote on an unknown id is a no-op")

        // deleteNote (the popover's Delete) drops the FIRST note; the survivor
        // reflows from pin #2 to pin #1 for free.
        session.deleteNote(id: first.id)
        checkPins(session.pending.count == 1, "deleteNote removes the note (count re-flows 2 -> 1)")
        checkPins(!session.pending.contains { $0.id == first.id }, "the deleted note is gone from the retained set")
        checkPins(session.pending.first?.id == second.id, "the survivor is the OTHER note, now reflowed to index 0 (pin #1)")
        checkPins(session.pending.first?.anchorRect == second.anchorRect, "the survivor keeps its OWN captured anchor rect after the reflow")

        // Deleting the last note empties the set, so the count badge would hide.
        session.deleteNote(id: second.id)
        checkPins(session.pending.isEmpty, "deleting the last note empties the retained set (count badge -> hidden)")

        phase3()
    }

    // ---- Phase 3: the mis-placed-pill regression ---------------------------
    // Reproduces the CONFIRMED bug headlessly: a content-sized host attaches at its
    // tiny PRE-LAYOUT frame and grows to its final frame WITHOUT posting
    // didMove/didResize, so the overlay's notification observers never re-fire.
    // Before the settle-poll fix the pill stayed at the stale small corner (off the
    // app, at the screen's top-left) and axOrigin stayed stale (dead hover). These
    // sub-phases FAIL without the fix (panel + axOrigin stuck on the small frame) and
    // PASS with it (the settle poll re-syncs to the final frame).
    func phase3() {
        print("\n--- Phase 3: mis-placed-pill regression (host grows post-attach, NO move/resize notification) ---")
        // Retire W2's overlay + window so W3 is the only visible host `hostWindow()`
        // can resolve to.
        controller2?.unmount()
        h2?.window.orderOut(nil)
        phase3aIdle()
    }

    // ---- Phase 3a: the IDLE pill re-anchors to the host's FINAL corner ------
    func phase3aIdle() {
        print("\n  3a — IDLE pill re-anchors to the host's FINAL frame:")
        let host = makeResizeHost(title: "AnnotKit Harness W3 (idle)")
        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-resize-idle.md")
        )
        let controller = OverlayController(session: session)
        controller.mount()   // attaches at the SMALL pre-layout frame + schedules the settle poll
        detachGeometryObservers(controller, from: host)   // the growth will NOT notify the controller
        resizeController = controller
        resizeSession = session

        // `base` is the REAL attached frame (AppKit may place a titled window on a
        // screen); the pill's corner is derived from it. `grown` keeps that origin so
        // the child panel is not dragged by the parent-move glue — WITHOUT the fix it
        // provably stays at the small frame's corner.
        let base = host.frame
        let grown = grownFrame(from: base)
        let attached = host.childWindows?.first?.frame
        print("      attached idle panel=\(attached.map(fmt) ?? "nil") (host \(fmt(base)); " +
              "pill corner expect \(fmtPoint(pillCorner(forHost: base))))")
        check3(attached.map { approxEqualPt(pillCorner(inPanel: $0), pillCorner(forHost: base)) } ?? false,
               "sanity: the pill attaches at the small pre-layout corner")

        // Grow the host on the next runloop turn (inside the settle-poll window),
        // with NO re-sync-triggering notification reaching the controller.
        DispatchQueue.main.async { host.setFrame(grown, display: true) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let panel = host.childWindows?.first?.frame
            print("      after growth: host=\(fmt(host.frame)) idle panel=\(panel.map(fmt) ?? "nil") " +
                  "pill corner=\(panel.map { fmtPoint(pillCorner(inPanel: $0)) } ?? "nil") " +
                  "(expect \(fmtPoint(pillCorner(forHost: grown))), stale would be \(fmtPoint(pillCorner(forHost: base))))")
            check3(panel.map { approxEqualPt(pillCorner(inPanel: $0), pillCorner(forHost: grown)) } ?? false,
                   "the idle pill sits at the LARGE window's corner after the post-layout growth")
            check3(panel.map { !approxEqualPt(pillCorner(inPanel: $0), pillCorner(forHost: base)) } ?? false,
                   "the idle pill is no longer stuck at the stale small pre-layout corner")
            self.resizeController?.unmount()
            host.orderOut(nil)
            self.phase3bAnnotate()
        }
    }

    // ---- Phase 3b: the ANNOTATE full-window frame + axOrigin track the FINAL frame ----
    func phase3bAnnotate() {
        print("\n  3b — ANNOTATE full-window frame + axOrigin track the host's FINAL frame:")
        let host = makeResizeHost(title: "AnnotKit Harness W3 (annotate)")
        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-resize-annotate.md")
        )
        let controller = OverlayController(session: session)
        controller.mount()
        controller.start()   // enter annotate mode BEFORE the growth; catcher covers the small frame now
        detachGeometryObservers(controller, from: host)   // the growth will NOT notify the controller
        resizeController = controller
        resizeSession = session

        let base = host.frame
        let grown = grownFrame(from: base)
        let attached = host.childWindows?.first?.frame
        print("      annotate panel (pre-growth)=\(attached.map(fmt) ?? "nil") expect \(fmt(base))")
        check3(attached.map { approxEqual($0, base) } ?? false,
               "sanity: annotate catcher covers the small pre-layout frame")

        DispatchQueue.main.async { host.setFrame(grown, display: true) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let panel = host.childWindows?.first?.frame
            print("      after growth: host=\(fmt(host.frame)) annotate panel=\(panel.map(fmt) ?? "nil") expect \(fmt(grown))")
            check3(panel.map { approxEqual($0, grown) } ?? false,
                   "annotate catcher expands to the LARGE final frame (covers the whole grown app)")

            // axOrigin: `syncFrameAndOrigin` sets the panel frame AND axOrigin from the
            // SAME `host.frame` read, and in annotate mode the panel frame == host.frame,
            // so the panel frame is the exact witness of the axOrigin the overlay now
            // transforms hover/clicks through. Assert it tracks the LARGE frame's AX
            // top-left (the dead-hover half of the bug), not the stale small one.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let axLarge = ScreenSpace.windowAXOrigin(cocoaFrame: grown, primaryHeight: primaryHeight)
            let axSmall = ScreenSpace.windowAXOrigin(cocoaFrame: base, primaryHeight: primaryHeight)
            let axNow = panel.map { ScreenSpace.windowAXOrigin(cocoaFrame: $0, primaryHeight: primaryHeight) }
            print("      axOrigin now=\(axNow.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "nil") " +
                  "largeAX=\(String(format: "(%.1f, %.1f)", axLarge.x, axLarge.y)) " +
                  "smallAX=\(String(format: "(%.1f, %.1f)", axSmall.x, axSmall.y))")
            check3(axNow.map { approxEqualPt($0, axLarge) } ?? false,
                   "axOrigin matches the LARGE final frame (host AX top-left the overlay hit-tests through)")
            check3(axNow.map { !approxEqualPt($0, axSmall) } ?? false,
                   "axOrigin is no longer the stale small-frame origin (fixes the dead AX hit-test / dead hover)")

            self.resizeController?.unmount()
            host.orderOut(nil)
            self.phase4Chrome()
        }
    }

    // ---- Phase 4: window CHROME is never an annotation target ---------------
    // The traffic lights are real, actionable AXButtons, so before the subrole
    // filter the hit-test offered them as targets (user bug: hovering close/
    // minimize/zoom highlighted them). While annotating, the native point query
    // hits the expanded overlay and is DISCARDED, so chrome resolves via the
    // geometric hitBeneathOverlay path — this phase exercises that real path
    // end-to-end (filter must cover deepestNonContainer too, or the fallback
    // hands the rejected button straight back), plus a positive control proving
    // real content still resolves.
    var chromeController: OverlayController?
    var chromeSession: AnnotationSession?
    var chromeHost: NSWindow?
    var passChrome = true
    func check4(_ cond: Bool, _ msg: String) {
        passChrome = passChrome && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    func phase4Chrome() {
        print("\n--- Phase 4: window chrome (traffic lights) is never an annotation target ---")
        // Retire Phase 1's host: titled windows are constrained ON-SCREEN by
        // AppKit, and a still-ordered-in W1 overlapping this phase's host makes
        // the geometric hit-test descend the WRONG window.
        h1?.orderOut(nil)
        // .miniaturizable + .resizable so all three traffic lights exist (the
        // other probe hosts are only titled+closable).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Harness W4 (chrome)"
        window.contentView = NSHostingView(
            rootView: Button("Probe Target") {}
                .accessibilityIdentifier("Probe.ChromeContent")
                .padding(40)
        )
        window.makeKeyAndOrderFront(nil)
        chromeHost = window

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-chrome.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()   // expand, so hits resolve through the geometric path
        chromeController = controller
        chromeSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let source = MacElementSource()
            // Chrome buttons via raw AX (subrole is not part of the public
            // Element); the content control via the public snapshot.
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let axWindow = AX.windows(app).first {
                AX.string($0, kAXTitleAttribute) == "AnnotKit Harness W4 (chrome)"
            }
            let chromeSubroles: Set<String> = [
                kAXCloseButtonSubrole as String,
                kAXMinimizeButtonSubrole as String,
                kAXZoomButtonSubrole as String,
                kAXFullScreenButtonSubrole as String,
            ]
            let chrome = axWindow.map { self.axFindAll(in: $0, subroles: chromeSubroles, depth: 0) } ?? []
            check4(chrome.count >= 3, "host exposes >=3 traffic-light AXButtons (found \(chrome.count))")
            for button in chrome {
                let frame = AX.frame(button)
                let subrole = AX.string(button, kAXSubroleAttribute)
                let hit = source.hitTest(CGPoint(x: frame.midX, y: frame.midY))
                print("      \(subrole) center=\(fmt(frame)) -> \(hit.map { "#\($0.id)" } ?? "nil")")
                check4(hit == nil, "\(subrole) is NOT an annotation target")
            }
            if let content = self.findElement(id: "Probe.ChromeContent", in: source.snapshot().map(\.root)) {
                let hit = source.hitTest(CGPoint(x: content.frame.midX, y: content.frame.midY))
                check4(hit?.id == "Probe.ChromeContent",
                       "content control still resolves through the expanded overlay (got \(hit.map { "#\($0.id)" } ?? "nil"))")
            } else {
                check4(false, "content control Probe.ChromeContent present in the snapshot")
            }
            self.chromeController?.unmount()
            window.orderOut(nil)
            self.phase5Card()
        }
    }

    // ---- Phase 5: a seeded CONTAINER resolves when its BODY is hovered -------
    // Mirrors the HUD-card fix: cards get .accessibilityElement(children:
    // .contain) + an identifier, and hovering the card body (inside the card,
    // outside any child) must resolve to the CARD, while hovering a child still
    // resolves the child. Validates nearestIdentified's identified-container
    // branch through the expanded overlay.
    var cardController: OverlayController?
    var cardSession: AnnotationSession?
    var cardHost: NSWindow?
    var passCard = true
    func check5(_ cond: Bool, _ msg: String) {
        passCard = passCard && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    func phase5Card() {
        print("\n--- Phase 5: seeded container (card) resolves on body hover ---")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Harness W5 (card)"
        window.contentView = NSHostingView(rootView: ProbeCardView())
        window.makeKeyAndOrderFront(nil)
        cardHost = window

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-card.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()
        cardController = controller
        cardSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let source = MacElementSource()
            let roots = source.snapshot().map(\.root)
            guard let card = self.findElement(id: "Probe.Card", in: roots),
                  let text = self.findElement(id: "Probe.CardText", in: roots) else {
                check5(false, "snapshot exposes Probe.Card + Probe.CardText")
                self.cardController?.unmount()
                window.orderOut(nil)
                self.finish()
                return
            }
            // A body point: inside the card, left of the (centered) text child.
            let body = CGPoint(x: card.frame.minX + 16, y: card.frame.midY)
            check5(!text.frame.contains(body), "sanity: the body point is outside the text child")
            let bodyHit = source.hitTest(body)
            print("      card=\(fmt(card.frame)) text=\(fmt(text.frame)) body-hit -> \(bodyHit.map { "#\($0.id)" } ?? "nil")")
            check5(bodyHit?.id == "Probe.Card",
                   "hovering the card BODY resolves to the seeded container (got \(bodyHit.map { "#\($0.id)" } ?? "nil"))")
            let textHit = source.hitTest(CGPoint(x: text.frame.midX, y: text.frame.midY))
            check5(textHit?.id == "Probe.CardText",
                   "hovering a child still resolves the CHILD, not the container (got \(textHit.map { "#\($0.id)" } ?? "nil"))")
            self.cardController?.unmount()
            window.orderOut(nil)
            self.phase6Specificity()
        }
    }

    // ---- Phase 6: pure positional specificity (r3, cli-vtrvt.1) --------------
    // The user-specified model: the smallest/deepest MEANINGFUL node under the
    // cursor wins, and moving between a child and its ancestors' padding
    // switches levels naturally. Covers the previously-untested AXValue case:
    // plain SwiftUI Text (value-only, empty title/description) must win over
    // its identified ancestors — before the fix it climbed to the page wrapper.
    var specController: OverlayController?
    var specSession: AnnotationSession?
    var specHost: NSWindow?
    var passSpec = true
    func check6(_ cond: Bool, _ msg: String) {
        passSpec = passSpec && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    func phase6Specificity() {
        print("\n--- Phase 6: positional specificity (button > text > card > section by cursor position) ---")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Harness W6 (specificity)"
        window.contentView = NSHostingView(rootView: ProbeSpecificityView())
        window.makeKeyAndOrderFront(nil)
        specHost = window

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-specificity.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()
        specController = controller
        specSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let source = MacElementSource()
            let roots = source.snapshot().map(\.root)
            guard let button = self.findElement(id: "Spec.Button", in: roots),
                  let card = self.findElement(id: "Spec.Card", in: roots),
                  let cardText = self.findElement(id: "Spec.CardText", in: roots),
                  let section = self.findElement(id: "Spec.Section", in: roots) else {
                check6(false, "snapshot exposes Spec.Button/Card/CardText/Section")
                self.specController?.unmount()
                window.orderOut(nil)
                self.finish()
                return
            }

            // 6a — button center resolves the button (actionable, unchanged).
            let buttonHit = source.hitTest(CGPoint(x: button.frame.midX, y: button.frame.midY))
            check6(buttonHit?.id == "Spec.Button", "button center -> the button (got \(buttonHit.map { "#\($0.id)" } ?? "nil"))")

            // 6b — UNIDENTIFIED plain-text center resolves the TEXT, not an
            // identified ancestor (the AXValue case — the r3 root cause).
            let plainText = self.findFirst(in: roots) {
                $0.role == "AXStaticText" && $0.value.contains("plain value text")
            }
            check6(plainText != nil, "snapshot exposes the unidentified value-only text")
            if let plainText {
                let hit = source.hitTest(CGPoint(x: plainText.frame.midX, y: plainText.frame.midY))
                check6(hit.map { $0.role == "AXStaticText" && $0.id != "Spec.Section" } ?? false,
                       "plain text center -> the TEXT itself, not the section (got \(hit.map { "#\($0.id) \($0.role)" } ?? "nil"))")
            }

            // 6c — card padding (inside card surface, outside its text) -> card.
            let cardPad = CGPoint(x: card.frame.minX + 12, y: card.frame.midY)
            check6(!cardText.frame.contains(cardPad), "sanity: card-padding point misses the card's text")
            let cardHit = source.hitTest(cardPad)
            check6(cardHit?.id == "Spec.Card", "card padding -> the card surface (got \(cardHit.map { "#\($0.id)" } ?? "nil"))")

            // 6d — card TEXT center -> the text (child beats its card).
            let textHit = source.hitTest(CGPoint(x: cardText.frame.midX, y: cardText.frame.midY))
            check6(textHit?.id == "Spec.CardText", "card text -> the text, not the card (got \(textHit.map { "#\($0.id)" } ?? "nil"))")

            // 6e — SECTION padding (inside the section surface, outside the
            // button/text/card cluster) -> the section: moving the cursor out
            // of a child naturally selects the parent level.
            let sectionPad = CGPoint(x: section.frame.minX + 10, y: section.frame.minY + 10)
            let insideChild = [button, card, cardText].contains { $0.frame.contains(sectionPad) }
            check6(!insideChild, "sanity: section-padding point misses every child")
            let sectionHit = source.hitTest(sectionPad)
            check6(sectionHit?.id == "Spec.Section", "section padding -> the section surface (got \(sectionHit.map { "#\($0.id)" } ?? "nil"))")

            // 6f — REGION fallback (cli-vtrvt.2): a click beyond every node
            // (the outer padding outside the section surface) is not dropped —
            // it captures a region note anchored to the nearest meaningful
            // element with the offset from its top-left.
            let bare = CGPoint(x: section.frame.minX - 10, y: section.frame.midY)
            let bareHit = source.hitTest(bare)
            check6(bareHit == nil, "sanity: the bare point hit-tests to nothing (got \(bareHit.map { "#\($0.id)" } ?? "nil"))")
            let regionSelection = self.specSession?.select(atAXPoint: bare)
            check6(regionSelection?.role == "AXRegion",
                   "bare click selects a REGION (got \(regionSelection.map { "#\($0.id) \($0.role)" } ?? "nil"))")
            let regionNote = self.specSession?.addNote(comment: "region probe")
            check6(regionNote?.regionOffset != nil, "the region note carries the anchor offset")
            check6(regionNote?.selector == "#Spec.Section",
                   "the region note anchors to the nearest meaningful element (got \(regionNote?.selector ?? "nil"))")

            self.specController?.unmount()
            window.orderOut(nil)
            self.phase7Marquee()
        }
    }

    // ---- Phase 7: marquee frame selection (F4) ------------------------------
    // The user press-drags a rectangle around what they mean. Unlike a click
    // (deepest-wins) a FRAME means "this whole thing", so the LARGEST element the
    // frame surrounds wins — the promise being that a sloppy rect around a card
    // binds to the card and not to the label inside it. Reuses the Phase 6
    // fixture, whose seeded card / card text / section / button are exactly the
    // nesting a marquee must disambiguate, and runs through the EXPANDED overlay
    // because that is when a drag actually happens.
    var marqueeController: OverlayController?
    var marqueeSession: AnnotationSession?
    var marqueeHost: NSWindow?
    var passMarquee = true
    func check7(_ cond: Bool, _ msg: String) {
        passMarquee = passMarquee && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    /// One-line rendering of a ladder for the log.
    func describe(_ ladder: [Element]) -> String {
        ladder.isEmpty ? "[] (region fallback)" : ladder.map { "#\($0.id) \(fmt($0.frame))" }.joined(separator: "  ->  ")
    }

    /// The ladder contract the session depends on: `ladder[0]` is the bound
    /// target, and every further rung is a DISTINCT, strictly enclosing component
    /// (so widening from a framed selection only ever gets coarser).
    func checkLadderShape(_ ladder: [Element], label: String) {
        guard let target = ladder.first else {
            check7(false, "\(label): ladder is non-empty")
            return
        }
        var seen: Set<String> = [target.id]
        let targetArea = target.frame.width * target.frame.height
        var wellFormed = true
        for rung in ladder.dropFirst() {
            let encloses = rung.frame.contains(target.frame)
            let notSmaller = rung.frame.width * rung.frame.height >= targetArea
            let distinct = seen.insert(rung.id).inserted
            if !(encloses && notSmaller && distinct) {
                wellFormed = false
                print("        rung #\(rung.id) \(fmt(rung.frame)) encloses=\(encloses) " +
                      "notSmaller=\(notSmaller) distinct=\(distinct)")
            }
        }
        check7(wellFormed, "\(label): every rung above ladder[0] encloses the target, is no smaller, and is distinct")
        // Regression guard for a defect this probe found: the ancestor chain climbs
        // to AXApplication, whose direct CHILDREN are the app's windows — our own
        // overlay panel among them, identified and enclosing everything. It used to
        // be the top rung of every ladder, so widening bound the note to AnnotKit's
        // own UI. Never a host component, so never a rung.
        check7(!ladder.contains { $0.id == overlayWindowIdentifier },
               "\(label): no rung is AnnotKit's own overlay panel")
    }

    func phase7Marquee() {
        print("\n--- Phase 7: marquee frame selection (drawn rect -> element) ---")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Harness W7 (marquee)"
        window.contentView = NSHostingView(rootView: ProbeSpecificityView())
        window.makeKeyAndOrderFront(nil)
        marqueeHost = window

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-marquee.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()
        marqueeController = controller
        marqueeSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let source = MacElementSource()
            let roots = source.snapshot().map(\.root)
            guard let button = self.findElement(id: "Spec.Button", in: roots),
                  let card = self.findElement(id: "Spec.Card", in: roots),
                  let cardText = self.findElement(id: "Spec.CardText", in: roots),
                  let section = self.findElement(id: "Spec.Section", in: roots) else {
                check7(false, "snapshot exposes Spec.Button/Card/CardText/Section")
                self.marqueeController?.unmount()
                window.orderOut(nil)
                self.finish()
                return
            }
            print("      fixture: card=\(fmt(card.frame)) cardText=\(fmt(cardText.frame)) " +
                  "section=\(fmt(section.frame)) button=\(fmt(button.frame))")

            // 7a — a SLOPPY frame around the card (drawn 8pt proud of it, the way a
            // hand-drag overshoots) binds to the CARD. The frame also fully
            // surrounds the card's text, so this is the check that largest-wins is
            // in force: without it the drag would bind to the label inside.
            let aroundCard = card.frame.insetBy(dx: -8, dy: -8)
            let cardLadder = source.marqueeLadder(in: aroundCard)
            print("      frame around card \(fmt(aroundCard)) -> \(self.describe(cardLadder))")
            check7(aroundCard.contains(cardText.frame), "sanity: the drawn frame also surrounds the card's TEXT")
            check7(cardLadder.first?.id == "Spec.Card",
                   "frame around the card -> #Spec.Card (got \(cardLadder.first.map { "#\($0.id)" } ?? "nil"))")
            check7(cardLadder.first?.id != "Spec.CardText",
                   "frame around the card is NOT bound to the text inside it (the feature's core promise)")
            self.checkLadderShape(cardLadder, label: "card ladder")
            check7(cardLadder.dropFirst().contains { $0.id == "Spec.Section" },
                   "the card ladder can still widen to #Spec.Section (widening works from a framed selection)")

            // 7b — a frame around the whole section binds to the SECTION, even
            // though it surrounds the card, the button and the texts as well.
            let aroundSection = section.frame.insetBy(dx: -6, dy: -6)
            let sectionLadder = source.marqueeLadder(in: aroundSection)
            print("      frame around section \(fmt(aroundSection)) -> \(self.describe(sectionLadder))")
            check7(sectionLadder.first?.id == "Spec.Section",
                   "frame around the section -> #Spec.Section (got \(sectionLadder.first.map { "#\($0.id)" } ?? "nil"))")
            self.checkLadderShape(sectionLadder, label: "section ladder")

            // 7c — a tight frame around just the button binds to the BUTTON: a
            // small drag stays as specific as a click would have been.
            let aroundButton = button.frame.insetBy(dx: -4, dy: -4)
            let buttonLadder = source.marqueeLadder(in: aroundButton)
            print("      frame around button \(fmt(aroundButton)) -> \(self.describe(buttonLadder))")
            check7(buttonLadder.first?.id == "Spec.Button",
                   "frame around the button -> #Spec.Button (got \(buttonLadder.first.map { "#\($0.id)" } ?? "nil"))")
            self.checkLadderShape(buttonLadder, label: "button ladder")

            // 7d — a frame drawn strictly INSIDE the card, in its padding, that
            // surrounds NOTHING: the enclosing fallback binds it to the tightest
            // thing it was drawn inside, the card — not the section that also
            // contains it. This is the rect generalization of the point-region path.
            let insideCard = CGRect(x: card.frame.minX + 6, y: card.frame.midY - 8, width: 16, height: 16)
            let insideLadder = source.marqueeLadder(in: insideCard)
            print("      frame inside card \(fmt(insideCard)) -> \(self.describe(insideLadder))")
            check7(card.frame.contains(insideCard), "sanity: the inside frame is strictly within the card")
            check7(!insideCard.intersects(cardText.frame), "sanity: the inside frame surrounds nothing (misses the text)")
            check7(insideLadder.first?.id == "Spec.Card",
                   "frame inside the card -> #Spec.Card via the enclosing fallback (got \(insideLadder.first.map { "#\($0.id)" } ?? "nil"))")
            self.checkLadderShape(insideLadder, label: "inside-card ladder")

            // 7e — a frame over empty space, outside every window: the adapter
            // returns [] and hands the drag to the session's region fallback rather
            // than binding a note to whatever happened to be frontmost.
            let nowhere = CGRect(x: -20000, y: -20000, width: 120, height: 90)
            let nowhereLadder = source.marqueeLadder(in: nowhere)
            print("      frame over empty space \(fmt(nowhere)) -> \(self.describe(nowhereLadder))")
            check7(nowhereLadder.isEmpty, "frame outside any window -> [] (region-fallback handoff)")

            // 7f — a press-release that never moved is a CLICK, not a marquee: a
            // degenerate rect must not bind to everything that encloses it.
            let degenerate = CGRect(origin: center(of: card.frame), size: .zero)
            check7(source.marqueeLadder(in: degenerate).isEmpty,
                   "zero-area frame -> [] (a click is not a marquee)")

            // 7g — NOTHING from AnnotKit's own overlay can enter the candidate set.
            // Sharper for a marquee than for a click: a drag rect by construction
            // spans screen the overlay is drawn across, and overlay elements are
            // genuinely identified and genuinely meaningful, so the rule cannot
            // reject them — a large overlay surface would WIN pass 1 on area and
            // bind the user's note to our own UI. The walk is rooted at the HOST
            // window (the overlay is filtered out of `kAXWindows` by identifier
            // BEFORE the root is picked, never by "key" or "frontmost"), so the
            // overlay's descendants are out of reach by construction. This asserts
            // that construction against the live tree instead of trusting it.
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let rawWindows = AX.windows(app)
            // BOTH overlay panels carry the identifier — correctly, since the point
            // query has to skip the toolbar as well as the catcher — so pick the one
            // that actually spans the host: the catcher. Taking `.first` here grabbed
            // the small fixed toolbar and made the span check below fail.
            let overlayPanel = rawWindows
                .filter { AX.string($0, kAXIdentifierAttribute) == overlayWindowIdentifier }
                .max { AX.frame($0).width * AX.frame($0).height < AX.frame($1).width * AX.frame($1).height }
            check7(overlayPanel != nil, "the overlay panel IS a live AX window during the drag (a real shadowing risk)")
            if let overlayPanel {
                let panelFrame = AX.frame(overlayPanel)
                // Without this the whole sub-phase would be vacuous: an overlay that
                // does not cover the drag region proves nothing about one that does.
                check7(panelFrame.contains(card.frame),
                       "sanity: the expanded overlay SPANS the drag region (the card is drawn beneath it)")
                let overlayIDs = Set(self.axCollectIDs(in: overlayPanel, depth: 0))
                let hostWindow = rawWindows.first { AX.string($0, kAXTitleAttribute) == "AnnotKit Harness W7 (marquee)" }
                let panelIsAXChildOfHost = hostWindow.map { host in
                    AX.children(host).contains { CFEqual($0, overlayPanel) }
                } ?? false
                print("      overlay panel \(fmt(panelFrame)) carries \(overlayIDs.count) identified element(s); " +
                      "exposed as an AX CHILD of the host window: \(panelIsAXChildOfHost)")
                let everyResult = cardLadder + sectionLadder + buttonLadder + insideLadder
                check7(!everyResult.contains { overlayIDs.contains($0.id) },
                       "no marquee result — target or rung — is an element from AnnotKit's own overlay subtree")
            }

            self.marqueeController?.unmount()
            window.orderOut(nil)
            self.phase8Navigation()
        }
    }

    // ---- Phase 8: selection navigation (F1 + F2) ----------------------------
    // Parent/Child is BIDIRECTIONAL navigation over one path, and the property
    // that makes it usable is that it round-trips: whatever you climbed, you can
    // walk back down to, and vice versa. That is a claim about a LIVE tree — the
    // whole reason descent replays history instead of re-querying is that a live
    // UI would answer the same question differently on consecutive presses — so it
    // has to be asserted here rather than only against hand-built fixtures.
    var navController: OverlayController?
    var navSession: AnnotationSession?
    var navHost: NSWindow?
    var passNav = true
    func check8(_ cond: Bool, _ msg: String) {
        passNav = passNav && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    /// Climb to the broadest rung, returning how many rungs were actually walked.
    /// Doubles as the probe's only view of the path's SHAPE: the session keeps the
    /// path private, so "how many rungs sit above the bound one" is observable only
    /// by walking them — which is what lets 8c prove no extra rung was inserted.
    func climbToTop(_ session: AnnotationSession) -> Int {
        var climbed = 0
        while session.selectParent() != nil { climbed += 1 }
        return climbed
    }

    /// Walk `count` rungs back down, returning how many actually moved.
    @discardableResult
    func descend(_ session: AnnotationSession, _ count: Int) -> Int {
        var moved = 0
        for _ in 0 ..< count where session.selectChild() != nil { moved += 1 }
        return moved
    }

    /// Identity for a round-trip assertion: id AND frame. The id alone is not
    /// enough — an UNSEEDED element's id is its slash-joined path, which two
    /// sibling rows of the same role and depth can share — and the frame alone is
    /// not enough either, because a coextensive surface shares it with the content
    /// group in front of it.
    func same(_ lhs: Element?, _ rhs: Element?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.id == rhs.id && approxEqual(lhs.frame, rhs.frame, tol: 0.5)
    }

    func label(_ element: Element?) -> String {
        guard let element else { return "nil" }
        let text = element.value.isEmpty ? element.label : element.value
        return "#\(element.id) \(element.role)\(text.isEmpty ? "" : " \"\(text)\"") \(fmt(element.frame))"
    }

    func phase8Navigation() {
        print("\n--- Phase 8: selection navigation (parent/child round trips, frame anchoring) ---")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Harness W8 (navigation)"
        window.contentView = NSHostingView(rootView: ProbeNavigationView())
        window.makeKeyAndOrderFront(nil)
        navHost = window

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-navigation.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: window)
        controller.start()
        navController = controller
        navSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            let source = MacElementSource()
            let roots = source.snapshot().map(\.root)
            guard let card = self.findElement(id: "Spec.Card", in: roots),
                  let cardText = self.findElement(id: "Spec.CardText", in: roots),
                  let section = self.findElement(id: "Spec.Section", in: roots),
                  let list = self.findFirst(in: roots, where: { $0.label == "Nav list" }) else {
                check8(false, "snapshot exposes Spec.Card/CardText/Section + the Nav list container")
                self.navController?.unmount()
                window.orderOut(nil)
                self.phase9Clamp()
                return
            }
            print("      fixture: card=\(fmt(card.frame)) cardText=\(fmt(cardText.frame)) " +
                  "section=\(fmt(section.frame)) list=\(self.label(list))")

            self.phase8aRoundTripUp(session: session, source: source, cardText: cardText)
            self.phase8bcdDescent(session: session, source: source, list: list)
            self.phase8eHover(session: session, cardText: cardText)
            self.phase8fAnchoring(session: session, card: card)

            // The hover re-check runs on a later turn ON PURPOSE: `hover` is
            // throttled to ~60fps, so a re-hover issued in this same runloop turn
            // would be dropped by the throttle and "still nil" would prove the
            // throttle, not the tool gate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.phase8eHoverRevived(session: session, cardText: cardText)
                self.navController?.unmount()
                window.orderOut(nil)
                self.phase9Clamp()
            }
        }
    }

    /// 8a — climbing N rungs and descending N returns to the ORIGINAL element.
    func phase8aRoundTripUp(session: AnnotationSession, source: MacElementSource, cardText: Element) {
        print("\n  8a — round trip UP: climb N, descend N, land on the original element:")
        let point = center(of: cardText.frame)
        let origin = session.select(atAXPoint: point)
        print("      click \(fmt(CGRect(origin: point, size: .zero))) -> \(self.label(origin))")
        check8(origin?.id == "Spec.CardText", "click selects #Spec.CardText (got \(self.label(origin)))")

        let climbed = climbToTop(session)
        let top = session.selected
        print("      climbed \(climbed) rung(s) -> \(self.label(top))")
        // Without this the round trip is vacuous: descending zero rungs trivially
        // "returns" to where it started. Two rungs, not one, so the descent has to
        // replay a sequence rather than a single undo.
        check8(climbed >= 2, "the click's ladder offered >=2 rungs to climb (got \(climbed) — a real multi-rung path)")
        check8(!same(top, origin), "climbing actually moved the binding off the original element")
        check8(!session.canSelectParent, "the climb stopped at the BROADEST rung (Select Parent is spent)")

        let descended = descend(session, climbed)
        print("      descended \(descended) rung(s) -> \(self.label(session.selected))")
        check8(descended == climbed, "descending walks back exactly as many rungs as were climbed")
        check8(same(session.selected, origin),
               "N up then N down returns to the ORIGINAL element (got \(self.label(session.selected)))")
    }

    /// 8b/8c/8d — descending BELOW the target: a real `ChildNavigationSource` query
    /// against the live tree, the history replay, and the `component` fix.
    ///
    /// Why this needs the Nav-list container rather than the Spec fixtures: every
    /// element in `ProbeSpecificityView` is an AX LEAF (the card and section are
    /// `children: .ignore` surfaces; the button and texts have no AX children), so
    /// a child query there can only ever return [] and every assertion built on it
    /// would pass while proving nothing. That is asserted below rather than assumed,
    /// so the day the fixture grows children this comment does not quietly rot.
    func phase8bcdDescent(session: AnnotationSession, source: MacElementSource, list: Element) {
        print("\n  8b/8c/8d — descend BELOW the target (live child query), history replay, component:")

        // The frame IS how this selection is made: the list container's AX frame is
        // the union of its rows (the documented `children: .contain` behaviour), so
        // there is no point inside it that hit-tests to the container itself. A
        // drawn frame binds to it by the marquee rule's largest-surrounded pass.
        let drawn = list.frame.insetBy(dx: -6, dy: -6)
        let target = session.select(inAXRect: drawn)
        print("      frame \(fmt(drawn)) -> \(self.label(target))")
        // Matched on label + frame, NOT on id, and that is not laziness: an unseeded
        // element's id is its slash-joined path, and the path is rooted differently
        // depending on which entry point produced the element — `snapshot()` roots
        // its trees at the window, while the hit-test / marquee / navigation paths
        // build the chain from the AXApplication. So the SAME live node is
        // `AXWindow[0]/AXGroup[0]/…` here and `AXApplication[0]/AXWindow[1]/…`
        // there. Pre-existing and orthogonal to this phase — but it is the concrete
        // reason a note's `component` must be an IDENTIFIER and never an id (8d).
        check8(target?.label == list.label && approxEqual(target?.frame ?? .zero, list.frame, tol: 0.5),
               "the drawn frame binds to the Nav list container (got \(self.label(target)))")
        check8((target?.path.last?.identifier ?? "").isEmpty,
               "the bound target is UNSEEDED (so `component` must come from a rung above it)")
        check8(target?.id.contains("/") == true,
               "the unseeded target's id IS a slash-joined path (got \(target?.id ?? "nil")) — the string that must never be exported as a grep target")

        let children = source.children(of: list, near: center(of: drawn))
        print("      live children(of: list) = \(children.isEmpty ? "[]" : children.map { self.label($0) }.joined(separator: "  |  "))")
        check8(!children.isEmpty, "the live tree really offers children under the bound target (the query is not returning [])")

        // 8b — descend below the target, then Parent returns to the target.
        let child = session.selectChild()
        print("      selectChild() -> \(self.label(child))")
        check8(child != nil, "selectChild() descends below the deepest known rung")
        check8(!same(child, target), "the descent landed on a DIFFERENT element than the target")
        check8(same(child, children.first),
               "the descent landed on the rule's most-likely child (got \(self.label(child)), rule ranked \(self.label(children.first)))")
        let backUp = session.selectParent()
        print("      selectParent() -> \(self.label(backUp))")
        check8(same(backUp, target), "Parent from the prepended child returns to the ORIGINAL target (round trip DOWN)")

        // 8c — history, not a re-query. `descend` measures the path's shape by
        // walking it: a second descent that RE-QUERIED would prepend a second rung,
        // so the number of rungs above the child would grow by one. That count is
        // the only externally visible witness of the prepend, which is why the
        // check is phrased as a depth comparison rather than "the ids match" alone.
        let secondChild = session.selectChild()
        print("      selectChild() again -> \(self.label(secondChild))")
        check8(same(secondChild, child), "the second descent lands on the SAME child (history, not a fresh heuristic)")
        let depthAfterFirst = climbToTop(session)
        descend(session, depthAfterFirst)
        let thirdChild = session.selected
        session.selectParent()
        let fourthChild = session.selectChild()
        let depthAfterThird = climbToTop(session)
        descend(session, depthAfterThird)
        print("      rungs above the child: after descent \(depthAfterFirst), after an up-down replay \(depthAfterThird)")
        check8(depthAfterFirst >= 2, "the descended path has >=2 rungs above the child (a real path to compare)")
        check8(same(thirdChild, child), "a full climb-and-return still lands on that same child")
        check8(same(fourthChild, child), "the replayed descent lands on that same child")
        check8(depthAfterThird == depthAfterFirst,
               "re-descending did NOT prepend another rung (\(depthAfterFirst) -> \(depthAfterThird)) — it replayed history rather than re-querying the live tree")

        // 8d — the component fix, against the live tree. The bound element is
        // unseeded, so `component` is searched UPWARD from the bound rung — and it
        // must be an identifier, never an unseeded element's slash-joined id, which
        // would export as a grep target that matches nothing while looking
        // perfectly plausible in the note.
        check8(same(session.selected, child), "still bound to the descended child going into the capture")
        check8((session.selected?.path.last?.identifier ?? "").isEmpty,
               "the descended child is itself UNSEEDED (so the note's component is not just its own id)")
        let note = session.addNote(comment: "phase 8 descended note")
        print("      note component=\(note?.component ?? "nil") unseeded=\(note?.unseeded.map(String.init) ?? "nil") selector=\(note?.selector ?? "nil")")
        check8(note != nil, "a note captured from the descended selection")
        check8(note?.component != nil, "the descended note names a component to grep")
        check8(note?.component?.contains("/") != true,
               "the component is NOT a slash-joined path (got \(note?.component ?? "nil")) — an unseeded id must never be exported as a grep target")
        check8(note?.component == "Nav.Section",
               "the component is the first SEEDED rung above the bound one (got \(note?.component ?? "nil"))")
    }

    /// 8e — frame mode makes hover inert, gated in the SESSION.
    func phase8eHover(session: AnnotationSession, cardText: Element) {
        print("\n  8e — hover is POINT-MODE ONLY (gated in the session, not the view):")
        let point = center(of: cardText.frame)
        session.setTool(.point)
        session.hover(atAXPoint: point)
        print("      point-mode hover at \(String(format: "(%.0f, %.0f)", point.x, point.y)) -> \(self.label(session.hovered))")
        // Non-vacuity: a point that hits nothing would leave `hovered` nil in BOTH
        // modes, and the frame-mode assertion below would prove nothing at all.
        check8(session.hovered?.id == "Spec.CardText",
               "sanity: this point DOES resolve to a real element in point mode (got \(self.label(session.hovered)))")

        session.setTool(.frame)
        check8(session.hovered == nil, "switching to frame mode drops the standing highlight")
        session.hover(atAXPoint: point)
        print("      frame-mode hover at the SAME live point -> \(self.label(session.hovered))")
        check8(session.hovered == nil, "hover() in frame mode is inert (no highlight, and no AX hit-test spent)")
    }

    /// 8e (continued, a later runloop turn) — and it comes back in point mode, so
    /// the gate is the TOOL and not a point that went dead.
    func phase8eHoverRevived(session: AnnotationSession, cardText: Element) {
        session.setTool(.point)
        session.hover(atAXPoint: center(of: cardText.frame))
        print("      back in point mode, same point -> \(self.label(session.hovered))")
        check8(session.hovered?.id == "Spec.CardText",
               "hover resolves again once the tool is point (the gate was the TOOL, not a dead point)")
    }

    /// 8f — the drawn frame is the anchor until the user navigates.
    func phase8fAnchoring(session: AnnotationSession, card: Element) {
        print("\n  8f — frame anchoring: the drawn rect anchors the overlay until Parent/Child is pressed:")
        let drawn = card.frame.insetBy(dx: -8, dy: -8)
        let target = session.select(inAXRect: drawn)
        print("      frame \(fmt(drawn)) -> \(self.label(target)) anchor=\(session.selectionAnchorFrame.map(fmt) ?? "nil")")
        check8(target?.id == "Spec.Card", "the drawn frame resolves to a real element (got \(self.label(target)))")
        // Non-vacuity: the anchor must differ from the resolved element's own frame,
        // or "anchors to the frame" and "anchors to the element" are the same claim.
        check8(!approxEqual(drawn, target?.frame ?? .zero, tol: 0.5),
               "sanity: the drawn frame is NOT the resolved element's own frame (8pt proud of it)")
        check8(session.selectionAnchorFrame.map { approxEqual($0, drawn, tol: 0.5) } ?? false,
               "selectionAnchorFrame IS the drawn rect (got \(session.selectionAnchorFrame.map(fmt) ?? "nil"))")

        let parent = session.selectParent()
        print("      selectParent() -> \(self.label(parent)) anchor=\(session.selectionAnchorFrame.map(fmt) ?? "nil") " +
              "marquee=\(session.selectedMarqueeRect.map(fmt) ?? "nil")")
        check8(parent != nil, "sanity: the framed selection really had a parent rung to navigate to")
        check8(session.selectionAnchorFrame == nil,
               "navigating drops the frame anchor, revealing the bound element (got \(session.selectionAnchorFrame.map(fmt) ?? "nil"))")
        check8(session.selectedMarqueeRect.map { approxEqual($0, drawn, tol: 0.5) } ?? false,
               "the drawn rect SURVIVES navigation (it is still what the note records)")

        verifyCapturedRects(session: session, drawn: drawn, boundAfterNavigation: parent)
    }

    /// 8g — the RECALLED-MARK record (VRT-pm3k.5): a captured note remembers the
    /// rect it was made on, in the two cases a POINT could never describe.
    ///
    /// The framed-then-navigated note is the whole reason the rects are stored
    /// rather than derived. Pressing Parent moves the note's binding onto the
    /// element while the drawn size stays the swept one, so `anchor + regionRect
    /// .size` — the only derivation available — yields a right-sized box in the
    /// wrong place. Here the two rects simply disagree, which is the answer.
    func verifyCapturedRects(session: AnnotationSession, drawn: CGRect, boundAfterNavigation: Element?) {
        print("\n  8g — a captured note remembers its RECT (anchorRect / drawnRect):")
        let axOrigin = ScreenSpace.windowAXOrigin(
            cocoaFrame: navHost?.frame ?? .zero,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0
        )
        func windowLocal(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -axOrigin.x, dy: -axOrigin.y) }

        // The selection is still the navigated one left by 8f.
        guard let bound = boundAfterNavigation,
              let navigated = session.addNote(comment: "framed then navigated", axOrigin: axOrigin) else {
            check8(false, "a note could be captured on the framed-then-navigated selection")
            session.cancelSelection()
            return
        }
        print("      navigated note: anchorRect=\(navigated.anchorRect.map(fmt) ?? "nil") " +
              "drawnRect=\(navigated.drawnRect.map(fmt) ?? "nil") bound element=\(fmt(bound.frame))")
        check8(navigated.anchorRect.map { approxEqual($0, windowLocal(bound.frame), tol: 0.5) } ?? false,
               "the navigated note's anchorRect is the ELEMENT it is filed against (window-local)")
        check8(navigated.drawnRect.map { approxEqual($0, windowLocal(drawn), tol: 0.5) } ?? false,
               "...and its drawnRect is still the rectangle the user SWEPT")
        check8(navigated.anchorRect != navigated.drawnRect,
               "the two rects DISAGREE here — the one case where the note's binding and the user's gesture differ")

        // And the ordinary framed note: draw the same rect again, file it without
        // navigating. Its two rects AGREE, which is exactly how a recalled mark
        // recognizes an area note and draws the swept box with no name tag.
        session.select(inAXRect: drawn)
        guard let framed = session.addNote(comment: "framed", axOrigin: axOrigin) else {
            check8(false, "a note could be captured on a plain framed selection")
            session.cancelSelection()
            return
        }
        print("      framed note:    anchorRect=\(framed.anchorRect.map(fmt) ?? "nil") " +
              "drawnRect=\(framed.drawnRect.map(fmt) ?? "nil")")
        check8(framed.anchorRect == framed.drawnRect && framed.drawnRect != nil,
               "an un-navigated framed note's two rects AGREE (that IS the area-note test)")
        check8(framed.drawnRect.map { approxEqual($0, windowLocal(drawn), tol: 0.5) } ?? false,
               "...and they are the swept rectangle, window-local")
        session.cancelSelection()
    }

    /// First element matching `predicate`, depth-first.
    func findFirst(in elements: [Element], where predicate: (Element) -> Bool) -> Element? {
        for element in elements {
            if predicate(element) { return element }
            if let found = findFirst(in: element.children, where: predicate) { return found }
        }
        return nil
    }

    /// Every non-empty AX identifier in `element`'s subtree, including its own —
    /// the set of ids a walk that strayed into the overlay would surface.
    func axCollectIDs(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 32 else { return [] }
        var out: [String] = []
        let id = AX.string(element, kAXIdentifierAttribute)
        if !id.isEmpty { out.append(id) }
        for child in AX.children(element) {
            out.append(contentsOf: axCollectIDs(in: child, depth: depth + 1))
        }
        return out
    }

    /// Recursive raw-AX search for elements matching one of `subroles`.
    func axFindAll(in element: AXUIElement, subroles: Set<String>, depth: Int) -> [AXUIElement] {
        guard depth < 12 else { return [] }
        var out: [AXUIElement] = []
        if subroles.contains(AX.string(element, kAXSubroleAttribute)) { out.append(element) }
        for child in AX.children(element) {
            out.append(contentsOf: axFindAll(in: child, subroles: subroles, depth: depth + 1))
        }
        return out
    }

    /// Depth-first search of the public snapshot tree by element id.
    func findElement(id: String, in elements: [Element]) -> Element? {
        for element in elements {
            if element.id == id { return element }
            if let found = findElement(id: id, in: element.children) { return found }
        }
        return nil
    }

    // ---- Phase 9: a host that hangs off the visible screen ------------------
    // The dogfooding report: "on scrollable screens, the menu in the bottom right
    // disappears." A tall/scrollable host is a window taller than the display, and
    // AppKit constrains a window's TOP under the menu bar but never lifts its bottom —
    // so its bottom edge ends up below `visibleFrame`. BOTH overlay modes anchor the
    // pill to that bottom edge (idle: a 240x104 panel at the host's bottom-right corner;
    // annotate: the pill drawn at the bottom-right INSIDE a full-host-frame panel), so
    // the toolbar is drawn under the Dock or off the display entirely and there is no
    // way to reach it. Every sub-phase here first PROVES the host really extends past
    // the visible area, or it would be asserting nothing.
    var clampController: OverlayController?
    var clampSession: AnnotationSession?
    var clampHost: ClampedHost?
    var passClamp = true
    func check9(_ cond: Bool, _ msg: String) {
        passClamp = passClamp && cond
        print("      " + (cond ? "ok   " : "FAIL ") + msg)
    }

    /// The display the clamp is measured against. `NSScreen.main` is the screen the
    /// probe's own windows land on, which is what `host.screen` will report back.
    var visibleFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// How far the fixtures hang past the visible edge. Large enough that a stale,
    /// unclamped placement is unambiguously off-screen rather than a rounding artifact.
    let overhang: CGFloat = 300

    func phase9Clamp() {
        print("\n--- Phase 9: the pill on a host that hangs BELOW the visible screen (scrollable-window report) ---")
        let visible = visibleFrame
        // Top pinned to the visible top (so AppKit does not fight the placement) and
        // TALLER than the visible height by `overhang` — exactly the shape a window
        // takes when its content grows past the display.
        let frame = NSRect(x: visible.midX - 310, y: visible.minY - overhang,
                           width: 620, height: visible.height + overhang)
        let host = makeClampedHost(title: "AnnotKit Harness W9 (below the fold)",
                                   frame: frame, unconstrained: false,
                                   visibleBand: visible.intersection(frame))
        clampHost = host

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-clamp.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: host.window)
        clampController = controller
        clampSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.phase9aIdle()
        }
    }

    /// The precondition every assertion in this phase rests on: the host really does
    /// extend past the bottom of the visible area. Printed with the numbers so a run on
    /// a different display arrangement is diagnosable.
    @discardableResult
    func assertHangsBelow(_ host: NSWindow) -> Bool {
        let visible = visibleFrame
        let hangs = host.frame.minY < visible.minY - 100
        print("      host=\(fmt(host.frame)) visibleFrame=\(fmt(visible)) " +
              "bottom hangs \(String(format: "%.0f", visible.minY - host.frame.minY))pt BELOW the visible area")
        check9(hangs, "sanity: the host really extends past the bottom of the visible screen (else this phase is vacuous)")
        return hangs
    }

    // ---- 9a: the IDLE pill stays on the visible screen ----------------------
    func phase9aIdle() {
        print("\n  9a — IDLE pill on a host whose bottom is below the visible area:")
        guard let host = clampHost, let panel = overlayCatcher(of: host.window) else {
            check9(false, "the overlay mounted a child panel on the clamped host")
            return phase9dTucked()
        }
        assertHangsBelow(host.window)

        let visible = visibleFrame
        // The UNCLAMPED placement: the same panel anchored to the HOST's own
        // bottom-right corner, which is the corner hanging below the screen.
        let unclamped = CGRect(origin: CGPoint(x: host.window.frame.maxX - panel.frame.width,
                                               y: host.window.frame.minY),
                               size: panel.frame.size)
        print("      idle panel=\(fmt(panel.frame)) pill=\(fmt(pillRect(inPanel: panel.frame))) " +
              "(unclamped placement would be \(fmt(unclamped)), pill \(fmt(pillRect(inPanel: unclamped))))")
        check9(!visible.contains(pillRect(inPanel: unclamped)),
               "sanity: the UNCLAMPED bottom-right placement really is off the visible screen (the reported bug)")
        check9(visible.contains(pillRect(inPanel: panel.frame)),
               "the idle pill is fully inside the visible screen")
        // Size, not just position: clamping by intersecting the panel down to the
        // visible region would leave the pill's own panel too short to draw it.
        // SNUG, not full-size: the panel covers the control and its chrome and no
        // more, because every pixel it covers is a pixel of the host app that cannot
        // be clicked. An IDLE pill is one pencil, so this is the smallest it ever is.
        check9(panel.frame.width < OverlayPlacementSeedSize.width / 2
               && panel.frame.height < OverlayPlacementSeedSize.height,
               "the idle panel is sized to the PILL, not to the old fixed corner (got \(fmt(panel.frame)))")
        check9(panel.frame.contains(pillRect(inPanel: panel.frame)),
               "and the pill still fits inside it (a panel sized too small would clip the control)")
        // Hit-testability, the property the user actually lost: AppKit's own
        // "which window would a click here land on" answer must be OUR panel.
        //
        // Ask only about THIS PROCESS's windows. `windowNumber(at:)` answers globally,
        // so any unrelated app that happens to cover the point — a full-screen
        // terminal running the probe, most obviously — makes the assertion fail for a
        // reason that has nothing to do with AnnotKit. Walking our own window list
        // front-to-back keeps the check about the panel-vs-host layering it is
        // actually testing, and keeps the probe from flaking on whatever is frontmost.
        let pillCenter = center(of: pillRect(inPanel: panel.frame))
        let ownNumbers = Set(NSApp.windows.map(\.windowNumber))
        var hitNumber = NSWindow.windowNumber(at: pillCenter, belowWindowWithWindowNumber: 0)
        while hitNumber != 0, !ownNumbers.contains(hitNumber) {
            hitNumber = NSWindow.windowNumber(at: pillCenter, belowWindowWithWindowNumber: hitNumber)
        }
        print("      windowNumber(at: pill center \(String(format: "(%.0f, %.0f)", pillCenter.x, pillCenter.y)))=\(hitNumber) " +
              "panel=\(panel.windowNumber) host=\(host.window.windowNumber)")
        check9(hitNumber == panel.windowNumber, "a click at the pill's center lands on the overlay panel (it is hit-testable)")

        clampController?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.phase9bAnnotate()
        }
    }

    // ---- 9b: the ANNOTATE pill stays on screen AND the hit-test stays true ---
    func phase9bAnnotate() {
        print("\n  9b — ANNOTATE pill + hit-test on the same clamped host:")
        guard let host = clampHost, let controller = clampController,
              let panel = overlayCatcher(of: host.window) else {
            check9(false, "the overlay is still mounted in annotate mode")
            return phase9dTucked()
        }
        let visible = visibleFrame
        assertHangsBelow(host.window)
        print("      annotate panel=\(fmt(panel.frame)) pill=\(fmt(pillRect(inPanel: panel.frame))) " +
              "(unclamped would be the host frame, pill \(fmt(pillRect(inPanel: host.window.frame))))")
        check9(!visible.contains(pillRect(inPanel: host.window.frame)),
               "sanity: the pill drawn at the bottom-right of the FULL host frame is off the visible screen")
        check9(visible.contains(pillRect(inPanel: panel.frame)),
               "the annotate pill is fully inside the visible screen")

        // The part that would make a naive fix worse than the bug: the surface the
        // overlay transforms clicks through must be the surface it is now DRAWN on.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let panelAXOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: panel.frame, primaryHeight: primaryHeight)
        guard let axOrigin = overlayValue(controller, "axOrigin", as: CGPoint.self),
              let surfaceSize = overlayValue(controller, "surfaceSize", as: CGSize.self) else {
            check9(false, "the controller still has axOrigin/surfaceSize to read (this phase asserts nothing otherwise)")
            return phase9cScroll()
        }
        print("      axOrigin=\(String(format: "(%.1f, %.1f)", axOrigin.x, axOrigin.y)) " +
              "panel-derived=\(String(format: "(%.1f, %.1f)", panelAXOrigin.x, panelAXOrigin.y)) " +
              "surfaceSize=\(String(format: "%.0fx%.0f", surfaceSize.width, surfaceSize.height)) " +
              "panel=\(String(format: "%.0fx%.0f", panel.frame.width, panel.frame.height)) " +
              "host=\(String(format: "%.0fx%.0f", host.window.frame.width, host.window.frame.height))")
        check9(approxEqualPt(axOrigin, panelAXOrigin), "axOrigin is derived from the CLAMPED panel frame")
        check9(abs(surfaceSize.height - panel.frame.height) < 2,
               "surfaceSize is the CLAMPED panel's size (the composer clamps cards to the VISIBLE region)")
        check9(surfaceSize.height < host.window.frame.height - 100,
               "the clamped surface is materially shorter than the host (the clip is real, not a no-op)")

        // And now the click itself, along the real path: SwiftUI hands the catcher a
        // PANEL-local point, the catcher ADDS axOrigin, the source resolves that.
        let source = MacElementSource()
        guard let buttonFrame = frame(ofID: "Clamp.Button", in: source.snapshot()) else {
            check9(false, "the host's button is in the AX tree (needed to test the click through the clamped panel)")
            return phase9cScroll()
        }
        let buttonAXCenter = center(of: buttonFrame)
        let local = CGPoint(x: buttonAXCenter.x - panelAXOrigin.x, y: buttonAXCenter.y - panelAXOrigin.y)
        let queried = CGPoint(x: local.x + axOrigin.x, y: local.y + axOrigin.y)
        let hit = source.hitTest(queried)
        print("      button AX \(fmt(buttonFrame)) -> panel-local \(String(format: "(%.0f, %.0f)", local.x, local.y)) " +
              "-> catcher queries \(String(format: "(%.0f, %.0f)", queried.x, queried.y)) -> hit=\(hit?.id ?? "nil")")
        check9(panel.frame.contains(CGPoint(x: buttonAXCenter.x, y: primaryHeight - buttonAXCenter.y)),
               "sanity: the button really is under the clamped panel (a click on it goes through the catcher)")
        check9(hit?.id == "Clamp.Button",
               "a click on the clamped host still resolves to the element under it (got \(hit?.id ?? "nil"))")

        phase9cScroll()
    }

    // ---- 9c: can the host be scrolled AT ALL while annotating? --------------
    // The other half of the report: the expanded catcher covers the host with
    // `ignoresMouseEvents = false`, and an event no view handles walks the PANEL's own
    // responder chain, never the window beneath. If the wheel dies there, nothing below
    // the fold can be annotated — on precisely the screens the report is about.
    func phase9cScroll() {
        print("\n  9c — scroll WHILE ANNOTATING: does a wheel over the catcher reach the host?")
        guard let host = clampHost, let panel = overlayCatcher(of: host.window) else {
            check9(false, "the overlay panel is present for the scroll measurement")
            return phase9dTucked()
        }
        // Aim at the vertical middle of the VISIBLE band. Chosen so the correct
        // (converted) host-local point lands in the UPPER spy while the unconverted
        // panel-local point would land in the LOWER one — the two answers are
        // distinguishable, so this measures the conversion and not just the routing.
        let visible = visibleFrame
        let aimScreen = CGPoint(x: panel.frame.midX, y: visible.midY)
        let panelLocal = CGPoint(x: aimScreen.x - panel.frame.minX, y: aimScreen.y - panel.frame.minY)
        let hostLocal = CGPoint(x: aimScreen.x - host.window.frame.minX, y: aimScreen.y - host.window.frame.minY)
        let split = (host.window.contentView?.bounds.height ?? 0) / 2
        print("      aim screen=\(String(format: "(%.0f, %.0f)", aimScreen.x, aimScreen.y)) " +
              "panel-local=\(String(format: "(%.0f, %.0f)", panelLocal.x, panelLocal.y)) " +
              "host-local=\(String(format: "(%.0f, %.0f)", hostLocal.x, hostLocal.y)) spy split at y=\(String(format: "%.0f", split))")
        check9(panel.frame.contains(aimScreen), "sanity: the annotate catcher really covers the point being scrolled")
        check9((hostLocal.y > split) != (panelLocal.y > split),
               "sanity: converted and unconverted points land in DIFFERENT spies (so the target proves the conversion)")

        guard let event = makeScrollEvent(panelLocal: panelLocal) else {
            check9(false, "a synthesized wheel event could be built")
            return phase9dTucked()
        }
        check9(approxEqualPt(event.locationInWindow, panelLocal),
               "sanity: the synthesized event carries the panel-local location a real wheel would")

        // The panel drives the enclosing scroller's CLIP directly — the event object
        // never enters the host's view tree (a phase `began` would otherwise engage
        // NSScrollView's event tracking against the PANEL window and wedge it; that
        // was the vanishing-toolbar bug). Offset movement is therefore observable
        // even for a synthesized event, which the old event-delivery path ignored.
        let upperBefore = host.upperScroll.contentView.bounds.origin.y
        let lowerBefore = host.lowerScroll.contentView.bounds.origin.y
        panel.scrollWheel(with: event)
        let upperMoved = abs(host.upperScroll.contentView.bounds.origin.y - upperBefore)
        let lowerMoved = abs(host.lowerScroll.contentView.bounds.origin.y - lowerBefore)
        print("      after the wheel: upper clip moved \(String(format: "%.1f", upperMoved))pt, lower \(String(format: "%.1f", lowerMoved))pt")
        check9(upperMoved > 0, "a wheel over the annotate catcher SCROLLS the host (it is not swallowed by the panel)")
        check9(lowerMoved == 0, "and it scrolls the pane actually under the pointer (the panel→host conversion is applied)")

        // The trackpad case that used to KILL the overlay: a phase-tagged event. It
        // must scroll like any other — and, mechanically, must never reach the host's
        // own scrollWheel, which is what the direct-clip design guarantees.
        if let phased = makeScrollEvent(panelLocal: panelLocal, phase: 1) {
            let before = host.upperScroll.contentView.bounds.origin.y
            panel.scrollWheel(with: phased)
            check9(abs(host.upperScroll.contentView.bounds.origin.y - before) > 0,
                   "a PHASE-tagged (trackpad) wheel scrolls too — the stream that wedged the old event-forwarding design")
        } else {
            check9(false, "a phase-tagged wheel event could be built")
        }

        phase9cMarksFollowContent(host: host, panel: panel, panelLocal: panelLocal)

        clampController?.unmount()
        clampHost?.window.orderOut(nil)
        phase9dTucked()
    }

    /// The other half of owning the wheel: because the panel applies the scroll
    /// itself, it knows the exact translation and can move the notes with it.
    ///
    /// Measured against the CONTENT, not against the deltas: the assertion is that
    /// the note's stored rect and the control it was made on moved by the SAME
    /// amount, which is the only form of the claim that means anything. Drawing a
    /// recalled mark over unrelated content is the most misleading possible reply to
    /// the one question the mark exists to answer, so wrong-and-confident is the
    /// only outcome here worse than the status quo.
    func phase9cMarksFollowContent(host: ClampedHost, panel: NSWindow, panelLocal: CGPoint) {
        print("\n  9c(ii) — a captured note's geometry follows the content the panel scrolls:")
        guard let session = clampSession else {
            check9(false, "the clamped session is available to capture a note on scrolled content")
            return
        }
        let axOrigin = ScreenSpace.windowAXOrigin(
            cocoaFrame: panel.frame,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0
        )
        let markerBefore = axCenter(of: host.upperMarker)
        session.select(atAXPoint: markerBefore)
        guard let note = session.addNote(comment: "note on scrolled content", axOrigin: axOrigin),
              let anchorBefore = note.anchorRect else {
            check9(false, "a note could be captured on the control INSIDE the scroller")
            return
        }
        print("      captured on \(note.selector): anchorRect=\(fmt(anchorBefore)) " +
              "marker AX centre=\(String(format: "(%.0f, %.0f)", markerBefore.x, markerBefore.y))")
        check9(note.selector.contains("Clamp.UpperMarker"),
               "sanity: the note really bound to the control inside the scroller (got \(note.selector))")

        guard let event = makeScrollEvent(panelLocal: panelLocal) else {
            check9(false, "a wheel event could be built for the mark-tracking measurement")
            return
        }
        panel.scrollWheel(with: event)

        let markerAfter = axCenter(of: host.upperMarker)
        let contentDY = markerAfter.y - markerBefore.y
        guard let anchorAfter = session.pending.first(where: { $0.id == note.id })?.anchorRect else {
            check9(false, "the note is still in the retained set after the scroll")
            return
        }
        let markDY = anchorAfter.minY - anchorBefore.minY
        print("      after the wheel: content moved \(String(format: "%+.1f", contentDY))pt, " +
              "the note's rect moved \(String(format: "%+.1f", markDY))pt (anchorRect=\(fmt(anchorAfter)))")
        // Without this the whole measurement is vacuous: two things that did not
        // move also "moved by the same amount".
        check9(abs(contentDY) > 1, "sanity: the wheel really moved the annotated control (\(String(format: "%.1f", contentDY))pt)")
        check9(abs(markDY - contentDY) < 1,
               "the note's stored rect moved by EXACTLY the translation applied to the content — the mark stays on what it describes")
        check9(abs(anchorAfter.minX - anchorBefore.minX) < 1 && anchorAfter.size == anchorBefore.size,
               "a vertical scroll moves the rect vertically and only vertically (size and x untouched)")
        session.deleteNote(id: note.id)

        phase9cSelectionFollowsContent(host: host, panel: panel, panelLocal: panelLocal)
    }

    /// The LIVE drawn frame — the one on screen right now, with a composer open and
    /// an element named in its header — has to track the content as well.
    ///
    /// This is the half that was missing, and the more visible of the two: a
    /// recalled mark is asked for deliberately and one at a time, whereas the live
    /// frame is up continuously. Reproduced before the fix: a frame drawn around row
    /// 3 held its window position across a 360pt scroll and ended up drawn around
    /// row 8 while the composer still named row 3.
    func phase9cSelectionFollowsContent(host: ClampedHost, panel: NSWindow, panelLocal: CGPoint) {
        print("\n  9c(iii) — the LIVE drawn frame follows the content it was drawn around:")
        guard let session = clampSession else {
            check9(false, "the clamped session is available for the live-selection measurement")
            return
        }
        let markerRect = axRect(ofCocoa: host.upperMarker.window!.convertToScreen(
            host.upperMarker.convert(host.upperMarker.bounds, to: nil)))
        let markerBefore = axCenter(of: host.upperMarker)
        session.setTool(.frame)
        let target = session.select(inAXRect: markerRect.insetBy(dx: -8, dy: -6))
        guard let anchorBefore = session.selectionAnchorFrame else {
            check9(false, "a frame drawn around the control inside the scroller anchors to what was drawn (got \(self.label(target)))")
            session.cancelSelection()
            session.setTool(.point)
            return
        }
        print("      drew \(fmt(anchorBefore)) around \(self.label(target))")

        guard let event = makeScrollEvent(panelLocal: panelLocal) else {
            check9(false, "a wheel event could be built for the live-selection measurement")
            session.cancelSelection(); session.setTool(.point); return
        }
        panel.scrollWheel(with: event)

        let contentDY = axCenter(of: host.upperMarker).y - markerBefore.y
        guard let anchorAfter = session.selectionAnchorFrame else {
            check9(false, "the frame selection SURVIVES the scroll (it must not be dropped)")
            session.cancelSelection(); session.setTool(.point); return
        }
        let frameDY = anchorAfter.minY - anchorBefore.minY
        print("      after the wheel: content moved \(String(format: "%+.1f", contentDY))pt, " +
              "the drawn frame moved \(String(format: "%+.1f", frameDY))pt")
        check9(abs(contentDY) > 1, "sanity: the wheel really moved the framed control (\(String(format: "%.1f", contentDY))pt)")
        check9(abs(frameDY - contentDY) < 1,
               "the live drawn frame moved by EXACTLY the translation applied to the content — it never ends up around something else")
        check9(session.selected?.id == target?.id,
               "the selection is the SAME element after the scroll (it moved; it did not become a different one)")
        session.cancelSelection()
        session.setTool(.point)
    }

    // ---- 9d: the OTHER clamp direction — a host tucked under the menu bar ----
    // Clamping the bottom leaves `axOrigin` untouched (it hangs off the frame's TOP
    // edge), so 9b cannot tell a fix that re-derives the origin from one that forgot to.
    // A host whose TOP is clipped can: there the origin really moves, and a host-derived
    // origin offsets every click by exactly the clipped amount.
    func phase9dTucked() {
        print("\n  9d — the other direction: a host whose TOP is tucked under the menu bar:")
        let visible = visibleFrame
        let frame = NSRect(x: visible.midX - 310, y: visible.minY + 80,
                           width: 620, height: visible.height - 80 + overhang)
        let host = makeClampedHost(title: "AnnotKit Harness W9 (under the menu bar)",
                                   frame: frame, unconstrained: true,
                                   visibleBand: visible.intersection(frame))
        clampHost = host

        let session = AnnotationSession(
            source: MacElementSource(),
            sink: NotesFileSink(path: NSTemporaryDirectory() + "annotkit-clamp-top.md")
        )
        let controller = OverlayController(session: session)
        controller.mount(on: host.window)
        controller.start()
        clampController = controller
        clampSession = session

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.phase9dChecks()
        }
    }

    func phase9dChecks() {
        guard let host = clampHost, let controller = clampController,
              let panel = overlayCatcher(of: host.window) else {
            check9(false, "the overlay mounted on the menu-bar-tucked host")
            return finish()
        }
        let visible = visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        print("      host=\(fmt(host.window.frame)) visibleFrame=\(fmt(visible)) " +
              "top is \(String(format: "%.0f", host.window.frame.maxY - visible.maxY))pt ABOVE the visible top")
        check9(host.window.frame.maxY > visible.maxY + 50,
               "sanity: the host's top really is under the menu bar (else the origin never moves and this proves nothing)")

        let hostAXOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: host.window.frame, primaryHeight: primaryHeight)
        let panelAXOrigin = ScreenSpace.windowAXOrigin(cocoaFrame: panel.frame, primaryHeight: primaryHeight)
        guard let axOrigin = overlayValue(controller, "axOrigin", as: CGPoint.self) else {
            check9(false, "the controller still has an axOrigin to read")
            return finish()
        }
        print("      panel=\(fmt(panel.frame)) axOrigin=\(String(format: "(%.1f, %.1f)", axOrigin.x, axOrigin.y)) " +
              "panel-derived=\(String(format: "(%.1f, %.1f)", panelAXOrigin.x, panelAXOrigin.y)) " +
              "host-derived=\(String(format: "(%.1f, %.1f)", hostAXOrigin.x, hostAXOrigin.y))")
        check9(!approxEqualPt(panelAXOrigin, hostAXOrigin),
               "sanity: clamping the TOP really does move the AX origin (the two candidates differ)")
        check9(approxEqualPt(axOrigin, panelAXOrigin),
               "axOrigin follows the CLAMPED panel, not the host (a host-derived origin offsets every click here)")

        let source = MacElementSource()
        guard let buttonFrame = frame(ofID: "Clamp.Button", in: source.snapshot()) else {
            check9(false, "the tucked host's button is in the AX tree")
            return finish()
        }
        let buttonAXCenter = center(of: buttonFrame)
        let local = CGPoint(x: buttonAXCenter.x - panelAXOrigin.x, y: buttonAXCenter.y - panelAXOrigin.y)
        let queried = CGPoint(x: local.x + axOrigin.x, y: local.y + axOrigin.y)
        let hit = source.hitTest(queried)
        // What the SAME click would resolve to if the origin had stayed host-derived:
        // named explicitly so the failure mode has a number next to it, not a shrug.
        let stale = CGPoint(x: local.x + hostAXOrigin.x, y: local.y + hostAXOrigin.y)
        print("      button AX \(fmt(buttonFrame)) -> panel-local \(String(format: "(%.0f, %.0f)", local.x, local.y)) " +
              "-> queries \(String(format: "(%.0f, %.0f)", queried.x, queried.y)) hit=\(hit?.id ?? "nil"); " +
              "a host-derived origin would query \(String(format: "(%.0f, %.0f)", stale.x, stale.y)) " +
              "-> \(source.hitTest(stale)?.id ?? "nil")")
        check9(hit?.id == "Clamp.Button",
               "a click on the menu-bar-tucked host still resolves to the element under it (got \(hit?.id ?? "nil"))")

        clampController?.unmount()
        clampHost?.window.orderOut(nil)
        phase10Escape()
    }

    // ---- Phase 10: Escape closes the menu -----------------------------------
    // The one claim no unit test can make. A local key monitor is invoked by
    // NSApplication's event DISPATCH, so it needs a real app with a running
    // runloop — `NSApp.postEvent` puts a real key-down into that queue, which is
    // as close to a keypress as a process can get to itself.
    var passEscape = true
    func check10(_ c: Bool, _ m: String) {
        print("      " + (c ? "ok   " : "FAIL ") + m)
        passEscape = passEscape && c
    }

    func escapeEvent() -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                         context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)
    }

    func phase10Escape() {
        print("\n--- Phase 10: Escape closes the menu ---")
        let host = makeHostWindow(title: "AnnotKit Escape W1")
        let controller = OverlayController(session: AnnotationSession(
            source: MacElementSource(), sink: NotesFileSink(path: "/dev/null")
        ))
        controller.mount(on: host.window)
        controller.start()
        check10(controller.session.mode == .annotating, "sanity: the menu is OPEN before the keypress")

        guard let event = escapeEvent() else {
            check10(false, "a real Escape key-down could be built")
            controller.unmount(); host.window.orderOut(nil); return finish()
        }
        NSApp.postEvent(event, atStart: true)
        // Dispatch happens on the runloop, not inline: let it turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let mode = controller.session.mode
            print("      after posting Escape: mode=\(mode)")
            self.check10(mode == .idle, "Escape closed the menu (annotate mode exited)")
            controller.unmount()
            host.window.orderOut(nil)
            self.phase11Marks()
        }
    }

    // ---- Phase 11: the two selections stop fighting, and a mark comes back --
    // Three questions the epic could not settle by inspection:
    //
    //  (d) does the permanently-mounted 240x104 toolbar panel — `ignoresMouseEvents
    //      = false`, ordered ABOVE the catcher, sitting in the exact corner a user
    //      drags a frame into — swallow presses in its TRANSPARENT region? Per-pixel
    //      alpha pass-through SHOULD save it, and that had never been asserted.
    //  (a) do PINS swallow the press? Every capture plants one where the next frame
    //      is most likely to be drawn, and the fix (inert in frame mode) is only
    //      believable if the two modes are shown to differ.
    //      Element and area notes coexisting, and each recalling its own kind of
    //      mark, is the other half of the same report.
    var passMarks = true
    func check11(_ c: Bool, _ m: String) {
        print("      " + (c ? "ok   " : "FAIL ") + m)
        passMarks = passMarks && c
    }

    var marksController: OverlayController?
    var marksHost: HostControls?

    func phase11Marks() {
        print("\n--- Phase 11: element + area notes coexist; a hover recalls ONE mark; pins are inert in frame mode ---")
        // ON SCREEN, unlike the other model phases: 11a asks the WINDOW SERVER which
        // window a click at a point would hit, and a window parked at (-12000,-12000)
        // is not in any answer it can give.
        let host = makeHostWindow(title: "AnnotKit Harness W11 (marks)")
        if realClicks {
            // 11a asks the window server a question, so its fixture has to be on a
            // real screen. Every other leg here drives the session or sends events
            // straight to a panel, so by default this stays off-screen like the rest
            // of the harness and disturbs nothing.
            host.window.setFrameOrigin(NSPoint(x: visibleFrame.minX + 120, y: visibleFrame.minY + 200))
            NSApp.activate(ignoringOtherApps: true)
        }
        host.window.makeKeyAndOrderFront(nil)
        marksHost = host

        let session = AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        let controller = OverlayController(session: session)
        controller.mount(on: host.window)
        controller.start()
        marksController = controller

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let notes = self.phase11bBothKindsCoexist(session: session, host: host)
            // Everything below drives the REAL view tree, so each step has to be
            // given a runloop turn to render into. A press sent in the same turn as
            // the `setTool` that is supposed to change its outcome would land on the
            // PREVIOUS layout and prove nothing — which is exactly how this phase
            // first reported the fix as broken when it was the harness that was.
            self.runSteps([
                { self.phase11cPress(session: session, host: host.window, notes: notes, tool: .point) },
                { self.phase11cPress(session: session, host: host.window, notes: notes, tool: .frame) },
                // The control click FIRST: a real click on the catcher, far from the
                // toolbar, must produce a selection. Without it, "the gap click
                // produced nothing" is equally consistent with no click having been
                // delivered at all.
                { self.phase11aArmClick(session: session, host: host.window, leg: .control) },
                { self.phase11aReadClick(session: session) },
                { self.phase11aArmClick(session: session, host: host.window, leg: .reclaimed) },
                { self.phase11aReadClick(session: session) },
                { self.phase11aArmClick(session: session, host: host.window, leg: .chrome) },
                { self.phase11aReadClick(session: session) },
                {
                    self.phase11dRecall(session: session, notes: notes)
                    controller.unmount()
                    host.window.orderOut(nil)
                    self.phase12FirstClick()
                }
            ])
        }
    }

    /// Run each step on its own runloop turn, with a beat in between for SwiftUI to
    /// lay out and for posted events to be delivered.
    func runSteps(_ steps: [() -> Void], delay: TimeInterval = 0.45) {
        guard let first = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            first()
            self?.runSteps(Array(steps.dropFirst()), delay: delay)
        }
    }

    /// Candidate (d), settled with a REAL CLICK.
    ///
    /// Every cheaper instrument was tried and each measures the wrong thing:
    /// `NSWindow.windowNumber(at:)` is RECT-based (measured: a panel containing a
    /// bare, empty `NSView` that draws nothing still answers "me"), and
    /// `NSHostingView.hitTest` returns the hosting view for EVERY point in its
    /// bounds, pill or gap. Neither can see the only thing that decides this — the
    /// window server's per-pixel test on a non-opaque window, which happens before
    /// AppKit is involved at all.
    ///
    /// So the probe asks the question the user asks: it posts a genuine click into
    /// the toolbar panel's empty region and looks at whether the CATCHER acted on
    /// it. Point mode, so a click that lands resolves to a selection — an
    /// unambiguous, observable effect, and nil if the toolbar swallowed it.
    ///
    /// THE ANSWER IS NO, and this phase now PINS THAT rather than wishing for it.
    /// Per-pixel alpha pass-through is a myth for mouse events: measured against a
    /// panel whose content view was a bare `NSView` drawing nothing at all, with
    /// `isOpaque = false` and a clear background, the click was still swallowed.
    /// `ignoresMouseEvents = true` was the ONLY configuration that let it through,
    /// and that would take the pill's own clicks with it. So the toolbar panel
    /// claims its whole 240x104 rect, permanently, in both modes.
    ///
    /// Recorded as a known limitation (DECISIONS.md) rather than fixed here: the
    /// remedy is to size the panel to the pill, which is a change to the design
    /// `be624b4` deliberately landed, and this epic's job was to SETTLE the
    /// question. IF THIS CHECK EVER FAILS, the limitation has been fixed — invert
    /// it and delete the DECISIONS.md entry.
    enum ClickLeg { case control, reclaimed, chrome }

    func phase11aArmClick(session: AnnotationSession, host: NSWindow, leg: ClickLeg) {
        let throughToolbar = leg != .control
        if leg == .control { print("\n  11a — the toolbar panel covers the PILL now, not a fixed 240x104 corner:") }
        guard let toolbar = overlayToolbar(of: host), let catcher = overlayCatcher(of: host), toolbar !== catcher else {
            check11(false, "both overlay panels are present (toolbar + catcher)")
            return
        }
        let pill = pillRect(inPanel: toolbar.frame)
        // The panel is 240x104; the pill is ~180x44 in its bottom-right corner. The
        // difference is real estate the panel covers permanently and draws nothing
        // in — and it is precisely the corner a user drags a frame into.
        let inGap = CGPoint(x: toolbar.frame.minX + 8, y: toolbar.frame.maxY - 8)
        // A point that used to be dead and is not any more: inside the fixed 240x104
        // rect the panel occupied in BOTH modes, and outside the pill-sized panel it
        // occupies now. This is the fix, stated as a coordinate.
        let reclaimed = CGPoint(x: toolbar.frame.midX,
                                y: toolbar.frame.minY + OverlayPlacementSeedSize.height - 8)
        // The control point: on the catcher, comfortably clear of the toolbar panel.
        let clear = CGPoint(x: host.frame.minX + 60, y: host.frame.maxY - 80)
        if !throughToolbar {
            let old = CGRect(origin: toolbar.frame.origin, size: OverlayPlacementSeedSize)
            print("      toolbar=\(fmt(toolbar.frame)) (was a fixed \(fmt(old))) pill=\(fmt(pill)) " +
                  "gap=\(String(format: "(%.0f, %.0f)", inGap.x, inGap.y)) " +
                  "reclaimed=\(String(format: "(%.0f, %.0f)", reclaimed.x, reclaimed.y)) " +
                  "control=\(String(format: "(%.0f, %.0f)", clear.x, clear.y)) trusted=\(AXIsProcessTrusted())")
            check11(toolbar.frame.contains(inGap) && !pill.contains(inGap) && catcher.frame.contains(inGap),
                    "sanity: the gap point is INSIDE the toolbar panel, outside the pill, and over the catcher")
            check11(!toolbar.frame.contains(clear) && catcher.frame.contains(clear),
                    "sanity: the control point is over the catcher and NOT over the toolbar panel")
            check11(old.contains(reclaimed) && !toolbar.frame.contains(reclaimed) && catcher.frame.contains(reclaimed),
                    "sanity: the reclaimed point is inside the OLD fixed panel, outside the new one, and over the catcher")
        }
        guard realClicks else {
            if !throughToolbar {
                print("      (candidate (d) needs a REAL click — skipped; set ANNOTKIT_PROBE_REALCLICK=1)")
            }
            clickPoint = nil
            return
        }
        guard AXIsProcessTrusted() else {
            check11(false, "posting a real click needs Accessibility trust — candidate (d) CANNOT be settled in this run")
            clickPoint = nil
            return
        }
        // Re-assert front immediately before the click: anything that came forward
        // in the last moment would otherwise eat it, and the phase would report a
        // fact about the desktop as a fact about AnnotKit.
        NSApp.activate(ignoringOtherApps: true)
        host.orderFrontRegardless()
        // The CONTROL leg is what says whether a posted click reaches this app at
        // all. If it did not, the desktop moved under the run and the two legs that
        // depend on it are unmeasurable — reported as skipped, because claiming
        // either answer from a click that never arrived is worse than claiming none.
        if leg != .control, controlClickLanded != true {
            print("      (\(leg == .reclaimed ? "reclaimed" : "chrome") leg skipped — the control click never landed, so this run cannot measure it)")
            clickPoint = nil
            return
        }

        session.setTool(.point)
        session.cancelSelection()
        session.endEditing()
        clickPoint = leg == .chrome ? inGap : (leg == .reclaimed ? reclaimed : clear)
        clickLeg = leg
        // Put the pointer back afterwards: a probe that steals the cursor and keeps
        // it is a probe people stop running.
        let restoreTo = NSEvent.mouseLocation
        clickOnScreen(clickPoint!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            CGWarpMouseCursorPosition(CGPoint(x: restoreTo.x, y: (NSScreen.screens.first?.frame.height ?? 0) - restoreTo.y))
        }
    }

    var clickPoint: CGPoint?
    var clickLeg: ClickLeg = .control
    /// Whether a posted click reached this app at all, established by the control
    /// leg and required by the two that follow it.
    var controlClickLanded: Bool?

    func phase11aReadClick(session: AnnotationSession) {
        guard let point = clickPoint else { return }
        let landed = session.selected
        let name = clickLeg == .control ? "CONTROL" : (clickLeg == .reclaimed ? "RECLAIMED" : "CHROME")
        print("      after the \(name) click at " +
              "\(String(format: "(%.0f, %.0f)", point.x, point.y)): session.selected = \(self.label(landed))")
        switch clickLeg {
        case .control:
            controlClickLanded = landed != nil
            if landed == nil {
                print("      (the app was not frontmost when the click landed — NSApp.isActive=\(NSApp.isActive); " +
                      "this run cannot settle the panel's footprint, and says nothing about it either way)")
            } else {
                check11(true, "control: a real click on the catcher DOES produce a selection (so a null result elsewhere means something)")
            }
        case .reclaimed:
            check11(landed != nil,
                    "a press where the old fixed 240x104 panel used to sit now REACHES the catcher — the corner is the host app's again")
        case .chrome:
            check11(landed == nil,
                    "what remains dead is only the chrome margin hugging the pill (shadow + count badge); macOS cannot pass a click through a window's transparent parts, so this band is the irreducible cost")
        }
        session.cancelSelection()
    }

    /// One real left click at a SCREEN point (Cocoa, y-up). CGEvent takes top-left
    /// global coordinates, so the y is flipped on the way out.
    func clickOnScreen(_ cocoaPoint: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: cocoaPoint.x, y: primaryHeight - cocoaPoint.y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cg, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// An element note and a framed note captured in the SAME session both survive,
    /// each carrying its own kind of geometry — which is what "area selections are
    /// maintained alongside the elements the user selects" actually asks for.
    func phase11bBothKindsCoexist(session: AnnotationSession, host: HostControls) -> (element: AnnotationNote?, area: AnnotationNote?) {
        print("\n  11b — an element note and an area note coexist, and switching tools drops neither:")
        guard let catcher = overlayCatcher(of: host.window) else {
            check11(false, "the catcher panel is present")
            return (nil, nil)
        }
        let axOrigin = ScreenSpace.windowAXOrigin(
            cocoaFrame: catcher.frame,
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0
        )

        session.setTool(.point)
        session.select(atAXPoint: axCenter(of: host.primary))
        let element = session.addNote(comment: "element note", axOrigin: axOrigin)

        // THE REPORTED FLOW: having selected and filed an element, use the frame
        // tool. Nothing in the model forbids it; the interference was all in the
        // view's hit-testing, which 11c measures.
        session.setTool(.frame)
        let sweep = axRect(ofCocoa: host.field.window!.convertToScreen(host.field.convert(host.field.bounds, to: nil)))
            .insetBy(dx: -10, dy: -10)
        session.select(inAXRect: sweep)
        check11(session.selected != nil, "a frame drag resolves AFTER an element note has been captured (got \(self.label(session.selected)))")
        let area = session.addNote(comment: "area note", axOrigin: axOrigin)

        check11(session.pending.count == 2, "both notes survive in one session (pending == 2, got \(session.pending.count))")
        check11(element?.drawnRect == nil, "the element note carries NO drawnRect")
        check11(area?.drawnRect != nil && area?.drawnRect == area?.anchorRect,
                "the area note carries a drawnRect that IS its anchor (an un-navigated framed note)")

        // Switching the tool must never destroy work in progress. Pinned here as
        // well as in the unit tests because this is the phase where a regression
        // would actually be noticed.
        session.setTool(.point)
        session.select(atAXPoint: axCenter(of: host.secondary))
        let live = session.selected
        session.setTool(.frame)
        check11(session.selected?.id == live?.id, "switching the tool KEEPS the live selection (the composer is not torn down)")
        check11(session.pending.count == 2, "switching the tool keeps the captured notes")
        session.cancelSelection()
        session.setTool(.point)
        return (element, area)
    }

    /// (a), measured both ways: a press on an existing pin must open the note's
    /// editor in POINT mode and do NOTHING in FRAME mode.
    ///
    /// The point-mode leg is the non-vacuity control for the frame-mode one. Without
    /// it, "the editor did not open" is equally consistent with the press never
    /// having arrived — which is not a hypothetical: the harness's first version sent
    /// the press in the same runloop turn as the `setTool` call, so it landed on the
    /// previous layout, and the control leg is what exposed that.
    ///
    /// Each call runs on its OWN turn (see `runSteps`) so the tool switch has been
    /// rendered before the press is sent.
    func phase11cPress(session: AnnotationSession, host: NSWindow, notes: (element: AnnotationNote?, area: AnnotationNote?), tool: AnnotationSession.SelectionTool) {
        if tool == .point { print("\n  11c — candidate (a): does a press that starts on a PIN reach the catcher?") }
        guard let catcher = overlayCatcher(of: host), let note = notes.element,
              let anchor = note.anchorRect?.origin else {
            check11(false, "a captured note with a drawable pin is on screen for the press")
            return
        }
        // The mode under test was set at the END of the previous step so it had a
        // whole runloop turn to be rendered. Assert it rather than assume it: a
        // press sent in the wrong mode would prove the opposite of what it claims.
        check11(session.tool == tool, "sanity: the overlay is in \(tool == .point ? "POINT" : "FRAME") mode before the press")
        // The pin is CENTRED on the anchor, in window-local y-DOWN coordinates; a
        // mouse event carries Cocoa y-UP window coordinates.
        let pinPoint = CGPoint(x: anchor.x, y: catcher.frame.height - anchor.y)
        session.endEditing()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: pinPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: catcher.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                check11(false, "a mouse event could be built for the pin press")
                return
            }
            catcher.sendEvent(event)
        }
        let opened = session.editingNoteID
        print("      \(tool == .point ? "POINT" : "FRAME") mode: press at pin #1 " +
              "(\(String(format: "(%.0f, %.0f)", pinPoint.x, pinPoint.y)) in the catcher panel) -> editingNoteID=\(opened ?? "nil")")
        if tool == .point {
            check11(opened == note.id,
                    "control: in POINT mode the press lands on the pin and opens its editor (pins behave exactly as they did)")
        } else {
            check11(opened == nil,
                    "in FRAME mode the pin is INERT — the press is not swallowed by the pin, so it can start a frame drag")
        }
        session.endEditing()
        // Leave the NEXT step's tool set here rather than at the top of it, so the
        // switch gets a full runloop turn to be rendered before that press is sent.
        session.setTool(tool == .point ? .frame : .point)
    }

    /// Recall: the hover→note mapping, driven through the session exactly as the
    /// catcher drives it, plus the two other ways a mark appears and disappears.
    func phase11dRecall(session: AnnotationSession, notes: (element: AnnotationNote?, area: AnnotationNote?)) {
        print("\n  11d — hovering a pin recalls THAT note's mark, and only ever one:")
        guard let element = notes.element, let area = notes.area,
              let elementPin = element.anchorRect?.origin, let areaPin = area.anchorRect?.origin else {
            check11(false, "both notes carry a drawable pin to hover")
            return
        }
        check11(session.attendedNoteID == nil, "nothing is attended before the pointer goes anywhere near a pin")

        session.attendPin(atWindowPoint: elementPin)
        check11(session.attendedNoteID == element.id, "hovering pin #1 attends the ELEMENT note")
        session.attendPin(atWindowPoint: areaPin)
        check11(session.attendedNoteID == area.id, "moving onto pin #2 attends the AREA note — the previous mark goes with it")
        check11(session.pending.filter { $0.id == session.attendedNoteID }.count == 1,
                "exactly ONE note is attended at a time")

        // Far from every pin. Non-vacuous only if it really is far: the two anchors
        // are the pins, so offsetting well past the attention radius from both is
        // the whole test.
        let empty = CGPoint(x: max(elementPin.x, areaPin.x) + 400, y: max(elementPin.y, areaPin.y) + 400)
        session.attendPin(atWindowPoint: empty)
        check11(session.attendedNoteID == nil, "moving off every pin drops the mark")

        // The edit card is the other way of asking the same question.
        session.beginEditing(id: area.id)
        check11(session.attendedNoteID == area.id, "opening a note's edit card also attends it (a card that names a note must not face an empty canvas)")
        session.endEditing()
        check11(session.attendedNoteID == nil, "closing the card removes the mark")

        // And a mark can never be recalled for a note that no longer exists.
        session.attendPin(atWindowPoint: elementPin)
        check11(session.attendedNote?.id == element.id, "sanity: pin #1 is attended again before the delete")
        session.deleteNote(id: element.id)
        check11(session.attendedNote == nil, "deleting the attended note drops its mark with no separate bookkeeping")
    }

    // ---- Phase 12: the FIRST click on the overlay acts ---------------------
    // The dogfooding report was "I have to click twice to get the functionality to
    // work and the little comment portal to appear", in BOTH tools. AppKit's rule:
    // a mouse-down in a NON-KEY window that CAN become key makes it key and then
    // DISCARDS the event unless the view under the pointer accepts first mouse —
    // and `NSHostingView` does not. `KeyablePanel` can become key (the composer's
    // text field needs it), so the first press only ever handed the panel focus.
    //
    // It is not once per launch, which is why it reads as a permanent tax: the
    // catcher panel is REBUILT every time the menu opens, and any interaction with
    // the host app hands key back, so the next press is swallowed again.
    //
    // Both panels are measured, because both are `KeyablePanel`s carrying a hosting
    // view and either could regress on its own. Every leg first asserts the panel is
    // NOT key — with the panel already key there is no first mouse to accept and the
    // phase would pass while proving nothing.
    /// Whether the phases that post REAL clicks at the window server run.
    ///
    /// OFF by default, and that is a correctness decision rather than politeness.
    /// A posted click depends on the whole desktop — Accessibility trust, which app
    /// is frontmost, whether anything came forward in the last 200ms — and it moves
    /// the user's pointer. Left on by default it made this probe FLAKY (measured:
    /// 2 failures in 5 back-to-back runs, in phases that do not click at all,
    /// because one run's activation and clicks perturbed the next run's AX reads;
    /// the same loop on `main` was 3 for 3 clean). A regression asset that is red
    /// two times in five teaches people to ignore it.
    ///
    /// What runs by default instead is the WHITE-BOX form of the same claim — the
    /// property that actually fixes the bug, asserted directly. Set
    /// `ANNOTKIT_PROBE_REALCLICK=1` for the end-to-end version.
    var realClicks: Bool { ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_REALCLICK"] == "1" }

    /// Whether a posted click or keystroke could have reached this app at all. Every
    /// real-input leg depends on being frontmost, and on a busy desktop something
    /// else can take that away mid-run. A leg that cannot measure says so instead of
    /// reporting the desktop's state as AnnotKit's — the alternative is a probe that
    /// is red two runs in five for reasons no one can act on, which is how a
    /// regression asset gets ignored.
    func realInputCouldLand(_ what: String) -> Bool {
        guard NSApp.isActive else {
            print("      (\(what) skipped — this app was not frontmost when the input landed, so the run cannot measure it)")
            return false
        }
        return true
    }

    var passFirstClick = true
    func check12(_ c: Bool, _ m: String) {
        print("      " + (c ? "ok   " : "FAIL ") + m)
        passFirstClick = passFirstClick && c
    }

    var firstClickHost: HostControls?
    var firstClickController: OverlayController?

    func phase12FirstClick() {
        print("\n--- Phase 12: the first click on the overlay ACTS (no click tax) ---")
        let host = makeHostWindow(title: "AnnotKit Harness W12 (first click)")
        host.window.makeKeyAndOrderFront(nil)
        firstClickHost = host

        let session = AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        let controller = OverlayController(session: session)
        // MOUNT ONLY: the menu stays closed, so 12a measures the toolbar panel's
        // own first click — the one that opens the menu in the first place.
        controller.mount(on: host.window)
        firstClickController = controller

        // The DEFAULT, deterministic form: assert the property that fixes the bug,
        // on both panels, directly. AppKit consults exactly this on the view under
        // a press into a non-key window, so a regression here — someone swapping
        // the hosting view back — is the regression, and this catches it without
        // depending on the desktop.
        check12(overlayToolbar(of: host.window)?.contentView?.acceptsFirstMouse(for: nil) == true,
                "the TOOLBAR panel's content view accepts first mouse (one click on the pill opens the menu)")
        controller.start()
        check12(overlayCatcher(of: host.window)?.contentView?.acceptsFirstMouse(for: nil) == true,
                "the CATCHER panel's content view accepts first mouse (one click selects, in either tool)")
        // Non-vacuity: a plain NSHostingView answers false, so the checks above are
        // about the subclass and not about some default every view shares.
        check12(NSHostingView(rootView: Color.clear).acceptsFirstMouse(for: nil) == false,
                "sanity: a plain NSHostingView does NOT accept first mouse (which is the whole bug)")
        controller.stop()

        guard realClicks else {
            print("      (end-to-end real-click legs skipped — set ANNOTKIT_PROBE_REALCLICK=1)")
            controller.unmount(); host.window.orderOut(nil); return phase13Keyboard()
        }
        guard AXIsProcessTrusted() else {
            check12(false, "posting real clicks needs Accessibility trust — the end-to-end legs CANNOT run")
            controller.unmount(); host.window.orderOut(nil); return phase13Keyboard()
        }
        host.window.setFrameOrigin(NSPoint(x: visibleFrame.minX + 140, y: visibleFrame.minY + 240))
        NSApp.activate(ignoringOtherApps: true)

        runSteps([
            { self.phase12aToolbar(session: session, host: host.window) },
            { self.phase12bCatcher(session: session, host: host.window) },
            {
                print("      after ONE click on a control: session.selected = \(self.label(session.selected))")
                if session.selected != nil || self.realInputCouldLand("the catcher click") {
                    self.check12(session.selected != nil,
                                 "ONE click on the catcher selects — the first press is not spent making the panel key")
                }
                controller.unmount()
                host.window.orderOut(nil)
                self.phase13Keyboard()
            }
        ])
    }

    /// 12a — one click on the pill opens the menu.
    func phase12aToolbar(session: AnnotationSession, host: NSWindow) {
        guard let toolbar = overlayToolbar(of: host) else {
            check12(false, "the toolbar panel is mounted")
            return
        }
        host.makeKeyAndOrderFront(nil)
        check12(!toolbar.isKeyWindow && host.isKeyWindow,
                "sanity: the toolbar panel is NOT key and the host IS (else there is no first mouse to accept)")
        // Idle draws ONE 44pt button at the pill's trailing end, 20pt in from the
        // panel's bottom-right corner.
        let pencil = CGPoint(x: toolbar.frame.maxX - 20 - 22, y: toolbar.frame.minY + 20 + 22)
        let restoreTo = NSEvent.mouseLocation
        clickOnScreen(pencil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            CGWarpMouseCursorPosition(CGPoint(x: restoreTo.x, y: (NSScreen.screens.first?.frame.height ?? 0) - restoreTo.y))
        }
        pendingFirstClickCheck = { [weak self] in
            guard let self else { return }
            guard session.mode == .annotating || self.realInputCouldLand("the pill click") else { return }
            self.check12(session.mode == .annotating,
                         "ONE click on the pill opens the menu (got \(session.mode))")
        }
    }

    var pendingFirstClickCheck: (() -> Void)?

    /// 12b — with the menu open and the HOST key again, one click on a control
    /// selects it. This is the leg the user reported: the catcher panel is freshly
    /// built by every open, so it is never key when the first press arrives.
    func phase12bCatcher(session: AnnotationSession, host: NSWindow) {
        pendingFirstClickCheck?()
        pendingFirstClickCheck = nil
        guard let catcher = overlayCatcher(of: host), let control = firstClickHost?.primary else {
            check12(false, "the catcher panel is open for the second leg")
            return
        }
        // Hand key BACK to the host — exactly what happens when a user touches
        // their own app between annotations.
        host.makeKeyAndOrderFront(nil)
        check12(!catcher.isKeyWindow && host.isKeyWindow,
                "sanity: the catcher panel is NOT key and the host IS")
        let screen = control.window!.convertToScreen(control.convert(control.bounds, to: nil))
        let restoreTo = NSEvent.mouseLocation
        clickOnScreen(CGPoint(x: screen.midX, y: screen.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            CGWarpMouseCursorPosition(CGPoint(x: restoreTo.x, y: (NSScreen.screens.first?.frame.height ?? 0) - restoreTo.y))
        }
    }

    // ---- Phase 13: the card's keyboard contract ----------------------------
    // The card promises "⏎ save · ⇧⏎ newline" in its own header, and the second
    // half of that was not true: Shift+Return inserted nothing AND discarded what
    // had already been typed, because a vertical `TextField` has no newline gesture
    // on macOS and the key reached AppKit as an ordinary `insertNewline:`.
    //
    // Asserted END TO END, through the composer's real text field, because that is
    // the only place the claim is meaningful: the draft is `@State` in the view, so
    // the only honest way to read it is to make the note and look at what was
    // filed. Real key events, so it rides the same opt-in flag as the click legs.
    var passKeyboard = true
    func check13(_ c: Bool, _ m: String) {
        print("      " + (c ? "ok   " : "FAIL ") + m)
        passKeyboard = passKeyboard && c
    }

    var keyboardController: OverlayController?

    func phase13Keyboard() {
        print("\n--- Phase 13: the card's keyboard contract (⏎ saves, ⇧⏎ inserts a line break) ---")
        guard realClicks else {
            print("      (needs real key events — skipped; set ANNOTKIT_PROBE_REALCLICK=1)")
            return finish()
        }
        guard AXIsProcessTrusted() else {
            check13(false, "posting real key events needs Accessibility trust")
            return finish()
        }
        let host = makeHostWindow(title: "AnnotKit Harness W13 (keyboard)")
        host.window.setFrameOrigin(NSPoint(x: visibleFrame.minX + 160, y: visibleFrame.minY + 260))
        NSApp.activate(ignoringOtherApps: true)
        host.window.makeKeyAndOrderFront(nil)

        let session = AnnotationSession(source: MacElementSource(), sink: NotesFileSink(path: "/dev/null"))
        let controller = OverlayController(session: session)
        controller.mount(on: host.window)
        controller.start()
        keyboardController = controller

        runSteps([
            {
                // Open the composer on a real control. The card focuses itself and
                // makes the panel key, which is what puts the field editor in the
                // responder chain the keystrokes will reach.
                NSApp.activate(ignoringOtherApps: true)
                session.select(atAXPoint: axCenter(of: host.primary))
                self.check13(session.selected != nil, "sanity: the composer is open on a real element")
            },
            {
                // "a", Shift+Return, "b" — the sequence that used to leave "b".
                self.typeKey(0)
                self.typeKey(36, shift: true)
                self.typeKey(11)
            },
            {
                // Enter commits, which is the only way to read a draft that lives
                // in the view's own @State.
                self.typeKey(36)
            },
            {
                let comment = session.pending.last?.comment
                print("      filed comment = \(comment.map { "\"\($0.replacingOccurrences(of: "\n", with: "\\n"))\"" } ?? "nil")")
                guard !session.pending.isEmpty || self.realInputCouldLand("the keyboard legs") else {
                    controller.unmount(); host.window.orderOut(nil); return self.finish()
                }
                self.check13(session.pending.count == 1, "⏎ filed the note (got \(session.pending.count))")
                self.check13(comment == "a\nb",
                             "⇧⏎ inserted a LINE BREAK and kept what was already typed (the old behaviour filed \"b\")")
                controller.unmount()
                host.window.orderOut(nil)
                self.finish()
            }
        ])
    }

    /// One real keystroke. Virtual key codes are hardware positions, so they are
    /// layout-independent: 0 = "a", 11 = "b", 36 = Return.
    func typeKey(_ code: CGKeyCode, shift: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        if shift {
            down.flags = .maskShift
            up.flags = .maskShift
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func finish() {
        print("\n  issue-2 (per-control hit-test through the expanded overlay): \(passIssue2 ? "PASS" : "FAIL")")
        print("  issue-1 (retention / copy / export / pill persistence):       \(pass1 ? "PASS" : "FAIL")")
        print("  Feature 1 (numbered-pin MODEL: anchors + update + delete/reflow): \(passPins ? "PASS" : "FAIL")")
        print("  Phase 3 (mis-placed-pill regression: pill + axOrigin track FINAL frame): \(passResize ? "PASS" : "FAIL")")
        print("  Phase 4 (window chrome excluded from the hit-test): \(passChrome ? "PASS" : "FAIL")")
        print("  Phase 5 (seeded container resolves on body hover): \(passCard ? "PASS" : "FAIL")")
        print("  Phase 6 (positional specificity by cursor position): \(passSpec ? "PASS" : "FAIL")")
        print("  Phase 7 (marquee frame selection: drawn rect -> element): \(passMarquee ? "PASS" : "FAIL")")
        print("  Phase 8 (selection navigation: round trips, history, component, frame anchor): \(passNav ? "PASS" : "FAIL")")
        print("  Phase 9 (pill + hit-test + scroll on a host hanging off the visible screen): \(passClamp ? "PASS" : "FAIL")")
        print("  Phase 10 (Escape closes the menu): \(passEscape ? "PASS" : "FAIL")")
        print("  Phase 11 (recallable marks: toolbar pass-through, pins inert in frame mode, hover recall): \(passMarks ? "PASS" : "FAIL")")
        print("  Phase 12 (the FIRST click on the overlay acts — no click tax): \(passFirstClick ? "PASS" : "FAIL")")
        print("  Phase 13 (the card's keyboard contract: ⏎ saves, ⇧⏎ newlines): \(passKeyboard ? "PASS" : "FAIL")")
        print("\n=== AnnotKitOverlayProbe complete ===")
        exit(pass1 && passIssue2 && passPins && passResize && passChrome && passCard && passSpec && passMarquee && passNav && passClamp && passEscape && passMarks && passFirstClick && passKeyboard ? 0 : 1)
    }

    func collectIDs(_ elements: [Element]) -> [String] {
        var out: [String] = []
        for element in elements {
            out.append(element.id)
            out.append(contentsOf: collectIDs(element.children))
        }
        return out
    }
}

/// Phase 5 host content: the HUD-card pattern under test. NOTE a plain
/// `.accessibilityElement(children: .contain)` container is NOT enough: SwiftUI
/// reports the contained group's AX frame as the UNION OF ITS CHILDREN (probed:
/// card frame == text frame), so the card's visual padding is dead to the AX
/// hit-test. The working pattern is an explicit full-size accessibility SURFACE:
/// a clear background carrying the card's identifier, whose AX frame is the
/// card's real visual bounds. Hovering the body hits the surface; hovering a
/// child still hits the child (the surface sits below content in AX z-order).
struct ProbeCardView: View {
    var body: some View {
        VStack {
            Text("Card body probe")
                .accessibilityIdentifier("Probe.CardText")
        }
        .padding(60)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("Probe.Card")
        )
        .padding(40)
    }
}

/// Phase 6 host content: the specificity fixture — an actionable button, an
/// UNIDENTIFIED value-only text (the AXValue root-cause case), a card (surface
/// + identified text child), all inside a section-level surface.
struct ProbeSpecificityView: View {
    var body: some View {
        VStack(spacing: 28) {
            Button("Spec Target") {}
                .accessibilityIdentifier("Spec.Button")
            Text("plain value text")
            VStack {
                Text("Card text")
                    .accessibilityIdentifier("Spec.CardText")
            }
            .padding(50)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("Spec.Card")
            )
        }
        .padding(36)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("Spec.Section")
        )
        .padding(24)
    }
}

/// Phase 8 host content: the specificity fixture (reused unchanged — its card /
/// card text / section are the nesting the UPWARD navigation and the frame anchor
/// need) plus ONE addition it cannot supply: a container with real children.
///
/// The addition is deliberate and minimal. `ProbeSpecificityView`'s elements are
/// all AX leaves, so `ChildNavigationSource` can only return [] for them and every
/// descent assertion built on it would be vacuously green. This container is:
///
/// * MEANINGFUL but UNSEEDED (a label, no identifier) — so descending below it
///   exercises the `component` search that must skip unseeded rungs, and its own
///   `Element.id` is the slash-joined path that must never reach a note; and
/// * a real AX parent (`children: .contain`) of two UNSEEDED rows — so the child
///   the descent lands on is unseeded too, and the note's component has to be
///   found further up, at `Nav.Section`.
///
/// Both fixtures share one window so the phase reads one snapshot; they are
/// independent subtrees, so neither one's geometry disturbs the other.
struct ProbeNavigationView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProbeSpecificityView()

            VStack(alignment: .leading, spacing: 8) {
                Text("Row one")
                Text("Row two")
            }
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Nav list")
        }
        .padding(24)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("Nav.Section")
        )
        .padding(16)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = OverlayProbeDelegate()
app.delegate = delegate
app.run()
#else
print("AnnotKitOverlayProbe is macOS-only")
#endif
