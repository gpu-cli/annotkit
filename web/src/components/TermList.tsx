import { withCode } from "../markup";

/**
 * The term list that appears three times: §02's targeting rules, §03's sinks
 * and §04's MCP tools. It was the same eight lines of JSX in all three, which
 * was fine until the terms and bodies started carrying machine text — at
 * which point "the same eight lines" became "three places to remember to run
 * the copy through `withCode`".
 *
 * The term is a `<dfn>` because that is what it is: the defining instance of
 * a term, with its definition alongside. §02's terms are ordinary words
 * (Click, Frame, Anchor) and §03's and §04's are identifiers, so whether a
 * term is set as `<code>` is decided by the copy's own backticks rather than
 * by which section it lands in.
 */
export function TermList({
  terms,
}: {
  terms: readonly { readonly term: string; readonly body: string }[];
}) {
  return (
    <ul className="sink-list">
      {terms.map((entry) => (
        <li key={entry.term}>
          <dfn>{withCode(entry.term)}</dfn>
          <p>{withCode(entry.body)}</p>
        </li>
      ))}
    </ul>
  );
}
