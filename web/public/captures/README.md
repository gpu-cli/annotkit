# Captures

Real recordings from `task demo` (AnnotKitDemo). Nothing drawn, nothing
mocked — Hallmark gate 47 bans re-drawn browser/IDE/window chrome, and the
epic's honest-copy rule (§6.6) bans stand-ins that read as proof.

While a shot is missing, `src/captures.ts` marks it `pending` and the page
renders a labelled empty plate naming the shot. That is deliberate: the hole
is honest, a fake screenshot is not.

## The shot list (L4)

| File | Shot | Notes |
|---|---|---|
| `annotate-loop.webm` + `annotate-loop.png` | §02 lead — click a control, composer opens, note submitted | Muted, ≤ ~1.5 MB, one take, no cuts. The `.png` is the poster frame. |
| `annotate-pin.avif` / `.webp` / `.png` | §02 — pin + composer detail, resolved selector visible | Crop tight; no window chrome in frame. |
| `agentation-notes.avif` / `.webp` / `.png` | §03 — the `AGENTATION_NOTES.md` the run wrote | Plain editor, no chrome in the crop. |

## Landing a capture

1. `task demo`, record the shot.
2. Drop the file(s) here.
3. In `src/captures.ts`, flip the entry from the `pending` shape to the
   `ready` shape: `src`, `alt`, `width`, `height`, and `buildHash` — the short
   commit the demo was built from. The caption prints it as
   `· captured at <hash>` so a stale capture is visible, not invisible.

Re-capturing is a 15-minute task; the demo app exists for exactly this. When
the overlay UI changes, re-shoot rather than letting the page drift.
