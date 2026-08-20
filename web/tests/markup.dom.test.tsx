import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { App } from "../src/App";
import { withCode } from "../src/markup";
import { agentNotes, codeBlock, install, masthead, theme } from "../src/copy";

/**
 * The backtick convention and what it renders to.
 *
 * copy.ts is a file of plain strings by design, so the only thing marking
 * `ANNOTKIT_NOTES.md` as machine text rather than a shouted noun is a pair of
 * backticks. That makes the convention load-bearing: an unbalanced pair, or a
 * component that forgets to run its copy through `withCode`, prints the
 * backticks to the page as literal characters.
 */

afterEach(cleanup);

describe("withCode", () => {
  it("leaves a line with no machine text exactly as it was", () => {
    expect(withCode("Add the package. Mount the toolbar.")).toBe(
      "Add the package. Mount the toolbar.",
    );
  });

  it("sets a backticked run as code and the rest as prose", () => {
    const { container } = render(<p>{withCode("Notes land in `ANNOTKIT_NOTES.md`, one block.")}</p>);
    const marks = [...container.querySelectorAll("code")];

    expect(marks.map((mark) => mark.textContent)).toEqual(["ANNOTKIT_NOTES.md"]);
    expect(container.textContent).toBe("Notes land in ANNOTKIT_NOTES.md, one block.");
  });

  it("marks every run on a line, not only the first", () => {
    const { container } = render(<p>{withCode(install.sinkNote)}</p>);

    expect([...container.querySelectorAll("code")].map((mark) => mark.textContent)).toEqual([
      "install()",
      "ANNOTKIT_NOTES.md",
    ]);
  });

  it("prints an unpaired backtick rather than swallowing the rest of the line", () => {
    const { container } = render(<p>{withCode("a `b c")}</p>);

    expect(container.querySelector("code")).toBeNull();
    expect(container.textContent).toBe("a `b c");
  });
});

describe("the convention, across every string the page ships", () => {
  it("closes every backtick it opens", async () => {
    const copy: Record<string, unknown> = await import("../src/copy");
    const captures: Record<string, unknown> = await import("../src/captures");

    const strings: string[] = [];
    const walk = (value: unknown) => {
      if (typeof value === "string") strings.push(value);
      else if (Array.isArray(value)) value.forEach(walk);
      else if (value && typeof value === "object") Object.values(value).forEach(walk);
    };
    walk(copy);
    walk(captures);

    for (const value of strings) {
      // Code samples are fenced by the block, not by backticks, and a Swift
      // or markdown snippet may legitimately contain one.
      if (/\n/.test(value)) continue;
      const ticks = (value.match(/`/g) ?? []).length;
      expect(ticks % 2, value).toBe(0);
    }
  });

  it("prints no backtick anywhere on the rendered page", () => {
    const { container } = render(<App />);

    // Every `<code>` the page draws came from a pair that was consumed; a
    // literal backtick in the output means one was missed.
    expect(container.textContent).not.toMatch(/`/);
    expect(container.querySelectorAll("code").length).toBeGreaterThan(8);
  });

  it("runs the copy that carries machine text through the renderer", () => {
    render(<App />);
    const marked = [...document.querySelectorAll("code")].map((node) => node.textContent);

    // One from a section lead, one from a term body, one from a code-block
    // caption, one from a figure — the four call sites, spot-checked.
    expect(marked).toContain("accessibilityIdentifier");
    expect(marked).toContain("JSONFileSink");
    expect(marked).toContain("AnnotationFormatter");
    expect(marked).toContain("task demo");
  });
});

describe("icons", () => {
  it("draws every icon as an SVG the a11y tree cannot see", () => {
    const { container } = render(<App />);
    const icons = [...container.querySelectorAll("svg")];

    expect(icons.length).toBeGreaterThanOrEqual(5);
    for (const icon of icons) {
      expect(icon.getAttribute("aria-hidden")).toBe("true");
      expect(icon.getAttribute("focusable")).toBe("false");
      // Every icon carries the one class that sizes it. A Lucide component
      // called directly — bypassing Icon.tsx — would not, and would ship at
      // the library's 24 px / stroke-2 default.
      // `contains`, not equality: Lucide prepends its own `lucide lucide-<name>`
      // classes ahead of whatever the caller passes.
      expect(icon.classList.contains("icon")).toBe(true);
      expect(icon.getAttribute("stroke-width")).toBe("1.5");
    }
  });

  it("ships no arrow or tick left as a text character", () => {
    const { container } = render(<App />);

    // These were ↗ and ↓ in the markup and inside two copy strings. A glyph
    // that comes back as text is one that stopped matching Lucide's weight.
    expect(container.textContent).not.toMatch(/[↗↘↙↖↓↑✓✗×]/);
  });

  it("keeps the masthead links' accessible names free of the icon", () => {
    render(<App />);
    const nav = screen.getByRole("navigation", { name: /primary/i });

    expect(screen.getByRole("link", { name: masthead.links.updates })).toBeTruthy();
    expect(nav.textContent).toBe(`${masthead.links.github}${masthead.links.updates}`);
  });
});

describe("the copy button, now that it is a bare glyph", () => {
  it("names itself for a screen reader instead of showing a label", () => {
    render(<App />);
    const button = screen.getByRole("button", {
      name: codeBlock.copyLabel(agentNotes.sample.caption),
    });

    // Nothing visible but the icon: a label would be a second copy of a name
    // the button already carries.
    expect(button.textContent).toBe("");
    expect(button.querySelector("svg")).not.toBeNull();
  });

  it("keeps a live region for the outcome, since the glyph cannot be read", () => {
    const { container } = render(<App />);

    expect(container.querySelectorAll('[role="status"]').length).toBeGreaterThanOrEqual(
      container.querySelectorAll("button.copy").length,
    );
  });
});

/**
 * Matched against the exported copy rather than a regex. The first version of
 * these tests hard-coded /switch to the .* theme/i and broke the moment the
 * wording changed — which is the wrong failure: the name is allowed to change,
 * it just has to stay the name the component was given.
 */
const findToggle = () =>
  screen.getByRole("button", {
    name: (name) => name === theme.switchTo.dark || name === theme.switchTo.light,
  });

describe("the theme control", () => {
  it("sits inside the masthead rather than in a row of its own", () => {
    const { container } = render(<App />);

    expect(findToggle().closest("header.mast")).not.toBeNull();
    expect(container.querySelector(".corner")).toBeNull();
  });

  it("stays out of the Primary landmark, which lists places to go", () => {
    render(<App />);

    expect(findToggle().closest("nav")).toBeNull();
  });

  it("renders both mode words, so flipping cannot change the row's width", () => {
    render(<App />);
    const words = [...findToggle().querySelectorAll(".theme__word")].map((w) => w.textContent);

    // Both are in the DOM at once and the cell sizes to the wider; only one
    // is visible. Rendering just the active word would move the rule under
    // it, because "Light Mode" is a character longer than "Dark Mode".
    expect(words).toEqual([theme.mode.dark, theme.mode.light]);
    expect(findToggle().querySelectorAll(".theme__word[data-shown]")).toHaveLength(1);
  });

  it("keeps the visible word inside the accessible name (WCAG 2.5.3)", () => {
    render(<App />);
    const shown = findToggle().querySelector(".theme__word[data-shown]")!.textContent!;
    const name = findToggle().getAttribute("aria-label")!;

    // Someone driving the page by voice says what they can read. If the
    // button shows "Dark Mode", "dark mode" has to be in its name.
    expect(name.toLowerCase()).toContain(shown.toLowerCase());
  });

  it("wears the link geometry, so its rule lands on the nav links'", () => {
    render(<App />);

    // The underline, the padding and the gap all come from `.link`. Dropping
    // that class is what would silently un-align the row.
    expect(findToggle().classList.contains("link")).toBe(true);
  });
});
