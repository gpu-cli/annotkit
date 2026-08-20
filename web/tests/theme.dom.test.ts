import { readFileSync } from "node:fs";
import { resolve as resolvePath } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { THEME_ATTR, THEME_KEY, resolve, storedChoice } from "../src/theme";

const indexHtml = readFileSync(resolvePath(__dirname, "../index.html"), "utf8");

/**
 * The pre-paint script in index.html cannot import from src/theme.ts — it has
 * to run before any module loads — so it repeats the storage key and the
 * attribute as literals. These tests are what stops that repetition drifting;
 * without them, renaming the key would silently strand every visitor's saved
 * choice and reset them to the system theme on the next deploy.
 */
describe("the pre-paint theme script", () => {
  it("reads the same storage key the app writes", () => {
    expect(indexHtml).toContain(`localStorage.getItem("${THEME_KEY}")`);
  });

  it("writes the same attribute the stylesheet selects on", () => {
    expect(indexHtml).toContain(`setAttribute("${THEME_ATTR}"`);
  });

  it("runs before the module bundle, or it would flash the wrong ground", () => {
    const script = indexHtml.indexOf("localStorage.getItem");
    const mount = indexHtml.indexOf("/src/main.tsx");
    expect(script).toBeGreaterThan(-1);
    expect(mount).toBeGreaterThan(-1);
    expect(script).toBeLessThan(mount);
  });

  it("falls back to a theme rather than throwing when storage is blocked", () => {
    expect(indexHtml).toMatch(/catch[\s\S]*setAttribute\("data-theme", "light"\)/);
  });
});

describe("theme resolution", () => {
  const original = window.matchMedia;
  afterEach(() => {
    window.matchMedia = original;
    localStorage.clear();
  });

  const systemPrefersDark = (dark: boolean) => {
    window.matchMedia = ((query: string) => ({
      matches: dark && query.includes("dark"),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    })) as unknown as typeof window.matchMedia;
  };

  it("follows the system when nothing is stored", () => {
    systemPrefersDark(true);
    expect(storedChoice()).toBe("system");
    expect(resolve("system")).toBe("dark");
  });

  it("lets an explicit choice override the system in both directions", () => {
    systemPrefersDark(true);
    expect(resolve("light")).toBe("light");
    systemPrefersDark(false);
    expect(resolve("dark")).toBe("dark");
  });

  it("ignores a stored value that is not a theme", () => {
    localStorage.setItem(THEME_KEY, "sepia");
    expect(storedChoice()).toBe("system");
  });
});
