# AnnotKit foundation decisions (F0)

Resolves the open decisions from the plan (planning/annotkit in the cli repo). Provisional items are cheap to change before the public release.

| Decision | Choice | Notes |
|---|---|---|
| Name | AnnotKit (provisional) | Trademark check required before public release. Distinct from Agentation (PolyForm, brand). |
| License | MIT | Maximises adoption. See LICENSE. |
| Repo location | Standalone repo at `~/Development/annotkit` | VirgilHUD consumes it during dev via a local SwiftPM path dependency; public remote created by the maintainer. |
| Versioning | SemVer, 0.x pre-1.0 | Breaking changes allowed while 0.x; 1.0 marks a stable public API. |
| Default element source | Accessibility hierarchy | The only strategy that surfaces SwiftUI `accessibilityIdentifier` values. |
| Opt-in element source | View tree (NSView/UIView) | Surfaces concrete view class names; richer for AppKit/UIKit hosts. Collapses to hosting views in pure SwiftUI. |
| `pathname` mapping | Host-supplied route, inferred fallback | A native app has no URL routes; the host sets a route, else infer from the key window title or identifier. |
| Overlay coverage | Per window | One overlay per target window; multi-display handled by per-window placement. (Per-screen reconsidered if multi-window proves awkward.) |
| Dev-only gating | `#if DEBUG` default + env override | On in DEBUG unless `ANNOTKIT_DISABLE`; off in release unless `ANNOTKIT_ENABLE`. Mirrors VirgilHUD `InspectMode`. |
| Concurrency | Swift 6 language mode, strict | Public `Element`/`CapturedImage`/`AnnotationNote` are `Sendable`; `ElementSource`/`Annotation` are `@MainActor`. |

## IP hygiene (carried into the F7 legal gate)

- Do not copy original Agentation source (PolyForm Shield 1.0.0, non-compete). Only the `AGENTATION_NOTES.md` file format is reused, reimplemented clean-room.
- The `swift-agentation` iOS data sources (MIT) may be vendored in F5 with their license and attribution preserved.
