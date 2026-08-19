/**
 * The figure manifest (epic §5, L4).
 *
 * Each entry is either `pending` — a shot that has not been recorded yet, and
 * that the page renders as a labelled empty plate — or `ready`, pointing at a
 * real file under `public/captures/`.
 *
 * To land a capture: record it from `task demo`, drop the file in
 * `public/captures/`, and flip the entry from the pending shape to the ready
 * shape (fill `src`, `alt`, `width`, `height`, and the `buildHash` of the
 * commit the demo was built from). No component changes are needed.
 */

type Base = {
  /** Printed under the frame. Says what the reader is looking at. */
  caption: string;
  /** Short commit hash of the build the capture was taken from. */
  buildHash?: string;
};

type Pending = Base & {
  status: "pending";
  /** One line naming the shot, shown on the placeholder plate. */
  shot: string;
  /** Direction for whoever records it. */
  direction: string;
};

type ReadyStill = Base & {
  status: "ready";
  kind: "still";
  src: string;
  alt: string;
  width: number;
  height: number;
  /** True for the one capture above the fold, if any. */
  priority?: boolean;
};

type ReadyLoop = Base & {
  status: "ready";
  kind: "loop";
  src: string;
  poster: string;
  alt: string;
  width: number;
  height: number;
};

export type Capture = Pending | ReadyStill | ReadyLoop;

/** §02 lead — the one muted webm loop on the page (≤ ~1.5 MB, epic §8.5). */
export const annotateLoop: Capture = {
  status: "pending",
  caption: "AnnotKitDemo — click a control, type a note, note written.",
  shot: "Screen recording · AnnotKitDemo settings screen",
  direction:
    "task demo → click Save → composer opens → type a note → submit. Muted webm, ≤ 1.5 MB, with a poster frame. One loop, no cuts.",
};

/** §02 support still — the pin and the composer, close in. */
export const annotatePin: Capture = {
  status: "pending",
  caption: "The pin and the composer, drawn over the app being annotated.",
  shot: "Still · pin + composer detail",
  direction:
    "task demo → place a pin on Settings.Profile.Save → screenshot the composer with the resolved selector visible.",
};

/** §03 support still — the notes file the run produced. */
export const notesFile: Capture = {
  status: "pending",
  caption: "The AGENTATION_NOTES.md the run above wrote.",
  shot: "Still · AGENTATION_NOTES.md in an editor",
  direction:
    "Open the AGENTATION_NOTES.md written by the demo run and screenshot it. Plain editor, no window chrome in the crop.",
};
