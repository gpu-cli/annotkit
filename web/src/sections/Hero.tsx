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
          {hero.display}
        </h1>
        <p className="hero__standfirst reveal" style={{ "--i": 1 } as React.CSSProperties}>
          {hero.standfirst}
        </p>
        <div className="hero__ctas reveal" style={{ "--i": 2 } as React.CSSProperties}>
          {site.repoIsPublic ? (
            <a
              className="link link--lead"
              href={site.repo}
              onClick={() => track({ name: "cta_github_clicked", props: { placement: "hero" } })}
            >
              {hero.ctaPrimary}
              <Icon as={ArrowUpRight} />
            </a>
          ) : (
            <span className="link link--lead" aria-disabled="true">
              {hero.ctaPrimary}
            </span>
          )}
          <a
            className="link link--lead"
            href="#updates"
            onClick={() => track({ name: "cta_updates_clicked", props: { placement: "hero" } })}
          >
            {hero.ctaSecondary}
            <Icon as={ArrowDown} />
          </a>
        </div>
        </div>
        <div className="hero__figure reveal" style={{ "--i": 3 } as React.CSSProperties}>
          <Figure capture={annotateLoop} />
        </div>
      </div>
    </section>
  );
}
