import type { Plugin } from "vite";
import { createHighlighter, type Highlighter } from "shiki";
import { colorReplacements, swiftTypes, theme, THEME_NAME } from "./theme";
import { snippets } from "../src/copy";

/**
 * Build-time syntax highlighting.
 *
 * Every code sample on the page is a constant in `src/copy.ts`, so there is
 * nothing to highlight at runtime: Shiki runs here, once, and hands the page
 * finished HTML through a virtual module. No grammar, engine or highlighter
 * ships to the browser.
 *
 * The theme is the page's own (`./theme.ts`): its colours are CSS variables
 * from tokens.css, so the plates follow the light and dark palettes with no
 * second set of colours and no theme-switch script.
 */

export const VIRTUAL_ID = "virtual:highlighted";
const RESOLVED_ID = "\0" + VIRTUAL_ID;

/** The lookup key the page uses: language and source, nothing derived. */
export function snippetKey(language: string, code: string): string {
  return `${language}\n${code}`;
}

/** One snippet to Shiki's inline markup: spans and line breaks only, since the
 * page owns the <pre> and <code> and the scroll container around them. */
export function render(
  highlighter: Highlighter,
  { language, code }: { language: string; code: string },
): string {
  return highlighter.codeToHtml(code, {
    lang: language,
    theme: THEME_NAME,
    structure: "inline",
    colorReplacements,
    // Keep `Annotation.` and `install` as separate tokens so the transformer
    // below can see the receiver on its own; the merge would otherwise fold
    // them into one span before it runs.
    mergeSameStyleTokens: false,
    transformers: [swiftTypes],
  });
}

export function highlight(): Plugin {
  return {
    name: "annotkit-highlight",
    resolveId(id) {
      return id === VIRTUAL_ID ? RESOLVED_ID : undefined;
    },
    async load(id) {
      if (id !== RESOLVED_ID) return;
      // Re-highlight when the copy changes in dev; the config import alone
      // would only catch it on a restart.
      this.addWatchFile(new URL("../src/copy.ts", import.meta.url).pathname);

      const languages = [...new Set(snippets.map((s) => s.language))];
      const highlighter = await createHighlighter({
        themes: [theme],
        langs: languages as Parameters<typeof createHighlighter>[0]["langs"],
      });

      const out: Record<string, string> = {};
      for (const snippet of snippets) {
        out[snippetKey(snippet.language, snippet.code)] = render(highlighter, snippet);
      }
      highlighter.dispose();
      return `export default ${JSON.stringify(out)};`;
    },
  };
}
