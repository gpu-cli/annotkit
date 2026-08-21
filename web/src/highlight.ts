/**
 * Syntax highlighting for the five snippets on the page, and nothing more.
 *
 * Hand-rolled rather than a library: the page ships three Swift snippets, one
 * note block and one shell line, and a general-purpose highlighter would be
 * the largest thing in the bundle by a wide margin for the sake of maybe forty
 * tokens. The grammars below are tuned to exactly what `copy.ts` contains; a
 * construct they do not know falls through as plain text, never as a wrong
 * colour.
 *
 * The one invariant worth a test: concatenating the tokens' text gives back
 * the input byte for byte. Highlighting is paint, not content — the copy
 * button and the accessibility tree both see the original string.
 */

export type TokenKind = "plain" | "keyword" | "type" | "string" | "comment" | "heading" | "field";

export type Token = { kind: TokenKind; text: string };

type Rule = { kind: TokenKind; re: RegExp };

/**
 * Swift. Keywords and compiler directives take the accent; capitalised
 * identifiers read as types (which on this page they all are: modules,
 * namespaces, views, sinks); strings and comments get their own inks.
 */
const swift: Rule[] = [
  { kind: "comment", re: /\/\/[^\n]*/y },
  { kind: "string", re: /"(?:[^"\\]|\\.)*"/y },
  { kind: "keyword", re: /#(?:if|endif|else|elseif)\b|\b(?:import|let|var|func|struct|return|some|true|false|nil)\b/y },
  // A type has a lowercase letter in it; an all-caps word (`DEBUG`) is a
  // compilation condition and stays plain, as it does in Xcode.
  { kind: "type", re: /\b[A-Z](?=[A-Za-z0-9_]*[a-z])[A-Za-z0-9_]*\b/y },
  { kind: "plain", re: /[A-Za-z_][A-Za-z0-9_]*|\s+|./y },
];

/**
 * The note block. A heading line, then `**Field**: value` lines, then the
 * comment as prose. Quoted text inside a value (the element's label) reads as
 * a string, the selector after the dash in the heading reads as a type: it is
 * the identifier an agent greps for.
 */
const markdown: Rule[] = [
  { kind: "heading", re: /^##[^\n]*/my },
  { kind: "field", re: /^\*\*[^*\n]+\*\*:/my },
  { kind: "string", re: /"(?:[^"\\]|\\.)*"/y },
  { kind: "plain", re: /[^\n"*]+|./y },
];

/** One shell line: the command word is the keyword, its argument a path. */
const sh: Rule[] = [
  { kind: "comment", re: /#[^\n]*/y },
  { kind: "keyword", re: /^\s*[a-z][\w-]*/my },
  { kind: "string", re: /\S*\//y },
  { kind: "plain", re: /\S+|\s+/y },
];

const grammars: Record<string, Rule[]> = { swift, markdown, sh };

export function tokenize(code: string, language: string): Token[] {
  const rules = grammars[language];
  if (!rules) return [{ kind: "plain", text: code }];

  const out: Token[] = [];
  let i = 0;
  while (i < code.length) {
    let matched = false;
    for (const { kind, re } of rules) {
      re.lastIndex = i;
      const m = re.exec(code);
      if (m && m[0].length > 0) {
        push(out, kind, m[0]);
        i += m[0].length;
        matched = true;
        break;
      }
    }
    if (!matched) {
      // Unreachable while every grammar ends in a catch-all, but a silent
      // infinite loop is the worst possible failure, so advance regardless.
      push(out, "plain", code.charAt(i));
      i += 1;
    }
  }
  return out;
}

/** Merge adjacent tokens of one kind so the DOM carries as few spans as the text allows. */
function push(out: Token[], kind: TokenKind, text: string) {
  const last = out[out.length - 1];
  if (last && last.kind === kind) last.text += text;
  else out.push({ kind, text });
}
