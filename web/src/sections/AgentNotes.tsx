import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { Figure } from "../components/Figure";
import { TermList } from "../components/TermList";
import { agentNotes } from "../copy";
import { notesPins } from "../captures";

/** §03 — the note format, the sinks, and the file a real run produced. */
export function AgentNotes() {
  return (
    <Section
      id="notes"
      number={agentNotes.number}
      title={agentNotes.title}
      lead={agentNotes.lead}
    >
      <div className="section__body section__body--7-5">
        <div className="stack stack--lg">
          <CodeBlock {...agentNotes.sample} />
          <Figure capture={notesPins} />
        </div>
        <TermList terms={agentNotes.sinks} />
      </div>
    </Section>
  );
}
