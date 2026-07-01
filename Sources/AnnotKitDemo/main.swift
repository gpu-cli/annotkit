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
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Mount the annotation overlay (dev-only gate is on in a debug build).
        Annotation.install()
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
