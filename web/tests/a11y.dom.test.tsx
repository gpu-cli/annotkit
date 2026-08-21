import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen, within } from "@testing-library/react";
import axe from "axe-core";
import { App } from "../src/App";
import { hero, masthead, signup } from "../src/copy";

/**
 * The a11y and structure pass, run against the real component tree rather
 * than a browser (epic L5). axe cannot see colour contrast in jsdom — that is
 * covered by `node scripts/contrast.mjs`, which computes it from the tokens —
 * so the colour rules are disabled here and checked there.
 */

afterEach(cleanup);

async function violations(container: HTMLElement) {
  const results = await axe.run(container, {
    rules: {
      // Computed from the tokens by scripts/contrast.mjs; jsdom has no layout
      // or paint, so axe would report a false negative either way.
      "color-contrast": { enabled: false },
    },
  });
  return results.violations;
}

describe("axe", () => {
  it("reports no violations on the whole page", async () => {
    const { container } = render(<App />);
    const found = await violations(container);

    expect(
      found.map((v) => `${v.id}: ${v.nodes.length} node(s) — ${v.help}`),
    ).toEqual([]);
  });
});

describe("document structure", () => {
  it("opens with a skip link that targets main", () => {
    render(<App />);
    const skip = screen.getByRole("link", { name: /skip to content/i });

    expect(skip.getAttribute("href")).toBe("#main");
    expect(document.querySelector("#main")).not.toBeNull();
  });

  it("has exactly one h1, and it is the hero", () => {
    render(<App />);
    const headings = screen.getAllByRole("heading", { level: 1 });

    expect(headings).toHaveLength(1);
    expect(headings[0]?.textContent).toBe(hero.display);
  });

  it("skips no heading levels", () => {
    const { container } = render(<App />);
    const levels = [...container.querySelectorAll("h1,h2,h3,h4,h5,h6")].map((node) =>
      Number(node.tagName.slice(1)),
    );

    for (let i = 1; i < levels.length; i++) {
      expect(levels[i]! - levels[i - 1]!).toBeLessThanOrEqual(1);
    }
  });

  it("names every landmark, so a screen reader can tell them apart", () => {
    const { container } = render(<App />);
    for (const nav of container.querySelectorAll("nav")) {
      expect(nav.getAttribute("aria-label")).toBeTruthy();
    }
  });
});

describe("typography discipline", () => {
  it("ships no italic markup inside a heading (gate 38a)", () => {
    const { container } = render(<App />);
    for (const heading of container.querySelectorAll("h1,h2,h3")) {
      expect(heading.querySelector("em,i")).toBeNull();
    }
  });

  it("uses typographic punctuation, never straight quotes or double hyphens", async () => {
    // Walk every exported string rather than a hand-picked few. The earlier
    // spot-check only looked for a quote after whitespace, so the straight
    // apostrophe in "Agentation's" sat in the footer colophon undetected.
    const copy: Record<string, unknown> = await import("../src/copy");

    const strings: string[] = [];
    const walk = (value: unknown) => {
      if (typeof value === "string") strings.push(value);
      else if (Array.isArray(value)) value.forEach(walk);
      else if (value && typeof value === "object") Object.values(value).forEach(walk);
    };
    walk(copy);

    expect(strings.length).toBeGreaterThan(30);
    // Code samples legitimately contain straight quotes and dashes. They are
    // identified by membership, not by a newline: the one-line dependency
    // snippet in §01 has quotes and no newline.
    const code = new Set((copy.snippets as { code: string }[]).map((s) => s.code));
    for (const value of strings) {
      if (code.has(value)) continue;
      expect(value, value).not.toMatch(/--/);
      expect(value, value).not.toMatch(/\.\.\./);
      expect(value, value).not.toMatch(/'/);
      expect(value, value).not.toMatch(/"/);
    }
  });
});

describe("the form", () => {
  it("labels the input with a real label, not a placeholder", () => {
    render(<App />);
    const input = screen.getByLabelText(signup.label);

    expect(input.tagName).toBe("INPUT");
    expect(input.getAttribute("placeholder")).not.toBe(signup.label);
  });

  it("wires the helper slot to the input with aria-describedby", () => {
    render(<App />);
    const input = screen.getByLabelText(signup.label);
    const describedBy = input.getAttribute("aria-describedby");

    expect(describedBy).toBeTruthy();
    expect(document.getElementById(describedBy!)?.textContent).toBe(signup.helper);
  });

  it("keeps the honeypot out of the tab order and out of the a11y tree", () => {
    const { container } = render(<App />);
    const honeypot = container.querySelector<HTMLInputElement>('input[name="url"]');

    expect(honeypot).not.toBeNull();
    expect(honeypot!.tabIndex).toBe(-1);
    expect(honeypot!.closest("[aria-hidden='true']")).not.toBeNull();
  });
});

describe("the CTAs", () => {
  it("points the GitHub links at the repo", () => {
    render(<App />);
    const links = screen
      .getAllByRole("link")
      .filter((link) => link.getAttribute("href")?.includes("github.com"));

    expect(links.length).toBeGreaterThanOrEqual(2);
    for (const link of links) {
      expect(link.getAttribute("href")).toMatch(/^https:\/\/github\.com\/gpu-cli\/annotkit/);
    }
  });

  it("anchors the updates CTA at the signup section", () => {
    render(<App />);
    const masthead_nav = screen.getByRole("navigation", { name: /primary/i });
    const updates = within(masthead_nav).getByRole("link", { name: masthead.links.updates });

    expect(updates.getAttribute("href")).toBe("#updates");
    expect(document.querySelector("#updates")).not.toBeNull();
  });
});
