import { useRef, type ReactNode } from "react";
import { useDrawOnce } from "../hooks";
import { withCode } from "../markup";

/**
 * The section shell.
 *
 * The numbered label sits DIRECTLY ABOVE the heading, in one column. The
 * Specimen macrostructure historically hangs that label in a left margin;
 * Hallmark gate 54 bans the tag-left / heading-right head outright and is
 * authoritative over the macrostructure's own sketch. The numbering survives,
 * the two-column head does not.
 */
export function Section({
  id,
  number,
  title,
  lead,
  modifier,
  children,
}: {
  id: string;
  number: string;
  title: string;
  lead?: string;
  modifier?: string;
  children: ReactNode;
}) {
  const ruleRef = useRef<HTMLHRElement>(null);
  useDrawOnce(ruleRef);

  return (
    <section id={id} className={modifier ? `section ${modifier}` : "section"}>
      <div className="u-shell">
        <hr className="u-rule draw section__rule" ref={ruleRef} aria-hidden="true" />
        <header className="section__head">
          <p className="u-label section__number">{number}</p>
          <h2 className="section__title">{title}</h2>
          {lead ? <p className="section__lead">{withCode(lead)}</p> : null}
        </header>
        {children}
      </div>
    </section>
  );
}
