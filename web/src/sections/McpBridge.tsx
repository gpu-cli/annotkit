import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { mcpBridge } from "../copy";

/** §04 — the optional MCP bridge and its two tools. */
export function McpBridge() {
  return (
    <Section
      id="mcp"
      number={mcpBridge.number}
      title={mcpBridge.title}
      lead={mcpBridge.lead}
    >
      <div className="section__body section__body--7-5">
        <CodeBlock
          caption={mcpBridge.command.caption}
          code={mcpBridge.command.code}
          language="sh"
        />
        <ul className="sink-list">
          {mcpBridge.tools.map((tool) => (
            <li key={tool.term}>
              <dfn>{tool.term}</dfn>
              <p>{tool.body}</p>
            </li>
          ))}
        </ul>
      </div>
    </Section>
  );
}
