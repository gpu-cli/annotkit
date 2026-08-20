# AnnotKit

Site: <https://annotkit.gpu-cli.sh>

A Swift package for native in-app annotation, built for AI coding agents. Click
a UI element in your own macOS or iOS app, or drag a frame around it, attach a
note, and emit an agent-readable, code-locating annotation. The native analogue
of the web Agentation tool.

The gesture becomes a stable selector, an element path, the element's role and
text, and your comment, so an AI coding agent can locate the exact view instead
of guessing from a verbal description.

**Requirements:** Swift 6.1 toolchain (Xcode 16.3 or later), macOS 15+ or
iOS 17+. The package is Swift 6 language mode with strict concurrency. It has no
dependencies.

## Add it to an existing Swift app

### 1. Add the package

**Xcode:** File ▸ Add Package Dependencies…, paste
`https://github.com/gpu-cli/annotkit`, choose the version rule **Up to Next
Major** from `0.8.0`, and add the `AnnotKit` library to your app target. Leave
`AnnotKitMCP` unchecked unless you want the [agent bridge](#agent-bridge-optional);
the toolbar does not need it.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/gpu-cli/annotkit", from: "0.8.0")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "AnnotKit", package: "annotkit")]
    )
]
```

### 2. Mount the toolbar once the app has a window

**AppKit (macOS):** in `applicationDidFinishLaunching`, after your main window
is up:

```swift
import AnnotKit

func applicationDidFinishLaunching(_ notification: Notification) {
    // ... make and show your window ...
    #if DEBUG
    Annotation.install()   // floating toolbar; click a view, type a note
    #endif
}
```

If several windows are open at launch, name the one to annotate instead of
letting AnnotKit pick: `Annotation.install(on: window)`.

**SwiftUI (macOS):** call it from the root view's `.onAppear` or from an
`NSApplicationDelegateAdaptor`:

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    #if DEBUG
                    Annotation.install()
                    #endif
                }
        }
    }
}
```

**SwiftUI (iOS):** attach it to the root view:

```swift
ContentView()
    #if DEBUG
    .installAnnotation()
    #endif
```

UIKit iOS hosts call `Annotation.install()` from the scene delegate once the
window is key.

`install()` is a no-op in release builds unless the `ANNOTKIT_ENABLE`
environment variable is set, and a no-op in debug builds when `ANNOTKIT_DISABLE`
is set, so the `#if DEBUG` above is belt and braces: the toolbar never appears
in a normal shipping build either way.

### 3. Decide where the notes go

By default notes are written to `ANNOTKIT_NOTES.md` in the process's **current
working directory**. For an app launched from Xcode that is usually *not* your
project folder. Either set the working directory in the scheme
(Edit Scheme ▸ Run ▸ Options ▸ Working Directory), point the path at the repo
through the scheme's environment variables (`ANNOTKIT_NOTES_MD=/path/to/repo/ANNOTKIT_NOTES.md`),
or pass a sink with an explicit path:

```swift
Annotation.install(sink: NotesFileSink(path: "/path/to/repo/ANNOTKIT_NOTES.md"))
```

Other sinks: `ClipboardSink(format: .markdown | .json)` copies instead of writing,
`JSONFileSink` writes the JSON store the MCP bridge reads, and `MultiSink` fans
out to several.

```swift
Annotation.install(sink: ClipboardSink(format: .json))
```

### 4. Seed identifiers where it matters

Selectors anchor to the nearest `accessibilityIdentifier`
(`#Settings.Models >> @Save`). Views with no identifier anywhere above them
still get a resolvable selector, but it is built from roles and indices and is
fragile across layout changes. Put `.accessibilityIdentifier("Settings.Models")`
on the components you expect to annotate and the notes will point an agent
straight at that code.

### Optional: world context

Register a **world-context provider** and every captured note snapshots it, so an
agent can put back the world the note was made in instead of guessing:

```swift
Annotation.install(
    context: { ["persona": currentPersona, "appearance": appearanceName] }
)
```

### Then use it

Press **Annotate** on the floating pill, click a control (or switch to the frame
tool and drag around a card), type a note, and save. Export writes every pending
note through the sink. Run `swift run AnnotKitDemo` in this repo to try the whole
loop in a sample app first.

## How it works

- **macOS** queries the app's own accessibility tree (the only strategy that
  surfaces SwiftUI `accessibilityIdentifier` values); **iOS** walks the UIView
  hierarchy. Both resolve a tap with the same rule: the **deepest actionable
  control** wins (a click inside a button binds to the button, not its label
  glyph), else the **deepest meaningful element** (a standalone text/label/value
  leaf is annotated in its own right). The generated selector then **anchors** a
  non-identified target to its nearest seeded `accessibilityIdentifier`
  (`#Settings.Models >> @Save`), so it round-trips a resolver and points an agent
  at the right component's code. See `DECISIONS.md`.
- **Drawing a frame** instead of clicking inverts that rule on purpose: a click
  means "this exact spot" and descends, while a box drawn around a card means "I
  mean this *whole* thing", so the **largest** element the frame surrounds wins
  and the labels inside it do not. A frame drawn *inside* something binds to the
  tightest element enclosing it, and the drawn rect rides along on the note.
  Saves hunting for the one pixel that hit-tests to a composite component.
- Notes are written in the `ANNOTKIT_NOTES.md` format that the
  `process-agentation-notes` skill consumes, or copied to the clipboard. The
  file is rewritten with the full set of notes on every export, so it never
  holds duplicates or stale entries. A screenshot of the element is captured
  in memory on request (`AnnotationSession.screenshotSelected()`) but is not
  part of the exported note; the markdown and JSON carry only pixel
  dimensions.
- **Platform coverage is uneven.** The selector engine, target rules, session
  and sinks are shared and unit-tested on both platforms, and CI cross-compiles
  for the iOS simulator. The live macOS path is additionally exercised by
  on-device probes and an end-to-end test; the iOS adapter's live behaviour is
  covered by unit tests over the pure rules only. See `PARITY.md` for the
  per-capability matrix.

## Agent bridge (optional)

Write notes as JSON (`JSONFileSink`) and run the MCP server so an agent can query
pending annotations over the Model Context Protocol:

```sh
swift run annotkit-mcp path/to/ANNOTKIT_NOTES.json
```

Tools: `annotation_get_pending`, `annotation_resolve`.

## Multi-instance hosts

A host that launches many isolated instances of one binary — a design loop with an
HMR session per branch, a gallery, an inspect window per persona — configures each
of them from the launch environment alone, with no change to the app's call site:

```sh
ANNOTKIT_NOTES_MD=$WORLD/notes.md \
ANNOTKIT_NOTES=$WORLD/notes.json \
ANNOTKIT_EVENTS=$WORLD/events.jsonl \
ANNOTKIT_CONTEXT_PERSONA=ada \
  ./MyApp
```

`ANNOTKIT_EVENTS` adds an append-only JSONL log beside the snapshot — one line per
capture, edit and delete — because the snapshot itself is written atomically and
so cannot be followed with `tail -f`. An agent watches the stream and reads the
snapshot the line names:

```sh
tail -F "$WORLD/events.jsonl" | while read -r line; do … done
```

Full contract, including how launcher context and the in-app provider merge:
[`docs/embedding.md`](docs/embedding.md).

## Build

```sh
swift build
swift test
swift run AnnotKitProbe     # live macOS smoke test
swift run AnnotKitDemo      # interactive demo app (overlay mounted; good for recordings)
swift run AnnotKitEnvProbe  # one env-configured embedding host, driven in code
```

Swift 6 (strict concurrency), macOS 15+, iOS 17+. Cross-compile for the iOS
simulator with the command in `CONTRIBUTING.md`.

## License

MIT. See `LICENSE`. The note format is a clean-room reimplementation of
Agentation's `AGENTATION_NOTES.md`, written to `ANNOTKIT_NOTES.md`; this
project contains no Agentation source.
