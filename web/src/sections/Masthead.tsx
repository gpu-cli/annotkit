import { ArrowDown, ArrowUpRight } from "lucide-react";
import { Icon } from "../components/Icon";
import { ThemeToggle } from "../components/ThemeToggle";
import { masthead } from "../copy";
import { site } from "../config";
import { track } from "../analytics";

/**
 * N6 · Newspaper masthead. The dateline row carries the platform facts from
 * Package.swift, which is what an editorial masthead's issue line is for:
 * stating what this edition is, in facts rather than adjectives.
 *
 * The theme control rides in the link row, not in a row of its own. It used
 * to hang flush right above the masthead, which cost 48 px of the fold budget
 * to say nothing and put the page's one piece of chrome in the one place gate
 * 42 watches. A row of its own under the wordmark cost nearly as much: a
 * 44 px target with the mast's own --space-lg above and below it read as a
 * fourth line of the masthead rather than as a control. Beside the two links
 * it is one more thing you can press, at the height they already sit at.
 *
 * It is a sibling of the `<nav>` rather than a third `<li>` inside it: the
 * links go somewhere and the button does not, and a landmark named "Primary"
 * should list the places you can go.
 */
export function Masthead() {
  return (
    <header className="mast">
      <div className="u-shell mast__inner">
        <p className="u-label mast__dateline">
          {[masthead.dateline, ...masthead.facts].join(" · ")}
        </p>
        <p className="mast__name">{masthead.wordmark}</p>
        <div className="mast__row">
          <nav className="mast__nav" aria-label="Primary">
            <ul>
              <li>
                {site.repoIsPublic ? (
                  <a
                    className="link"
                    href={site.repo}
                    onClick={() =>
                      track({ name: "cta_github_clicked", props: { placement: "masthead" } })
                    }
                  >
                    {masthead.links.github}
                    <Icon as={ArrowUpRight} />
                  </a>
                ) : (
                  <span className="link" aria-disabled="true">
                    {masthead.links.githubUnavailable}
                  </span>
                )}
              </li>
              <li>
                <a
                  className="link"
                  href="#updates"
                  onClick={() =>
                    track({ name: "cta_updates_clicked", props: { placement: "masthead" } })
                  }
                >
                  {masthead.links.updates}
                  <Icon as={ArrowDown} />
                </a>
              </li>
            </ul>
          </nav>
          <ThemeToggle />
        </div>
        <hr className="mast__rule" aria-hidden="true" />
      </div>
    </header>
  );
}
