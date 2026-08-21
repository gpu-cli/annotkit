import { Section } from "../components/Section";
import { Figure } from "../components/Figure";
import { TermList } from "../components/TermList";
import { annotate } from "../copy";
import { annotateClick } from "../captures";

/**
 * §02 — the targeting rules, with the click capture beside them. The loop
 * lives in the hero; one still here is enough to show the chip and the
 * composer that the rules produce. The still takes the narrow track: it is
 * nearly square, and on the wide one it outran the three rules by half its
 * own height.
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
      <div className="section__body section__body--5-7">
        <Figure capture={annotateClick} />
        <TermList terms={annotate.points} />
      </div>
    </Section>
  );
}
