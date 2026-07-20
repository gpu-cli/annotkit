# macOS / iOS parity matrix (F0.4)

Authored before the iOS path (F5) is built, per the cli repo's
`.claude/checklists/parallel-path-parity.md`. Every observable capability has a
row; each asymmetry is closed by code or has a tracked mitigation.

| Capability | macOS adapter | iOS adapter | Asymmetry / mitigation |
|---|---|---|---|
| Default element source | AX hierarchy (own pid) | UIView tree (clean-room walk) | iOS defaults to the view-tree walk; it still surfaces SwiftUI `accessibilityIdentifier` (set on the backing UIView), so a separate AX source is not needed |
| Opt-in element source | NSView tree | (the default already walks the view tree) | macOS adds a view-tree opt-in alongside its AX default; iOS only needs the one source |
| `accessibilityIdentifier` | via AX | via `UIView.accessibilityIdentifier` | both surface SwiftUI identifiers |
| Concrete view class name | via NSView opt-in source | via the default UIView walk | none |
| Hit test primitive | `AXUIElementCopyElementAtPosition` + NSView `hitTest` | `UIView.hitTest(_:with:)` | iOS has no global AX point query; uses view hitTest. Tracked: F5.2 |
| Annotation target rule | shared `AnnotationTargetRule` over an AX candidate chain | shared `AnnotationTargetRule` over a UIView candidate chain | none — both build a `[TargetCandidate]` chain and apply the SAME rule (deepest actionable, else deepest meaningful). Closes the earlier split (macOS "deepest meaningful" vs iOS "nearest identified"), cli-got28.2 |
| Component widening | `ComponentLadderSource` (AX chain) | `ComponentLadderSource` (UIView chain) | none — same ladder (target, then enclosing identified components) |
| Coordinate space | Cocoa bottom-left to AX top-left flip | UIKit top-left native | iOS needs no flip; shared `ScreenSpace` used only on macOS |
| Screenshot | ScreenCaptureKit / `cacheDisplay` | `UIGraphicsImageRenderer` + `drawHierarchy` | both capture own hierarchy only; no cross-window or secure overlays |
| Overlay host | resizing `NSPanel` (toolbar corner idle, full screen annotating) | pass-through `UIWindow` | both interactive; selection via the shared SwiftUI catcher, not a global monitor |
| Overlay AX-exclusion | mark window non-accessibility | mark window non-accessibility | none |
| Selected-text capture | responder / `NSText` | `UIResponder` / `UITextInput` | symmetric concept |
| Install API | `Annotation.install()` + SwiftUI modifier | same | none |
| Sinks (file / clipboard / MCP) | shared | shared | none |
| Mac Catalyst | n/a | builds as the iOS path (`os(iOS)` true) | AppKit-only pieces do not apply; UIKit adapter's concern |

Selector generation, the selector engine, and the note/sink layer are
platform-independent and shared (see `Sources/AnnotKit`).
