import { useEffect, useRef, useState } from "react";
import * as ScrollArea from "@radix-ui/react-scroll-area";
import { Check, Copy, X } from "lucide-react";
import { Icon } from "./Icon";
import { codeBlock } from "../copy";
import { withCode } from "../markup";

/**
 * A code sample in a typographic frame — a caption row above a hairline
 * plate. Deliberately NOT a re-drawn editor window: no mock title bar, no
 * traffic-light dots (Hallmark gate 47), and no rule under the caption, which
 * would read as the top edge of a frame the plate's rounded corners then fail
 * to close.
 *
 * The plate is the page's one real scroll container: long snippets run off
 * sideways. A Radix ScrollArea owns that overflow so the bar is drawn in the
 * page's tokens instead of the platform's, and it appears only when there is
 * something to scroll to.
 *
 * The copy button ships all eight states. `copying` and `failed` are real —
 * `navigator.clipboard` is async and it rejects on insecure origins and on a
 * denied permission, and the user needs to be told when it does.
 *
 * It is a bare glyph rather than the word COPY. Three things keep that from
 * costing anything: the button's accessible name is a full sentence naming
 * the snippet, so nothing is lost to a screen reader; the outcome is spoken
 * by the live region below; and the glyph CHANGES rather than only its
 * colour, so the confirmation does not depend on telling grey from accent.
 * The failure state gets its own glyph for the same reason — a red tick
 * would be a tick.
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

  // The glyph is the state. `copying` keeps the Copy mark rather than
  // flashing a third one: the operation resolves in a frame or two on a
  // healthy clipboard, and a spinner for that is theatre.
  const Glyph = state === "copied" ? Check : state === "failed" ? X : Copy;

  return (
    <div className="code">
      <div className="code__bar">
        <p className="u-label code__caption">{withCode(caption)}</p>
        <button
          type="button"
          className="copy"
          onClick={copy}
          disabled={!supported || state === "copying"}
          data-state={state === "idle" || state === "copying" ? undefined : state}
          aria-label={codeBlock.copyLabel(caption)}
          aria-busy={state === "copying" || undefined}
        >
          {/* `inline`, so the glyph is 1 em of the button's own type — and
           * the button is set at the caption's size, so the mark and the
           * words it sits opposite are drawn at the same scale. */}
          <Icon as={Glyph} />
        </button>
      </div>
      {/* The plate is the ScrollArea root; the viewport is what actually
       * scrolls, so `tabIndex` lives there — a scroll region a keyboard
       * cannot reach is a WCAG failure, and Radix does not add it for us. */}
      <ScrollArea.Root className="code__plate" type="auto">
        <ScrollArea.Viewport className="code__viewport" tabIndex={0}>
          <pre className="code__pre">
            <code data-language={language}>{code}</code>
          </pre>
        </ScrollArea.Viewport>
        <ScrollArea.Scrollbar className="code__scrollbar" orientation="horizontal">
          <ScrollArea.Thumb className="code__thumb" />
        </ScrollArea.Scrollbar>
      </ScrollArea.Root>
      {/* The outcome is announced once, not on every keystroke of state. */}
      <span className="u-visually-hidden" role="status">
        {state === "copied" ? codeBlock.copied : state === "failed" ? codeBlock.failed : ""}
      </span>
    </div>
  );
}
