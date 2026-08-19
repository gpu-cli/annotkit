import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { install } from "../copy";

/** §01 — the two snippets from the README, verbatim. */
export function Install() {
  return (
    <Section id="install" number={install.number} title={install.title} lead={install.lead}>
      <div className="section__body section__body--7-5">
        <div className="stack stack--lg">
          <CodeBlock caption={install.appKit.caption} code={install.appKit.code} />
          <CodeBlock caption={install.swiftUI.caption} code={install.swiftUI.code} />
        </div>
        <div className="stack">
          <p>{install.sinkNote}</p>
          <CodeBlock caption={install.sink.caption} code={install.sink.code} />
        </div>
      </div>
    </Section>
  );
}
