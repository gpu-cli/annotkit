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
            let axPoint = axCenter(of: h2.primary)
            _ = session.select(atAXPoint: axPoint); session.addNote(comment: "issue-1 note A")
            _ = session.select(atAXPoint: axPoint); session.addNote(comment: "issue-1 note B")
            print("  captured 2 notes -> pending=\(session.pending.count) mode=\(session.mode)")
            check1(session.pending.count == 2, "addNote APPENDS to a retained set (pending == 2)")

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
            finish()
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

        finish()
    }

    func finish() {
        print("\n  issue-2 (per-control hit-test through the expanded overlay): \(passIssue2 ? "PASS" : "FAIL")")
        print("  issue-1 (retention / copy / export / pill persistence):       \(pass1 ? "PASS" : "FAIL")")
        print("\n=== AnnotKitOverlayProbe complete ===")
        exit(pass1 && passIssue2 ? 0 : 1)
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = OverlayProbeDelegate()
app.delegate = delegate
app.run()
#else
print("AnnotKitOverlayProbe is macOS-only")
#endif
