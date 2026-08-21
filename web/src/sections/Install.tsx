import { ArrowUpRight } from "lucide-react";
import { Section } from "../components/Section";
import { CodeBlock } from "../components/CodeBlock";
import { Icon } from "../components/Icon";
import { install } from "../copy";
import { site } from "../config";
import { withCode } from "../markup";
import { track } from "../analytics";

/**
 * §01 — two snippets, and one paragraph beside each: the Xcode route beside
 * the dependency, the notes path beside the mount. The paragraph that used to
 * sit here listing what else the README covers was a table of contents, not
 * copy, and it pointed at the README a third time in four lines.
 *
 * Everything past these two moves (call sites per framework, sinks, seeded
 * identifiers, world context) is one link away; the page sells the loop, the
 * README installs it.
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
          <p>{withCode(install.xcode)}</p>
          <p>{withCode(install.note)}</p>
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
