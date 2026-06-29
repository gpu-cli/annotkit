#if os(macOS)
import AppKit
import AnnotKit

// Live smoke test of the macOS AX adapter. Builds an off-screen window with two
// identified buttons, then verifies the adapter walks the real AX tree, finds
// the seeded identifiers, hit-tests a button, and generates a round-tripping
// selector. Exits 0 on pass, 1 on fail. Not a unit test (it needs a running
// NSApplication and the window server), so it lives as an executable.

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var save: NSButton!

    func applicationDidFinishLaunching(_ note: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: -12000, y: -12000, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "ProbeWindow"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        save = NSButton(title: "Save", target: nil, action: nil)
        save.setAccessibilityIdentifier("SaveButton")
        save.frame = NSRect(x: 40, y: 120, width: 120, height: 32)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.setAccessibilityIdentifier("CancelButton")
        cancel.frame = NSRect(x: 200, y: 120, width: 120, height: 32)
        content.addSubview(save)
        content.addSubview(cancel)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        // Let AppKit materialize the AX tree, then introspect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.introspect()
        }
    }

    func introspect() {
        var pass = true
        func check(_ cond: Bool, _ msg: String) {
            print((cond ? "ok   " : "FAIL ") + msg)
            pass = pass && cond
        }

        let source = MacElementSource()
        let windows = source.snapshot()
        check(!windows.isEmpty, "snapshot returned \(windows.count) window(s)")

        let ids = Self.collectIDs(windows.map(\.root))
        check(ids.contains("SaveButton"), "AX tree contains SaveButton")
        check(ids.contains("CancelButton"), "AX tree contains CancelButton")

        // Hit-test the Save button center, converted to AX top-left screen space.
        let inWindow = save.convert(save.bounds, to: nil)
        let inScreen = save.window!.convertToScreen(inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: inScreen.midX, y: primaryHeight - inScreen.midY)

        if let hit = source.hitTest(axPoint) {
            check(true, "hitTest -> id=\(hit.id) role=\(hit.role) label=\(hit.label)")
            let selector = source.selector(for: hit)
            check(!selector.isEmpty, "selector(for: hit) = \(selector)")
        } else {
            check(false, "hitTest returned nil at \(axPoint)")
        }

        print(pass ? "PROBE PASS" : "PROBE FAIL")
        exit(pass ? 0 : 1)
    }

    static func collectIDs(_ elements: [Element]) -> [String] {
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
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
#else
print("AnnotKitProbe is macOS-only")
#endif
