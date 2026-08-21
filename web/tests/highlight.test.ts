import { describe, expect, it } from "vitest";
import { tokenize } from "../src/highlight";
import { agentNotes, install, mcpBridge } from "../src/copy";

const snippets = [
  ["swift", install.appKit.code],
  ["swift", install.swiftUI.code],
  ["swift", install.sink.code],
  ["markdown", agentNotes.sample.code],
  ["sh", mcpBridge.command.code],
] as const;

describe("the highlighter", () => {
  it("gives back every snippet byte for byte", () => {
    for (const [language, code] of snippets) {
      expect(tokenize(code, language).map((t) => t.text).join("")).toBe(code);
    }
  });

  it("leaves an unknown language alone", () => {
    expect(tokenize("anything", "cobol")).toEqual([{ kind: "plain", text: "anything" }]);
  });

  it("reads the Swift it is given", () => {
    const kinds = Object.fromEntries(
      tokenize(install.appKit.code, "swift").map((t) => [t.text.trim(), t.kind]),
    );
    expect(kinds["import"]).toBe("keyword");
    expect(kinds["#if"]).toBe("keyword");
    expect(kinds["AnnotKit"]).toBe("type");
    expect(kinds["DEBUG"]).toBe("plain");
    expect(kinds["// floating toolbar; click a view, type a note"]).toBe("comment");
  });

  it("reads the note block", () => {
    const tokens = tokenize(agentNotes.sample.code, "markdown");
    expect(tokens[0]?.kind).toBe("heading");
    expect(tokens.some((t) => t.kind === "field" && t.text === "**Timestamp**:")).toBe(true);
    expect(tokens.some((t) => t.kind === "string" && t.text === '"Save"')).toBe(true);
  });
});
