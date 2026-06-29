# AnnotKit

Native in-app annotation for AI coding agents. Click a UI element in your own
macOS or iOS app, attach a note, and emit an agent-readable, code-locating
annotation. The native analogue of the web Agentation tool.

```swift
import AnnotKit

#if DEBUG
Annotation.install()   // floating toolbar; click a view, type a note
#endif
```

A click becomes a stable selector, an element path, a screenshot, and your
comment, so an AI coding agent can locate the exact view instead of guessing
from a verbal description.

## Status

Early development, built phase by phase against a planned, reviewed spec.

- F0 (this commit): public API surface, the SwiftPM package (Swift 6, macOS 15 /
  iOS 17), and the platform-independent core: the selector engine
  (parse / generate / resolve, round-tripping by construction) and the
  AX-to-Cocoa coordinate conversion, both unit-tested.
- Next: the macOS accessibility adapter (hit-test, selector generation,
  capture), the annotation overlay, and the output sinks.

See `DECISIONS.md`, `PARITY.md`, and `docs/` for the design.

## Build

```sh
swift build
swift test
```

## License

MIT. See `LICENSE`. Reuses the `AGENTATION_NOTES.md` file format (reimplemented
clean-room); does not include any Agentation source.
