#if os(macOS)
import AnnotKit
import AppKit
import SwiftUI

// A tiny host app for trying AnnotKit by hand. Run it, use the "Annotate"
// toolbar (bottom-right), click any control below, type a note, and Save. Notes
// are written to AGENTATION_NOTES.md in the current working directory.

struct DemoView: View {
    @State private var text = ""
    @State private var toggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AnnotKit Demo")
                .font(.largeTitle).bold()
                .accessibilityIdentifier("Demo.Title")

            Text("Click 'Annotate' (bottom-right), then click any control below, type a note, and Save. Notes land in AGENTATION_NOTES.md in your working directory.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("Demo.Instructions")

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
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AnnotKit Demo"
        window.contentView = NSHostingView(rootView: DemoView())
        window.center()
        self.window = window

        // `swift run` launches an unbundled binary, so a single activation often
        // loses the race with the window server and the window opens behind the
        // terminal. Bring it fully to the front, then retry briefly until it
        // takes. (An embedded host is normally already frontmost; AnnotKit also
        // self-activates in `OverlayController.start()` when annotation begins.)
        bringToFront()
        retryActivationIfNeeded(attemptsRemaining: 5)

        // Mount the annotation overlay (dev-only gate is on in a debug build).
        Annotation.install()
    }

    /// Full activation sequence for an unbundled `swift run` process.
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Activation from an unbundled binary can silently no-op if it fires before
    /// the process is registered with the window server. Re-attempt on the main
    /// queue until the app is active or we run out of attempts.
    private func retryActivationIfNeeded(attemptsRemaining: Int) {
        guard attemptsRemaining > 0, !NSApp.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !NSApp.isActive else { return }
            self.bringToFront()
            self.retryActivationIfNeeded(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = DemoAppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
#else
import Foundation
print("AnnotKitDemo is macOS-only")
#endif
