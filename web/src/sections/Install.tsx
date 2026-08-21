import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { install } from "../copy";
import { withCode } from "../markup";

/** §01 — the two snippets from the README, verbatim. */
export function Install() {
  return (
    <Section
      id="install"
      number={install.number}
      title={install.title}
      lead={install.lead}
      modifier="section--install"
    >
      <div className="section__body section__body--7-5">
        <div className="stack stack--lg">
          <CodeBlock {...install.appKit} />
          <CodeBlock {...install.swiftUI} />
        </div>
        <div className="stack">
          <p>{withCode(install.sinkNote)}</p>
          <CodeBlock {...install.sink} />
        </div>
      </div>
    </Section>
  );
}
