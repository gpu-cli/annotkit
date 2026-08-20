import { Fragment, type ReactNode } from "react";

/**
 * The one piece of markup the copy is allowed to carry.
 *
 * Machine text in a line of running prose — a filename, a call, a selector —
 * has to be set in the mono face or the reader has to work out from context
 * that `ANNOTKIT_NOTES.md` is a file and not a shouted noun. The page already
 * owns that distinction everywhere else: the dateline, the section numbers,
 * the sink names and the code plates are all mono, and mono means "the
 * machine said this".
 *
 * The alternative was to put JSX in copy.ts. That was rejected twice over:
 * copy.ts is the single source of truth for the page's STRINGS (epic §8.1),
 * and the typography test in tests/a11y.dom.test.tsx walks every exported
 * value looking for straight quotes and double hyphens — it can walk strings,
 * arrays and plain objects, and it would walk straight into a React element's
 * props and start asserting on them.
 *
 * So the copy stays strings, and marks its machine text the way every plain
 * text format already does: with backticks. This turns that into `<code>`.
 *
 * Deliberately not a markdown parser. One rule, no nesting, no emphasis, no
 * links, no escapes — anything more and copy.ts stops being readable as the
 * text it ships. An unclosed backtick is left as a literal character rather
 * than swallowing the rest of the line, which is the failure mode that would
 * actually reach production.
 */

const SEGMENT = /`([^`\n]+)`/g;

export function withCode(text: string): ReactNode {
  // The overwhelmingly common case is a line with no machine text in it.
  if (!text.includes("`")) return text;

  const out: ReactNode[] = [];
  let cursor = 0;

  const push = (node: ReactNode) => out.push(<Fragment key={out.length}>{node}</Fragment>);

  for (const match of text.matchAll(SEGMENT)) {
    const at = match.index;
    if (at > cursor) push(text.slice(cursor, at));
    push(<code>{match[1]}</code>);
    cursor = at + match[0].length;
  }

  // Includes the whole string when nothing matched — an unpaired backtick
  // prints as itself rather than eating the line after it.
  if (cursor < text.length) push(text.slice(cursor));

  return <>{out}</>;
}
