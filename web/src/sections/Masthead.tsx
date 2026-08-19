import { masthead } from "../copy";
import { site } from "../config";
import { track } from "../analytics";

/**
 * N6 · Newspaper masthead. The dateline row carries the platform facts from
 * Package.swift, which is what an editorial masthead's issue line is for:
 * stating what this edition is, in facts rather than adjectives.
 */
export function Masthead() {
  return (
    <header className="mast">
      <div className="u-shell mast__inner">
        <p className="u-label mast__dateline">
          {[masthead.dateline, ...masthead.facts].join(" · ")}
        </p>
        <p className="mast__name">{masthead.wordmark}</p>
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
              </a>
            </li>
          </ul>
        </nav>
        <hr className="mast__rule" aria-hidden="true" />
      </div>
    </header>
  );
}
