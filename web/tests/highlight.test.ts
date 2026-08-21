import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createHighlighter, type Highlighter } from "shiki";
import { render } from "../plugins/highlight";
import { theme } from "../plugins/theme";
import { agentNotes, install, mcpBridge, snippets } from "../src/copy";

/**
 * The build-time highlighter, against the real grammars. These pin the roles
 * a Swift reader expects (Xcode's), so a grammar or Shiki upgrade that
 * reshuffles scopes fails here rather than on the page.
 */

let hl: Highlighter;
beforeAll(async () => {
  hl = await createHighlighter({ themes: [theme], langs: ["swift", "markdown", "sh"] });
});
afterAll(() => hl.dispose());

const colour = (html: string, text: string) => {
  const m = html.match(new RegExp(`<span style="color:([^"]+)">${text}</span>`));
  return m?.[1];
};
const text = (html: string) =>
  html
    .replace(/<br>/g, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&amp;/g, "&");

describe("the highlighter", () => {
  it("gives back every snippet's text unchanged", () => {
    for (const s of snippets) expect(text(render(hl, s))).toBe(s.code);
  });

  it("never lets a placeholder hex reach the page", () => {
    for (const s of snippets) expect(render(hl, s)).not.toMatch(/#00000[0-9]/);
  });

  it("reads Swift the way Xcode does", () => {
    const html = render(hl, install.appKit);
    expect(colour(html, "import")).toBe("var(--color-accent)");
    expect(colour(html, "#if")).toBe("var(--color-accent)");
    expect(colour(html, " AnnotKit")).toBe("var(--color-syntax-type)");
    expect(colour(html, " DEBUG")).toBe("var(--color-ink)");
    expect(colour(html, "Annotation")).toBe("var(--color-syntax-type)");
    expect(colour(html, ".install\\(\\)   ")).toBe("var(--color-ink)");
    expect(html).toMatch(/color:var\(--color-muted\)">\/\/ floating/);

    const sink = render(hl, install.sink);
    expect(colour(sink, "ClipboardSink")).toBe("var(--color-syntax-type)");
    expect(colour(sink, "\\.install\\(sink: ")).toBe("var(--color-ink)");
    expect(colour(sink, "\\(format: \\.json\\)\\)")).toBe("var(--color-ink)");

    const view = render(hl, install.swiftUI);
    expect(colour(view, "ContentView")).toBe("var(--color-syntax-type)");
    expect(colour(view, "    \\.installAnnotation\\(\\)")).toBe("var(--color-ink)");
  });

  it("sets the note block's heading and labels as labels", () => {
    const html = render(hl, agentNotes.sample);
    expect(html).toMatch(/color:var\(--color-accent\);font-weight:bold">## \[/);
    expect(html).toMatch(/color:var\(--color-ink\);font-weight:bold">\*\*Timestamp\*\*/);
  });

  it("treats a shell argument as a word, not a string", () => {
    const html = render(hl, mcpBridge.command);
    expect(colour(html, "swift")).toBe("var(--color-accent)");
    expect(colour(html, " run")).toBe("var(--color-ink)");
    expect(colour(html, " path/to/ANNOTKIT_NOTES.json")).toBe("var(--color-ink)");
  });
});
