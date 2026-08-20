# Contributing to AnnotKit

Thanks for your interest. AnnotKit is an early-stage, MIT-licensed Swift package.

## Build and test

```sh
swift build
swift test

# Cross-compile for the iOS simulator
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --sdk "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios17.0-simulator

# Live macOS smoke test of the AX adapter + overlay
swift run AnnotKitProbe
```

The package builds under Swift 6 strict concurrency and must stay warning-free
(`swift build -Xswiftc -warnings-as-errors`).

## Conventions

- Public, platform-independent logic (selector engine, formatter, session) lives
  in the cross-platform sources and is unit-tested.
- Platform code is guarded by `#if os(macOS)` / `#if os(iOS)` and shares the
  `ElementSource` and `AnnotationSink` protocols.
- No em dashes in prose.
- Do not add any code derived from the PolyForm-licensed Agentation project. Only
  the shape of Agentation's `AGENTATION_NOTES.md` format is reused, reimplemented
  independently and written to our own `ANNOTKIT_NOTES.md`.

## Scope

See `DECISIONS.md`, `PARITY.md`, and `docs/` for the design and the resolved
decisions. Keep changes surgical and aligned with that design.
