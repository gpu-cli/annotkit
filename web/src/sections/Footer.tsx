import { ArrowUpRight } from "lucide-react";
import { Icon } from "../components/Icon";
import { footer } from "../copy";
import { site } from "../config";
import { track } from "../analytics";

/**
 * Ft1 · Mast-headed — an identity block, a link set, and a separate sub-band
 * carrying the org line.
 *
 * The band is two columns above 48 rem: who this is on the left, where else to
 * find it on the right. The tagline sits under the wordmark it describes
 * rather than across the page from it, which is the arrangement a masthead
 * actually uses — a name with its strapline beneath, not a name and a
 * sentence holding opposite corners. The links take the right edge, on the
 * wordmark's own baseline, so the band still spans the page's full measure.
 *
 * The sub-band is a `<div>` inside the one `<footer>` rather than a second
 * landmark: two footer landmarks would need two names to be told apart, and
 * "who ships this" is not a second region of the document — it is the fine
 * print at the bottom of the one it already has.
 */
export function Footer() {
  const href = { repo: site.repo, issues: site.issues } as const;

  return (
    <footer className="foot">
      <div className="u-shell foot__main">
        <div className="foot__band">
          <div className="foot__identity">
            <p className="foot__wordmark">{footer.wordmark}</p>
            <p className="foot__tagline">
              {footer.tagline.map((sentence) => (
                <span key={sentence}>{sentence}</span>
              ))}
            </p>
          </div>
          <nav className="foot__links" aria-label="Elsewhere">
            {footer.links.map((link) => (
              <a
                key={link.label}
                className="prose-link"
                href={href[link.href]}
                onClick={
                  link.href === "repo"
                    ? () => track({ name: "cta_github_clicked", props: { placement: "footer" } })
                    : undefined
                }
              >
                {link.label}
              </a>
            ))}
          </nav>
        </div>
      </div>

      <div className="subfoot">
        <div className="u-shell">
          <a className="subfoot__link" href={site.org}>
            {footer.poweredBy}
            <Icon as={ArrowUpRight} />
          </a>
        </div>
      </div>
    </footer>
  );
}
