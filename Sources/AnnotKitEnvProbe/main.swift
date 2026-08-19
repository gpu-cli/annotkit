#if os(macOS)
import AnnotKit
import AppKit
import Foundation

// One ISOLATED INSTANCE of an embedding host, configured from its environment and
// nothing else — the thing an agent-driving launcher actually starts N of.
//
// It is the AnnotKitDemo story with the human taken out: same `Annotation.install`
// path, same env-derived sinks, same world-context provider, but the click, the
// typing and the Save are driven in code so the whole loop can be asserted. That
// is what makes it a regression asset rather than a demo — `AgentLoopE2ETests`
// launches two of these at once and reads what they wrote.
//
// Reads (all optional, all from the environment):
//   ANNOTKIT_NOTES_MD / ANNOTKIT_NOTES / ANNOTKIT_EVENTS  destinations
//   ANNOTKIT_ROUTE, ANNOTKIT_CONTEXT[_KEY]                world provenance
//   ANNOTKIT_PROBE_COMMENT                                the note's text
//   ANNOTKIT_PROBE_EDIT                                   re-export with an edit
// Exits 0 on pass, 1 on fail, printing one `ok`/`FAIL` line per check.

/// A canned source so the capture is deterministic and needs no accessibility
/// permission: what is under test here is the embedding contract — env to
/// destinations to context to files — not the AX adapter, which `AnnotKitProbe`
/// already exercises against the live tree.
@MainActor
private final class ProbeSource: ElementSource {
    let element = Element(
        id: "SaveButton",
        role: "AXButton",
        type: "AXButton",
        label: "Save",
        value: "Save",
        frame: CGRect(x: 40, y: 120, width: 120, height: 32),
        isVisible: true,
        isActionable: true,
        path: [PathComponent(role: "AXWindow", label: "EnvProbeWindow", identifier: nil, indexAmongRole: 0),
               PathComponent(role: "AXButton", label: "Save", identifier: "SaveButton", indexAmongRole: 0)]
    )
    func snapshot() -> [WindowSnapshot] { [] }
    func hitTest(_ point: CGPoint) -> Element? { element }
    func selector(for element: Element) -> String { "#\(element.id)" }
    func screenshot(of element: Element?) async throws -> CapturedImage {
        CapturedImage(pngData: Data(), pixelWidth: 1, pixelHeight: 1)
    }
}

@MainActor
final class EnvProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var pass = true

    private func check(_ condition: Bool, _ message: String) {
        print((condition ? "ok   " : "FAIL ") + message)
        pass = pass && condition
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Off-screen: this runs unattended, and a window that steals focus from
        // whoever is running the suite is its own kind of test failure.
        let window = NSWindow(
            contentRect: NSRect(x: -12000, y: -12000, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "EnvProbeWindow"
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.makeKeyAndOrderFront(nil)
        self.window = window

        let environment = Annotation.environment
        check(environment.isEnabled(byDefault: true), "the launch environment enables the overlay")

        // The whole point: no paths, no context, no route in this call. The launcher
        // decided all of it, and the provider adds only what the running app knows.
        Annotation.install(
            on: window,
            source: ProbeSource(),
            context: { ["window": "400x300"] }
        )
        check(Annotation.isInstalled, "install() mounted the overlay on the host window")

        guard let session = Annotation.current else {
            check(false, "Annotation.current is nil after install()")
            return finish()
        }

        let comment = ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_COMMENT"]
            ?? "contrast is too low here"
        session.start()
        check(session.select(atAXPoint: CGPoint(x: 100, y: 136)) != nil, "the catcher resolved an element")
        let note = session.addNote(comment: comment)
        check(note != nil, "addNote produced a note")
        check(note?.context?["window"] == "400x300", "the provider's live value rode along on the note")
        check(note?.context?["persona"] != nil, "the launcher's context rode along on the note")
        check(note?.route != nil, "the note carries a route")

        do { try session.export() } catch { check(false, "export threw: \(error)") }

        // A second export with an edited comment, so the event stream has to
        // distinguish `edited` from a re-announced `captured`.
        if ProcessInfo.processInfo.environment["ANNOTKIT_PROBE_EDIT"] != nil, let id = note?.id {
            session.updateNote(id: id, comment: comment + " (edited)")
            do { try session.export() } catch { check(false, "re-export threw: \(error)") }
        }

        finish()
    }

    private func finish() {
        print(pass ? "ENV PROBE PASS" : "ENV PROBE FAIL")
        exit(pass ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = EnvProbeDelegate()
app.delegate = delegate
app.run()
#endif
