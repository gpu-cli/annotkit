import { Fragment } from "react";
import { ArrowDown, ArrowUpRight } from "lucide-react";
import { Icon } from "../components/Icon";
import { hero } from "../copy";
import { site } from "../config";
import { track } from "../analytics";
import { Figure } from "../components/Figure";
import { annotateLoop } from "../captures";

/**
 * The display, the standfirst and the two CTAs on the left; the demo loop on
 * the right, a real capture in a bare frame (gate 47 still holds — nothing is
 * drawn). The page's one orchestrated entrance lives here: four elements,
 * staggered by DOM index, settling inside ~200 ms. Nothing below the fold
 * animates on scroll except the section rules.
 */
export function Hero() {
  return (
    <section className="hero" aria-labelledby="hero-display">
      <div className="u-shell hero__grid">
        <div className="hero__copy">
        <h1 className="hero__display reveal" id="hero-display" style={{ "--i": 0 } as React.CSSProperties}>
          {/* One sentence per line from the span breakpoint up. Each sentence
           * is a no-wrap span, so the only place the line can break is
           * between them; the text content is the one string, unchanged. */}
          {hero.display.split(/(?<=\.) /).map((sentence, i) => (
            <Fragment key={sentence}>
              {/* The space sits BETWEEN the spans: inside a no-wrap span it
               * would be a space the line cannot break at. */}
              {i > 0 ? " " : null}
              <span className="hero__sentence">{sentence}</span>
            </Fragment>
          ))}
        </h1>
        <p className="hero__standfirst reveal" style={{ "--i": 1 } as React.CSSProperties}>
          {hero.standfirst}
        </p>
        {/* The primary sends the reader one section down rather than off the
          * site: §01 is the next thing on the page and it already ends with
          * the README link. The repo-visibility branch moved with the README
          * onto the secondary, which is where it was always aimed — an anchor
          * into this same document has nothing to be unavailable about. */}
        <div className="hero__ctas reveal" style={{ "--i": 2 } as React.CSSProperties}>
          <a
            className="link link--lead"
            href="#install"
            onClick={() => track({ name: "cta_install_clicked", props: { placement: "hero" } })}
          >
            {hero.ctaPrimary}
            <Icon as={ArrowDown} />
          </a>
          {site.repoIsPublic ? (
            <a
              className="link link--lead"
              href={site.repo}
              onClick={() => track({ name: "cta_github_clicked", props: { placement: "hero" } })}
            >
              {hero.ctaSecondary}
              <Icon as={ArrowUpRight} />
            </a>
          ) : (
            <span className="link link--lead" aria-disabled="true">
              {hero.ctaSecondary}
            </span>
          )}
        </div>
        </div>
        <div className="hero__figure reveal" style={{ "--i": 3 } as React.CSSProperties}>
          <Figure capture={annotateLoop} />
        </div>
      </div>
    </section>
  );
}
