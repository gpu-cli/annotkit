import { Section } from "../components/Section";
import { Figure } from "../components/Figure";
import { TermList } from "../components/TermList";
import { annotate } from "../copy";
import { annotateLoop, annotatePin } from "../captures";

/**
 * §02 — the targeting rules, led by the one moving figure on the page.
 * The loop sits directly under the hero fold; the still supports the rules.
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
          <Figure capture={annotatePin} />
          <TermList terms={annotate.points} />
        </div>
      </div>
    </Section>
  );
}
