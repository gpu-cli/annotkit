import type { ShikiTransformer, ThemeRegistrationRaw } from "shiki";

/**
 * The page's own syntax theme, in TextMate form.
 *
 * Shiki's stock CSS-variables theme is coarse by design (it paints a Swift
 * argument label, an enum case and a shell argument all as "function"), so
 * the rules here are written against the scopes the Swift, Markdown and
 * shell grammars actually emit for the snippets on the page. The roles
 * follow Xcode's, which is what a Swift reader's eye is trained on:
 * keywords and compiler directives in one ink, type names in a second,
 * strings in a third, comments stepped back, and everything else — method
 * names, argument labels, enum cases, shell arguments — left in the body ink.
 *
 * A TextMate theme wants hex colours. These are placeholders that never
 * reach the page: `colorReplacements` swaps each for a CSS variable, so the
 * plates follow the light and dark palettes in tokens.css with no second set
 * of colours and no theme-switch script.
 */

const INK = "#000001";
const KEYWORD = "#000002";
const TYPE = "#000003";
const STRING = "#000004";
const COMMENT = "#000005";

export const colorReplacements: Record<string, string> = {
  [INK]: "var(--color-ink)",
  [KEYWORD]: "var(--color-accent)",
  [TYPE]: "var(--color-syntax-type)",
  [STRING]: "var(--color-syntax-string)",
  [COMMENT]: "var(--color-muted)",
};

export const THEME_NAME = "annotkit";

export const theme: ThemeRegistrationRaw = {
  name: THEME_NAME,
  type: "light",
  colors: { "editor.foreground": INK, "editor.background": "#000000" },
  settings: [
    { settings: { foreground: INK } },
    {
      // `#if` is one keyword, hash included, as Xcode paints it.
      scope: ["keyword", "storage", "punctuation.definition.preprocessor"],
      settings: { foreground: KEYWORD },
    },
    { scope: ["entity.name.type", "support.type", "support.class"], settings: { foreground: TYPE } },
    { scope: ["string.quoted", "string.interpolated"], settings: { foreground: STRING } },
    { scope: ["comment"], settings: { foreground: COMMENT } },
    // Shell: the command word is the keyword of the line; its arguments are
    // words, not strings, however the grammar files them.
    { scope: ["entity.name.command.shell"], settings: { foreground: KEYWORD } },
    { scope: ["string.unquoted.argument.shell"], settings: { foreground: INK } },
    // The note block: the heading carries the selector, the `**Field**`
    // labels are labels. Bold, and the heading in the accent, so the eye
    // reads down the labels and across to the values.
    { scope: ["markup.heading"], settings: { foreground: KEYWORD, fontStyle: "bold" } },
    { scope: ["markup.bold"], settings: { fontStyle: "bold" } },
  ],
};

/**
 * What the Swift grammar cannot say. It files `ContentView(` and `install(`
 * under the same scope, leaves a receiver like `Annotation.` unscoped, and
 * hands both to Shiki inside one body-ink token with the call around them.
 * Xcode colours a capitalised name in call or member position as a type,
 * because in Swift it is one. So: Swift tokens only, body ink only, and the
 * token is split around each capitalised name (one with a lowercase letter in
 * it; `DEBUG` is a compilation condition) that a `.` or `(` follows. Only the
 * colour of that slice changes; the text is the same bytes in the same order.
 * The replacement is applied by hand because Shiki substitutes colours during
 * tokenisation, before transformers run.
 */
const TYPE_IN_CALL = /\b[A-Z](?=[A-Za-z0-9_]*[a-z])[A-Za-z0-9_]*(?=[.(])/g;

export const swiftTypes: ShikiTransformer = {
  name: "annotkit:swift-types",
  tokens(lines) {
    if (this.options.lang !== "swift") return;
    for (const line of lines) {
      const split = line.flatMap((token) => {
        if (token.color !== colorReplacements[INK]) return [token];
        const out: typeof line = [];
        let cursor = 0;
        for (const m of token.content.matchAll(TYPE_IN_CALL)) {
          const at = m.index ?? 0;
          if (at > cursor) out.push(slice(token, cursor, at));
          out.push({ ...slice(token, at, at + m[0].length), color: colorReplacements[TYPE] });
          cursor = at + m[0].length;
        }
        if (cursor < token.content.length) out.push(slice(token, cursor, token.content.length));
        return out;
      });
      line.splice(0, line.length, ...split);
    }
  },
};

function slice<T extends { content: string; offset: number }>(token: T, from: number, to: number): T {
  return { ...token, content: token.content.slice(from, to), offset: token.offset + from };
}
