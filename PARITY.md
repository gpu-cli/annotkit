# macOS / iOS parity matrix (F0.4)

Authored before the iOS path (F5) is built, per the cli repo's
`.claude/checklists/parallel-path-parity.md`. Every observable capability has a
row; each asymmetry is closed by code or has a tracked mitigation.

| Capability | macOS adapter | iOS adapter | Asymmetry / mitigation |
|---|---|---|---|
| Default element source | AX hierarchy (own pid) | AX hierarchy | none |
| Opt-in element source | NSView tree | UIView tree + `.agentationTag()` | symmetric concept, platform views differ |
| `accessibilityIdentifier` | via AX | via AX | none |
| Concrete view class name | via NSView opt-in source | via UIView opt-in source | none |
| Hit test | `AXUIElementCopyElementAtPosition` + NSView `hitTest` | `UIView.hitTest(_:with:)` | iOS has no global AX point query; uses view hitTest. Tracked: F5.2 |
| Coordinate space | Cocoa bottom-left to AX top-left flip | UIKit top-left native | iOS needs no flip; shared `ScreenSpace` used only on macOS |
| Screenshot | ScreenCaptureKit / `cacheDisplay` | `UIGraphicsImageRenderer` + `drawHierarchy` | both capture own hierarchy only; no cross-window or secure overlays |
| Overlay host | borderless `NSWindow`/`NSPanel` | transparent `UIWindow` | shared SwiftUI overlay behind a window-host seam |
| Overlay AX-exclusion | mark window non-accessibility | mark window non-accessibility | none |
| Selected-text capture | responder / `NSText` | `UIResponder` / `UITextInput` | symmetric concept |
| Install API | `Annotation.install()` + SwiftUI modifier | same | none |
| Sinks (file / clipboard / MCP) | shared | shared | none |
| Mac Catalyst | n/a | builds as the iOS path (`os(iOS)` true) | AppKit-only pieces do not apply; UIKit adapter's concern |

Selector generation, the selector engine, and the note/sink layer are
platform-independent and shared (see `Sources/AnnotKit`).
