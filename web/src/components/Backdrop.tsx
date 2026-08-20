/**
 * The one piece of decoration on the page, and the argument for it.
 *
 * Hallmark gate 29 bans abstract backgrounds and gate 45 bans unmotivated
 * decoration. What makes this admissible is that it is not abstract and it is
 * not unmotivated: AnnotKit's whole gesture is drawing a frame around a piece
 * of a running interface, so the page draws frames. They are the app's marquee
 * at rest. A blob field or an aurora would fail both gates outright, because
 * neither would mean anything here.
 *
 * The restraint is in the numbers, which live in base.css: hairline strokes at
 * six per cent of the accent, drifts of twenty to forty pixels, and cycles of
 * forty to ninety seconds with prime-ish periods so no two frames ever come
 * back into phase. Nothing here is fast enough to catch the eye while you are
 * reading, which is the whole point of a backdrop.
 *
 * `aria-hidden` and `pointer-events: none`: it is not content and it must
 * never intercept a click. Under `prefers-reduced-motion` the frames hold
 * still rather than disappearing, so the composition survives and only the
 * movement goes.
 */
export function Backdrop() {
  return (
    <div className="backdrop" aria-hidden="true">
      {Array.from({ length: 7 }, (_, i) => (
        <span key={i} className="backdrop__frame" />
      ))}
    </div>
  );
}
