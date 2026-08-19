# AnnotKit

Native in-app annotation for AI coding agents. Click a UI element in your own
macOS or iOS app — or drag a frame around it — attach a note, and emit an
agent-readable, code-locating annotation. The native analogue of the web
Agentation tool.

The gesture becomes a stable selector, an element path, a screenshot, and your
comment, so an AI coding agent can locate the exact view instead of guessing
from a verbal description.

## Install

Add the package, then mount the toolbar (dev builds only).

```swift
import AnnotKit

#if DEBUG
Annotation.install()   // floating toolbar; click a view, type a note
#endif
```

SwiftUI iOS hosts can attach it to a view instead:

```swift
ContentView()
    #if DEBUG
    .installAnnotation()
    #endif
```

`install()` defaults to the platform AX/view source and writes notes to
`AGENTATION_NOTES.md`. Pass a different sink to override:

```swift
Annotation.install(sink: ClipboardSink(format: .json))
```

Register a **world-context provider** and every captured note snapshots it, so an
agent can put back the world the note was made in instead of guessing:

```swift
Annotation.install(
    context: { ["persona": currentPersona, "appearance": appearanceName] }
)
```

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
- Notes are written in the `AGENTATION_NOTES.md` format that the
  `process-agentation-notes` skill consumes, or copied to the clipboard.

## Agent bridge (optional)

Write notes as JSON (`JSONFileSink`) and run the MCP server so an agent can query
pending annotations over the Model Context Protocol:

```sh
swift run annotkit-mcp path/to/AGENTATION_NOTES.json
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

Swift 6 (strict concurrency), macOS 15+, iOS 17+.

## License

MIT. See `LICENSE`. Reuses the `AGENTATION_NOTES.md` file format (reimplemented
clean-room); contains no Agentation source.
