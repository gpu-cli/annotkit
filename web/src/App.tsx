import { useEffect } from "react";
import * as ScrollArea from "@radix-ui/react-scroll-area";
import { Masthead } from "./sections/Masthead";
import { Hero } from "./sections/Hero";
import { Install } from "./sections/Install";
import { Annotate } from "./sections/Annotate";
import { AgentNotes } from "./sections/AgentNotes";
import { McpBridge } from "./sections/McpBridge";
import { Signup } from "./sections/Signup";
import { Footer } from "./sections/Footer";
import { Backdrop } from "./components/Backdrop";
import { init } from "./analytics";
import { skipLink } from "./copy";

/**
 * The whole document scrolls through a ScrollArea, so the page's own scrollbar
 * is drawn in its own ink rather than the platform's.
 *
 * That means the viewport, not the document, is what scrolls. Three things
 * follow, and each is handled rather than hoped for:
 *
 *   · `scroll-behavior: smooth` and the skip link both act on the nearest
 *     scrollable ancestor, which is now `.page__viewport` — the CSS moved
 *     with it.
 *   · `scripts/responsive-check.mjs` measured the DOCUMENT for gate 34. A
 *     document that can no longer overflow always passes, so the probe now
 *     measures this viewport too. A gate that cannot fail is not a gate.
 *   · The mobile URL bar no longer collapses on scroll, because the body is
 *     not what moves. That is the real cost of this pattern and it is the
 *     reason to think twice before reaching for it.
 */
export function App() {
  useEffect(init, []);

  return (
    <ScrollArea.Root className="page" type="auto">
      <Backdrop />
      <ScrollArea.Viewport className="page__viewport">
        <a className="skip" href="#main">
          {skipLink}
        </a>
        {/* The theme control is inside the masthead now, centred under the
         * wordmark. It was a flush-right row of its own here; see the note in
         * sections/Masthead.tsx for why it moved. */}
        <Masthead />
        <main id="main">
          <Hero />
          <Install />
          <Annotate />
          <AgentNotes />
          <McpBridge />
          <Signup />
        </main>
        <Footer />
      </ScrollArea.Viewport>
      <ScrollArea.Scrollbar className="page__scrollbar" orientation="vertical">
        <ScrollArea.Thumb className="page__thumb" />
      </ScrollArea.Scrollbar>
    </ScrollArea.Root>
  );
}
