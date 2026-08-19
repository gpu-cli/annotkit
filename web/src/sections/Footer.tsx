import { footer } from "../copy";
import { site } from "../config";
import { track } from "../analytics";

/** Ft1 · Mast-headed — wordmark band, tagline, small links, colophon. */
export function Footer() {
  const href = { repo: site.repo, issues: site.issues, license: site.license } as const;

  return (
    <footer className="foot">
      <div className="u-shell">
        <div className="foot__band">
          <p className="foot__wordmark">{footer.wordmark}</p>
          <p className="foot__tagline">{footer.tagline}</p>
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
        <p className="foot__colophon">{footer.colophon}</p>
      </div>
    </footer>
  );
}
