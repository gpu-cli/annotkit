import { useEffect, useRef, useState } from "react";
import { codeBlock } from "../copy";

/**
 * A code sample in a typographic frame — a caption row, a hairline, the
 * `<pre>`, a hairline. Deliberately NOT a re-drawn editor window: no mock
 * title bar, no traffic-light dots (Hallmark gate 47).
 *
 * The copy button ships all eight states. `copying` and `failed` are real —
 * `navigator.clipboard` is async and it rejects on insecure origins and on a
 * denied permission, and the user needs to be told when it does.
 */

type CopyState = "idle" | "copying" | "copied" | "failed";

export function CodeBlock({
  caption,
  code,
  language = "swift",
}: {
  caption: string;
  code: string;
  language?: string;
}) {
  const [state, setState] = useState<CopyState>("idle");
  const timer = useRef<number | undefined>(undefined);

  // The clipboard API is absent on insecure origins. Disable rather than
  // offer a control that cannot work.
  const supported =
    typeof navigator !== "undefined" && typeof navigator.clipboard?.writeText === "function";

  useEffect(() => () => window.clearTimeout(timer.current), []);

  async function copy() {
    if (!supported || state === "copying") return;
    setState("copying");
    try {
      await navigator.clipboard.writeText(code);
      setState("copied");
    } catch {
      setState("failed");
    }
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setState("idle"), 2500);
  }

  const label =
    state === "copied"
      ? codeBlock.copied
      : state === "failed"
        ? codeBlock.failed
        : codeBlock.copy;

  return (
    <div className="code">
      <div className="code__bar">
        <p className="u-label code__caption">{caption}</p>
        <button
          type="button"
          className="copy"
          onClick={copy}
          disabled={!supported || state === "copying"}
          data-state={state === "idle" || state === "copying" ? undefined : state}
          aria-label={codeBlock.copyLabel(caption)}
          aria-busy={state === "copying" || undefined}
        >
          {label}
        </button>
      </div>
      <pre className="code__pre" tabIndex={0}>
        <code data-language={language}>{code}</code>
      </pre>
      {/* The outcome is announced once, not on every keystroke of state. */}
      <span className="u-visually-hidden" role="status">
        {state === "copied" ? codeBlock.copied : state === "failed" ? codeBlock.failed : ""}
      </span>
    </div>
  );
}
