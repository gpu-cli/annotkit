/**
 * PostHog wiring (epic §3, L5).
 *
 * Three constraints shape this file:
 *
 *  1. **Cookieless.** `persistence: "memory"` keeps the SDK out of cookies and
 *     localStorage entirely, so no consent banner is required for launch.
 *     Verify the option against the installed SDK before changing it.
 *  2. **No PII, ever.** The submitted email address never leaves the form.
 *     Event properties carry an outcome kind and nothing else.
 *  3. **Off the critical path.** `posthog-js-lite` (~5 KB) is dynamically
 *     imported after the page is idle, so it cannot delay LCP.
 *
 * With no key configured the whole module is inert — `track()` is a no-op and
 * nothing is fetched. That is the correct behaviour for local dev and for any
 * build made before the PostHog project exists.
 */

import { analytics as config } from "./config";

/** The taxonomy is fixed. Adding an event means editing this union. */
export type AnalyticsEvent =
  | { name: "landing_view" }
  | { name: "cta_github_clicked"; props: { placement: "masthead" | "hero" | "install" | "footer" } }
  | { name: "cta_updates_clicked"; props: { placement: "masthead" | "hero" } }
  | { name: "cta_install_clicked"; props: { placement: "hero" } }
  | { name: "signup_submitted" }
  | { name: "signup_succeeded"; props: { status: "subscribed" | "already_subscribed" } }
  | { name: "signup_failed"; props: { kind: SignupFailureKind } };

export type SignupFailureKind =
  | "invalid_email"
  | "rate_limited"
  | "upstream"
  | "network";

type Client = { capture: (event: string, properties?: Record<string, unknown>) => void };

let client: Client | null = null;
let loading: Promise<Client | null> | null = null;
const queue: AnalyticsEvent[] = [];

const enabled = () => config.key.length > 0;

async function load(): Promise<Client | null> {
  if (!enabled()) return null;
  if (client) return client;
  if (loading) return loading;

  loading = import("posthog-js-lite")
    .then(({ PostHog }) => {
      client = new PostHog(config.key, {
        host: config.host,
        // Cookieless: nothing is written to cookies, localStorage, or
        // sessionStorage. Conversion is counted; individuals are not tracked.
        persistence: "memory",
      }) as unknown as Client;
      return client;
    })
    .catch(() => {
      // Analytics must never take the page down with it.
      return null;
    });

  return loading;
}

function send(client: Client, event: AnalyticsEvent) {
  const props = "props" in event ? event.props : undefined;
  client.capture(event.name, props);
}

/** Fire an event. Safe to call before (or without) the SDK ever loading. */
export function track(event: AnalyticsEvent): void {
  if (!enabled()) return;
  if (client) {
    send(client, event);
    return;
  }
  queue.push(event);
  void load().then((loaded) => {
    if (!loaded) {
      queue.length = 0;
      return;
    }
    while (queue.length > 0) {
      const next = queue.shift();
      if (next) send(loaded, next);
    }
  });
}

/**
 * Kick the SDK off once the browser is idle, then record the page view.
 * Called once from App on mount.
 */
export function init(): void {
  if (!enabled()) return;

  const start = () => track({ name: "landing_view" });

  if (typeof window.requestIdleCallback === "function") {
    window.requestIdleCallback(start, { timeout: 4000 });
  } else {
    window.setTimeout(start, 2000);
  }
}
