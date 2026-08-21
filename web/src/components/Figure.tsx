import type { Capture } from "../captures";
import { usePrefersReducedMotion } from "../hooks";
import { withCode } from "../markup";

/**
 * A capture in a bare frame — a hairline border and a caption, nothing else.
 * No drawn browser chrome, no drawn device frame (Hallmark gate 47).
 *
 * Until L4 records the real captures from `task demo`, a figure renders an
 * honest placeholder: an empty plate that names the shot it is waiting for.
 * A drawn stand-in would be exactly the invented-proof slop the epic's
 * honest-copy rule bans, so this shows the hole instead of filling it.
 */
export function Figure({ capture }: { capture: Capture }) {
  const reducedMotion = usePrefersReducedMotion();

  return (
    <figure className="figure">
      <div className="figure__frame">
        {capture.status === "pending" ? (
          <div className="figure__pending">
            <p className="u-label">Capture pending · L4</p>
            <p>
              <b>{withCode(capture.shot)}</b>
            </p>
            <p>{withCode(capture.direction)}</p>
          </div>
        ) : capture.kind === "loop" ? (
          // Reduced motion gets the poster frame and a control to start it,
          // never an autoplaying loop.
          <video
            src={capture.src}
            poster={capture.poster}
            width={capture.width}
            height={capture.height}
            autoPlay={!reducedMotion}
            loop={!reducedMotion}
            controls={reducedMotion}
            muted
            playsInline
            preload="none"
            aria-label={capture.alt}
          />
        ) : (
          <img
            src={capture.src}
            alt={capture.alt}
            width={capture.width}
            height={capture.height}
            loading={capture.priority ? "eager" : "lazy"}
            fetchPriority={capture.priority ? "high" : undefined}
            decoding="async"
          />
        )}
      </div>
      {/* The build hash stays in the manifest, for whoever re-shoots; it is
       * not printed. A caption is for the reader, and says what to look at. */}
      <figcaption>{withCode(capture.caption)}</figcaption>
    </figure>
  );
}
