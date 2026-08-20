import { useEffect, useState } from "react";
import { Moon, Sun } from "lucide-react";
import { Icon } from "./Icon";
import { theme as copy } from "../copy";
import {
  applyTheme,
  persistChoice,
  resolve,
  storedChoice,
  watchSystem,
  type ThemeChoice,
} from "../theme";

/**
 * The theme control, third in the masthead's link row.
 *
 * It names and draws the theme it will switch TO. A bare icon had no way to
 * say which direction it went, and a sun that means "you are in light mode"
 * is a status light people press expecting nothing to happen.
 *
 * It is built as a link rather than as an icon button, because it now IS one:
 * a mono label, a 1 em mark beside it, and the same accent rule under it that
 * GitHub and Updates carry. That also settles an alignment problem the icon-
 * only version had — a 20 px glyph centred in its own box sat closer to the
 * rule than the links' text did, and no amount of padding fixed it, because
 * the links' rule is placed by a LINE BOX with descender space under the
 * baseline. Give the control a line of type and it gets the same line box for
 * free.
 *
 * Both words are rendered, and the inactive one is hidden with `visibility`
 * rather than removed. "Light Mode" is one character wider than "Dark Mode",
 * so swapping the text would move the rule under it and nudge the row; the
 * cell sizes to the wider of the two and then never changes. `visibility:
 * hidden` also takes the inactive word out of the accessibility tree, so
 * nothing reads both.
 *
 * Clicking commits to light or dark explicitly. "System" is the state you
 * start in and cannot click back to; a third stop in a cycle is a control
 * most people never resolve. Clearing the stored choice is what a browser's
 * own site-data reset is for.
 */
export function ThemeToggle() {
  const [choice, setChoice] = useState<ThemeChoice>(() =>
    typeof window === "undefined" ? "system" : storedChoice(),
  );

  // While the choice is "system", the OS still owns the answer.
  useEffect(() => {
    if (choice !== "system") return;
    return watchSystem(() => applyTheme("system"));
  }, [choice]);

  const current = typeof window === "undefined" ? "light" : resolve(choice);
  const next = current === "dark" ? "light" : "dark";
  const Glyph = next === "dark" ? Moon : Sun;

  function flip() {
    setChoice(next);
    persistChoice(next);
    applyTheme(next);
  }

  return (
    <button type="button" className="link theme" onClick={flip} aria-label={copy.switchTo[next]}>
      <span className="theme__label">
        <span className="theme__word" data-shown={next === "dark" ? "" : undefined}>
          {copy.mode.dark}
        </span>
        <span className="theme__word" data-shown={next === "light" ? "" : undefined}>
          {copy.mode.light}
        </span>
      </span>
      <Icon as={Glyph} />
    </button>
  );
}
