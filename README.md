# AnnotKit

Native in-app annotation for AI coding agents. Click a UI element in your own
macOS or iOS app, attach a note, and emit an agent-readable, code-locating
annotation. The native analogue of the web Agentation tool.

A click becomes a stable selector, an element path, a screenshot, and your
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
- Notes are written in the `AGENTATION_NOTES.md` format that the
  `process-agentation-notes` skill consumes, or copied to the clipboard.

## Agent bridge (optional)

Write notes as JSON (`JSONFileSink`) and run the MCP server so an agent can query
pending annotations over the Model Context Protocol:

```sh
swift run annotkit-mcp path/to/AGENTATION_NOTES.json
```

Tools: `annotation_get_pending`, `annotation_resolve`.

## Build

```sh
swift build
swift test
swift run AnnotKitProbe   # live macOS smoke test
```

Swift 6 (strict concurrency), macOS 15+, iOS 17+.

## License

MIT. See `LICENSE`. Reuses the `AGENTATION_NOTES.md` file format (reimplemented
clean-room); contains no Agentation source.
