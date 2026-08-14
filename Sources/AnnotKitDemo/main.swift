#if os(macOS)
import AnnotKit
import AppKit
import SwiftUI

// A tiny host app for trying AnnotKit by hand — and for recording demos. Run
// it (`swift run AnnotKitDemo`), use the "Annotate" toolbar (bottom-right),
// click any control below, type a note, and Save. Notes are written to
// AGENTATION_NOTES.md in the current working directory.
//
// The screen is a small, realistic settings page so both gestures demo well:
// click a control (deepest actionable wins) or drag a frame around one of the
// stat cards (largest surrounded element wins). Everything meaningful carries
// a dot-notation accessibilityIdentifier so generated selectors show the
// `#Settings.Profile >> @NameField`-style anchoring in the emitted notes.
// Semantic colors only, so the window is dark-mode friendly on camera.

private struct StatCard: View {
    let identifier: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title).bold()
                .accessibilityIdentifier("\(identifier).Value")
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier).Label")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        // Expose the card itself as an AX group so a drawn frame binds to the
        // whole card rather than the value/label leaves inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct DemoView: View {
    @State private var name = "Ada Lovelace"
    @State private var email = "ada@example.com"
    @State private var notifications = true
    @State private var plan = "Pro"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Acme Settings")
                    .font(.largeTitle).bold()
                    .accessibilityIdentifier("Settings.Title")
                Text("Click 'Annotate' (bottom-right), then click a control — or drag a frame around a card — type a note, and Save. Notes land in AGENTATION_NOTES.md in your working directory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Settings.Instructions")
            }

            GroupBox {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.tint.opacity(0.15))
                        Text("AL")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 48, height: 48)
                    .accessibilityIdentifier("Settings.Profile.Avatar")

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("Settings.Profile.NameField")
                        TextField("Email", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("Settings.Profile.EmailField")
                    }

                    Spacer()

                    Toggle("Notifications", isOn: $notifications)
                        .accessibilityIdentifier("Settings.Profile.NotificationsToggle")
                }
                .padding(8)
            } label: {
                Text("Profile")
                    .accessibilityIdentifier("Settings.Profile.Header")
            }
            .accessibilityIdentifier("Settings.Profile")

            HStack(spacing: 12) {
                StatCard(identifier: "Settings.Stats.Projects", value: "12", label: "Projects")
                StatCard(identifier: "Settings.Stats.Streak", value: "8 days", label: "Streak")
                StatCard(identifier: "Settings.Stats.Storage", value: "64%", label: "Storage")
            }

            HStack(spacing: 12) {
                Button("Save changes") {}
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("Settings.Actions.Save")
                Button("Reset") {}
                    .accessibilityIdentifier("Settings.Actions.Reset")
                Spacer()
                Picker("Plan", selection: $plan) {
                    Text("Free").tag("Free")
                    Text("Pro").tag("Pro")
                    Text("Team").tag("Team")
                }
                .frame(width: 160)
                .accessibilityIdentifier("Settings.Actions.PlanPicker")
            }

            Text("AnnotKit Demo · v0.1 · dev build")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("Settings.Footer.Version")
        }
        .padding(28)
        .frame(width: 620, height: 560)
    }
}

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
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
