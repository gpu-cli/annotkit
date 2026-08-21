/**
 * The figure manifest (epic §5, L4).
 *
 * Each entry is either `pending` — a shot that has not been recorded yet, and
 * that the page renders as a labelled empty plate — or `ready`, pointing at a
 * real file under `public/captures/`.
 *
 * The placeholder's prose fields (`shot`, `direction`) run through the same
 * backtick convention the rest of the copy uses: text between backticks is
 * rendered as `<code>`. See src/markup.tsx. A ready capture has no caption:
 * the prose beside it does that job, and `alt` carries it for a reader who
 * cannot see the frame.
 *
 * To land a capture: record it from `task demo`, drop the file in
 * `public/captures/`, and flip the entry from the pending shape to the ready
 * shape (fill `src`, `alt`, `width`, `height`, and the `buildHash` of the
 * commit the demo was built from). No component changes are needed.
 */

type Base = {
  /** Short commit hash of the build the capture was taken from. Kept for
   * re-shoots; the page does not print it. */
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

/** The stills were shot at this build. */
const HASH = "b5f58cf";
/** The loop predates it: its on-screen help text still names the old notes
 * file, which `b5f58cf` renamed, so it was built from the commit before. */
const LOOP_HASH = "4db8fc6";

/** The hero, right-hand track — the one moving figure on the page. */
export const annotateLoop: Capture = {
  status: "ready",
  kind: "loop",
  src: "/captures/annotate-loop.mp4",
  poster: "/captures/annotate-loop-poster.png",
  alt: "AnnotKitDemo, a dark macOS settings window. Annotate is pressed, a control is clicked, a note is typed into the composer and sent; a numbered pin lands on the control.",
  width: 1274,
  height: 820,
  buildHash: LOOP_HASH,
};

/** §02 support still — a click, the composer, the resolved selector. */
export const annotateClick: Capture = {
  status: "ready",
  kind: "still",
  src: "/captures/annotate-click.png",
  alt: "The demo window after a click on the avatar. A chip above it reads Settings.Profile.Avatar and the composer below holds the note “Change the background color to green”.",
  width: 1428,
  height: 1378,
  buildHash: HASH,
};

/** Not placed. A frame, and what it bound to; kept for a future slot. */
export const annotateFrame: Capture = {
  status: "ready",
  kind: "still",
  src: "/captures/annotate-frame.png",
  alt: "The demo window with a frame drawn around the heading and the Profile card. The composer title reads Frame → Settings… and waits for a note.",
  width: 1498,
  height: 1286,
  buildHash: HASH,
};

/** §03 support still — the notes, pinned in the app, before export. */
export const notesPins: Capture = {
  status: "ready",
  kind: "still",
  src: "/captures/notes-pins.png",
  alt: "The demo window with five numbered blue pins on its controls and the toolbar’s copy button under the pointer, captioned Copy notes (Markdown).",
  width: 1570,
  height: 1350,
  buildHash: HASH,
};
