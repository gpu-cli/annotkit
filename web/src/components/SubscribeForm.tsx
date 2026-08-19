import { useId, useRef, useState } from "react";
import { parseEmail } from "../../shared/email";
import { SUBSCRIBE_ENDPOINT } from "../config";
import { signup } from "../copy";
import { track, type SignupFailureKind } from "../analytics";

/**
 * The page's only stateful UI. All eight states from epic §7 ship here; the
 * five that are structural live in this component, the three that are pure
 * styling (`hover`, `focus-visible`, `active`) live on `.field__input` and
 * `.submit` in base.css.
 *
 * Submitting is idempotent: an address already on the list comes back as
 * `already_subscribed` and renders the same success shape with different
 * wording, because from the visitor's side nothing different happened.
 */

type Status = "subscribed" | "already_subscribed";
type Phase =
  | { name: "idle" }
  | { name: "submitting" }
  | { name: "error"; kind: SignupFailureKind }
  | { name: "done"; status: Status };

const isFailureKind = (value: unknown): value is SignupFailureKind =>
  value === "invalid_email" ||
  value === "rate_limited" ||
  value === "upstream" ||
  value === "network";

export function SubscribeForm() {
  const [email, setEmail] = useState("");
  const [phase, setPhase] = useState<Phase>({ name: "idle" });
  const [touched, setTouched] = useState(false);
  const noteRef = useRef<HTMLParagraphElement>(null);

  const inputId = useId();
  const noteId = useId();

  const submitting = phase.name === "submitting";
  const clientInvalid = touched && email.length > 0 && parseEmail(email) === null;
  const invalid = clientInvalid || phase.name === "error";

  function fail(kind: SignupFailureKind) {
    setPhase({ name: "error", kind });
    track({ name: "signup_failed", props: { kind } });
    // The message is below the field and the eye is above it — move focus so a
    // screen-reader and a keyboard user both land on what changed.
    window.requestAnimationFrame(() => noteRef.current?.focus());
  }

  async function onSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting) return;

    setTouched(true);
    const normalised = parseEmail(email);
    if (normalised === null) {
      fail("invalid_email");
      return;
    }

    setPhase({ name: "submitting" });
    track({ name: "signup_submitted" });

    const form = new FormData(event.currentTarget);
    const honeypot = String(form.get("url") ?? "");

    let response: Response;
    try {
      response = await fetch(SUBSCRIBE_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: normalised, url: honeypot }),
      });
    } catch {
      fail("network");
      return;
    }

    const body: unknown = await response.json().catch(() => null);

    if (response.ok) {
      const status: Status =
        body && typeof body === "object" && "status" in body && body.status === "already_subscribed"
          ? "already_subscribed"
          : "subscribed";
      setPhase({ name: "done", status });
      track({ name: "signup_succeeded", props: { status } });
      return;
    }

    const error =
      body && typeof body === "object" && "error" in body ? body.error : undefined;
    fail(isFailureKind(error) ? error : "upstream");
  }

  if (phase.name === "done") {
    return (
      <div className="signup__done" role="status">
        <strong>
          {phase.status === "already_subscribed" ? signup.successDuplicate : signup.successNew}
        </strong>
        <p>{signup.successBody}</p>
      </div>
    );
  }

  const noteTone =
    phase.name === "error" ? "error" : clientInvalid ? "error" : undefined;
  const noteText =
    phase.name === "error"
      ? signup.errors[phase.kind]
      : clientInvalid
        ? signup.errors.invalid_email
        : signup.helper;

  return (
    <form className="signup__form" onSubmit={onSubmit} noValidate>
      <div className="field">
        <label className="field__label" htmlFor={inputId}>
          {signup.label}
        </label>
        <div className="field__row">
          <input
            id={inputId}
            className="field__input"
            type="email"
            name="email"
            inputMode="email"
            autoComplete="email"
            placeholder={signup.placeholder}
            value={email}
            required
            aria-required="true"
            aria-invalid={invalid || undefined}
            aria-describedby={noteId}
            disabled={submitting}
            onChange={(event) => {
              setEmail(event.target.value);
              if (phase.name === "error") setPhase({ name: "idle" });
            }}
            onBlur={() => setTouched(true)}
          />
          <button
            type="submit"
            className="submit"
            disabled={submitting}
            aria-busy={submitting || undefined}
          >
            {submitting ? signup.submitLoading : signup.submit}
          </button>
        </div>
        {/* The slot holds a line whether filled or not, so an appearing error
            never pushes the page down. */}
        <p
          id={noteId}
          ref={noteRef}
          tabIndex={-1}
          className="field__note"
          data-tone={noteTone}
          aria-live="polite"
        >
          {noteText}
        </p>
      </div>

      {/* Honeypot. Real people never fill this; bots fill everything. */}
      <div className="honeypot" aria-hidden="true">
        <label htmlFor="url-field">Leave this field empty</label>
        <input id="url-field" name="url" type="text" tabIndex={-1} autoComplete="off" />
      </div>
    </form>
  );
}
