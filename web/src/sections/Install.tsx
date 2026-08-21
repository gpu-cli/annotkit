import { ArrowUpRight } from "lucide-react";
import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { Icon } from "../components/Icon";
import { install } from "../copy";
import { site } from "../config";
import { withCode } from "../markup";
import { track } from "../analytics";

/**
 * §01 — two snippets: the dependency line and the mount. Everything the
 * README covers beyond that (AppKit vs SwiftUI vs UIKit call sites, the
 * working-directory gotcha, sinks, world context) is one link away rather
 * than repeated here; the page sells the loop, the README installs it.
 */
export function Install() {
  return (
    <Section
      id="install"
      number={install.number}
      title={install.title}
      lead={install.lead}
      modifier="section--install"
    >
      <div className="section__body section__body--7-5">
        <div className="stack stack--lg">
          <CodeBlock {...install.package} />
          <CodeBlock {...install.mount} />
        </div>
        <div className="stack">
          <p>{withCode(install.note)}</p>
          <p>{withCode(install.more)}</p>
          <a
            className="link link--lead"
            href={site.setup}
            onClick={() => track({ name: "cta_github_clicked", props: { placement: "install" } })}
          >
            {install.readme}
            <Icon as={ArrowUpRight} />
          </a>
        </div>
      </div>
    </Section>
  );
}
