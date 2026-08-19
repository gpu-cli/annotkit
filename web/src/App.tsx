import { useEffect } from "react";
import { Masthead } from "./sections/Masthead";
import { Hero } from "./sections/Hero";
import { Install } from "./sections/Install";
import { Annotate } from "./sections/Annotate";
import { AgentNotes } from "./sections/AgentNotes";
import { McpBridge } from "./sections/McpBridge";
import { Signup } from "./sections/Signup";
import { Footer } from "./sections/Footer";
import { init } from "./analytics";
import { skipLink } from "./copy";

export function App() {
  useEffect(init, []);

  return (
    <>
      <a className="skip" href="#main">
        {skipLink}
      </a>
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
    </>
  );
}
