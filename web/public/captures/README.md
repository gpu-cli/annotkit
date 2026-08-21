# Captures

Real recordings from `task demo` (AnnotKitDemo). Nothing drawn, nothing
mocked — Hallmark gate 47 bans re-drawn browser/IDE/window chrome, and the
epic's honest-copy rule (§6.6) bans stand-ins that read as proof.

While a shot is missing, `src/captures.ts` marks it `pending` and the page
renders a labelled empty plate naming the shot. That is deliberate: the hole
is honest, a fake screenshot is not.

## The shots

| File | Where | Notes |
|---|---|---|
| `annotate-loop.mp4` + `annotate-loop-poster.png` | §02 lead | 22 s, muted, H.264, 1274×820, 465 KB. The poster is shown to reduced-motion readers, who get a play control instead of autoplay. |
| `annotate-click.png` | §02 | A click on the avatar: selector chip and composer. |
| `annotate-frame.png` | §02 | A frame around the heading and Profile card, composer waiting. |
| `notes-pins.png` | §03 | Five pins placed, copy button under the pointer. |
| `annotate-hover.png` | unused | The Profile card under hover, chip `Settings.Profile`. Kept for a future slot. |

Stills recorded from `task demo` at `b5f58cf`; the loop at `4db8fc6` (its help text still says `AGENTATION_NOTES.md`, so re-shoot it when convenient). The stills are PNG at 2×; re-encode
to AVIF/WebP if the page's weight budget ever needs it (`Figure` takes a single
`src`, so swap the path).

## Landing a capture

1. `task demo`, record the shot.
2. Drop the file(s) here.
3. In `src/captures.ts`, flip the entry from the `pending` shape to the
   `ready` shape: `src`, `alt`, `width`, `height`, and `buildHash` — the short
   commit the demo was built from. The caption prints it as
   `· captured at <hash>` so a stale capture is visible, not invisible.

Re-capturing is a 15-minute task; the demo app exists for exactly this. When
the overlay UI changes, re-shoot rather than letting the page drift.
