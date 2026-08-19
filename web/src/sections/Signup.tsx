import { Section } from "../components/Section";
import { SubscribeForm } from "../components/SubscribeForm";
import { signup } from "../copy";

/** §05 — the page's second CTA and its only stateful UI. */
export function Signup() {
  return (
    <Section
      id="updates"
      number={signup.number}
      title={signup.title}
      lead={signup.lead}
      modifier="section--signup"
    >
      <div className="stack stack--lg">
        <SubscribeForm />
        <p className="signup__privacy">{signup.privacy}</p>
      </div>
    </Section>
  );
}
