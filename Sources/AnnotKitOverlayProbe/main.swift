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
func idleFrame(_ host: CGRect) -> CGRect {
    CGRect(x: host.maxX - 240, y: host.minY, width: 240, height: 104)
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
        print("=== AnnotKitOverlayProbe: EXPANDED-overlay AX diagnostic ===")
        h1 = makeSwiftUIHost(title: "AnnotKit Harness W1")
        // SwiftUI needs a beat to render before its AX tree materializes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.phase1Baseline()
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
            // Mirror OverlayView's REAL capture path: snapshot a WINDOW-LOCAL pin
            // anchor (the selected element's AX top-left minus the host window's
            // axOrigin) BEFORE addNote clears the selection, and hand it to addNote
            // — the exact value Feature 1 stores on the note to place its numbered
            // pin. Two DISTINCT controls yield two DISTINCT anchors, so we can prove
            // each note owns its own anchor rather than sharing one.
            let axOrigin = ScreenSpace.windowAXOrigin(
                cocoaFrame: h2.window.frame,
                primaryHeight: NSScreen.screens.first?.frame.height ?? 0
            )
            @MainActor func captureNote(_ comment: String, at view: NSView) -> AnnotationNote? {
                let element = session.select(atAXPoint: axCenter(of: view))
                let anchor = element.map {
                    CGPoint(x: $0.frame.minX - axOrigin.x, y: $0.frame.minY - axOrigin.y)
                }
                return session.addNote(comment: comment, anchor: anchor)
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

        guard let panel = h2.window.childWindows?.first else {
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
    /// Assert both freshly-captured notes carry a non-nil window-local anchor that
    /// lands inside the host window's bounds, and that the two anchors DIFFER (so a
    /// pin is per-note, not a single shared position).
    func verifyPinAnchors(noteA: AnnotationNote?, noteB: AnnotationNote?, host: NSWindow) {
        print("\n  Feature 1 — numbered-pin anchors (window-local, snapshot at addNote):")
        guard let noteA, let noteB else {
            checkPins(false, "both notes captured (addNote returned a note for each control)")
            return
        }
        // Window-local space: origin at the host window's top-left, so a valid
        // anchor sits within (0,0)...(width,height). Grown 1pt for float slack.
        let bounds = CGRect(origin: .zero, size: host.frame.size).insetBy(dx: -1, dy: -1)
        for (label, note) in [("note A (pin #1)", noteA), ("note B (pin #2)", noteB)] {
            guard let anchor = note.anchor else {
                checkPins(false, "\(label) carries a non-nil window-local anchor")
                continue
            }
            print("      \(label) anchor=\(String(format: "(%.1f, %.1f)", anchor.x, anchor.y)) " +
                  "host-local bounds=\(fmt(CGRect(origin: .zero, size: host.frame.size)))")
            checkPins(true, "\(label) carries a non-nil window-local anchor")
            checkPins(bounds.contains(anchor), "\(label) anchor is inside the host window bounds")
        }
        if let a = noteA.anchor, let b = noteB.anchor {
            checkPins(a != b, "the two notes carry DISTINCT anchors (per-note, not a shared position)")
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
        checkPins(session.pending.first?.anchor == second.anchor, "the survivor keeps its OWN captured anchor after the reflow")

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
        // provably stays at `idleFrame(base)`.
        let base = host.frame
        let grown = grownFrame(from: base)
        let attached = host.childWindows?.first?.frame
        print("      attached idle panel=\(attached.map(fmt) ?? "nil") (host \(fmt(base)); expect \(fmt(idleFrame(base))))")
        check3(attached.map { approxEqual($0, idleFrame(base)) } ?? false,
               "sanity: pill attaches at the small pre-layout corner")

        // Grow the host on the next runloop turn (inside the settle-poll window),
        // with NO re-sync-triggering notification reaching the controller.
        DispatchQueue.main.async { host.setFrame(grown, display: true) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let panel = host.childWindows?.first?.frame
            print("      after growth: host=\(fmt(host.frame)) idle panel=\(panel.map(fmt) ?? "nil") " +
                  "(expect \(fmt(idleFrame(grown))), stale would be \(fmt(idleFrame(base))))")
            check3(panel.map { approxEqual($0, idleFrame(grown)) } ?? false,
                   "idle pill sits at the LARGE window's corner after the post-layout growth")
            check3(panel.map { !approxEqual($0, idleFrame(base)) } ?? false,
                   "idle pill is no longer stuck at the stale small pre-layout corner")
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
            let overlayPanel = rawWindows.first { AX.string($0, kAXIdentifierAttribute) == overlayWindowIdentifier }
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
            self.finish()
        }
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

    func finish() {
        print("\n  issue-2 (per-control hit-test through the expanded overlay): \(passIssue2 ? "PASS" : "FAIL")")
        print("  issue-1 (retention / copy / export / pill persistence):       \(pass1 ? "PASS" : "FAIL")")
        print("  Feature 1 (numbered-pin MODEL: anchors + update + delete/reflow): \(passPins ? "PASS" : "FAIL")")
        print("  Phase 3 (mis-placed-pill regression: pill + axOrigin track FINAL frame): \(passResize ? "PASS" : "FAIL")")
        print("  Phase 4 (window chrome excluded from the hit-test): \(passChrome ? "PASS" : "FAIL")")
        print("  Phase 5 (seeded container resolves on body hover): \(passCard ? "PASS" : "FAIL")")
        print("  Phase 6 (positional specificity by cursor position): \(passSpec ? "PASS" : "FAIL")")
        print("  Phase 7 (marquee frame selection: drawn rect -> element): \(passMarquee ? "PASS" : "FAIL")")
        print("\n=== AnnotKitOverlayProbe complete ===")
        exit(pass1 && passIssue2 && passPins && passResize && passChrome && passCard && passSpec && passMarquee ? 0 : 1)
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = OverlayProbeDelegate()
app.delegate = delegate
app.run()
#else
print("AnnotKitOverlayProbe is macOS-only")
#endif
