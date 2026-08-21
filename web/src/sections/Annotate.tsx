import { Section } from "../components/Section";
import { Figure } from "../components/Figure";
import { TermList } from "../components/TermList";
import { annotate } from "../copy";
import { annotateClick, annotateFrame, annotateLoop } from "../captures";

/**
 * §02 — the targeting rules, led by the one moving figure on the page.
 * The loop sits directly under the hero fold; the two stills, a click and a
 * frame, stand beside the rules they illustrate.
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
      <div className="stack stack--lg">
        <Figure capture={annotateLoop} />
        <div className="section__body section__body--5-7">
          <div className="stack stack--lg">
            <Figure capture={annotateClick} />
            <Figure capture={annotateFrame} />
          </div>
          <TermList terms={annotate.points} />
        </div>
      </div>
    </Section>
  );
}
