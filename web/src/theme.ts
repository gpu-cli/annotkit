/**
 * Theme resolution, in one place.
 *
 * Three states, not two. "system" is a real, selectable state — a visitor who
 * has never touched the toggle is FOLLOWING their OS, and flipping the OS at
 * midnight should follow with it. Storing only "light" or "dark" would freeze
 * whichever one they happened to land on the first time they loaded the page.
 *
 * The initial resolution runs from an inline script in index.html, before
 * first paint, so the page never flashes the wrong ground. That script
 * duplicates THEME_KEY and THEME_ATTR as string literals, because it has to
 * run before any module loads. The two are checked against each other by
 * tests/theme.dom.test.ts rather than left to drift.
 */

export type ThemeChoice = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";

export const THEME_KEY = "annotkit-theme";
export const THEME_ATTR = "data-theme";

const DARK_QUERY = "(prefers-color-scheme: dark)";

export function systemTheme(): ResolvedTheme {
  return window.matchMedia(DARK_QUERY).matches ? "dark" : "light";
}

export function storedChoice(): ThemeChoice {
  try {
    const raw = localStorage.getItem(THEME_KEY);
    return raw === "light" || raw === "dark" || raw === "system" ? raw : "system";
  } catch {
    // Private mode and blocked storage both throw here. Following the system
    // is the right fallback: it is what an untouched toggle already means.
    return "system";
  }
}

export function resolve(choice: ThemeChoice): ResolvedTheme {
  return choice === "system" ? systemTheme() : choice;
}

/** Writes the resolved theme where CSS can see it. */
export function applyTheme(choice: ThemeChoice): void {
  document.documentElement.setAttribute(THEME_ATTR, resolve(choice));
}

export function persistChoice(choice: ThemeChoice): void {
  try {
    if (choice === "system") localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, choice);
  } catch {
    // Nothing to do — the choice still applies for this page view.
  }
}

/** Subscribes to OS changes; only meaningful while the choice is "system". */
export function watchSystem(onChange: (theme: ResolvedTheme) => void): () => void {
  const query = window.matchMedia(DARK_QUERY);
  const handler = () => onChange(query.matches ? "dark" : "light");
  query.addEventListener("change", handler);
  return () => query.removeEventListener("change", handler);
}
