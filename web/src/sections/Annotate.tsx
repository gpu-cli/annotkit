import { Section } from "../components/Section";
import { Figure } from "../components/Figure";
import { TermList } from "../components/TermList";
import { annotate } from "../copy";
import { annotateClick, annotateFrame, annotateLoop } from "../captures";

/**
 * §02 — the targeting rules and the captures that show them.
 *
 * The loop takes the wide track with the three rules beside it, so the first
 * moving figure on the page does not run the full measure and the rules are
 * read while it plays. The two stills, a click and a frame, sit as a pair
 * under it: same height, same frame, one rule each.
 */
export function Annotate() {
  return (
    <Section
      id="annotate"
      number={annotate.number}
      title={annotate.title}
      lead={annotate.lead}
      modifier="section--annotate"
    >
      <div className="stack stack--xl">
        <div className="section__body section__body--7-5">
          <Figure capture={annotateLoop} />
          <TermList terms={annotate.points} />
        </div>
        <div className="section__body section__body--6-6">
          <Figure capture={annotateClick} />
          <Figure capture={annotateFrame} />
        </div>
      </div>
    </Section>
  );
}
