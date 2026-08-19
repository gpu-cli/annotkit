/**
 * POST /api/subscribe — Cloudflare Pages Function (epic §8.2).
 *
 * Holds the Resend key server-side and writes one contact into one Resend
 * segment. There is no database of our own: Resend is the store of record.
 *
 * The contract, verbatim from the epic:
 *
 *   200 { status: "subscribed" }          contact created
 *   200 { status: "already_subscribed" }  idempotent — already on the list
 *   200 { status: "subscribed" }          honeypot tripped; no upstream call
 *   400 { error: "invalid_email" }        fails the shared zod schema
 *   405 —                                 non-POST
 *   429 { error: "rate_limited" }         per-IP throttle tripped
 *   502 { error: "upstream" }             Resend failed; logged, not surfaced
 *
 * Segments, not Audiences: Audiences are deprecated and scheduled for removal.
 */

import { parseEmailStrict } from "../../shared/email.schema";

// ── Minimal runtime types ────────────────────────────────────────────────────
// Hand-rolled rather than pulling @cloudflare/workers-types in: the function
// touches exactly two platform surfaces and the types for both fit here.

interface KVNamespace {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
}

export interface Env {
  /** Restricted Resend key — Contacts: write. Pages secret, never a var. */
  RESEND_API_KEY?: string;
  /** Segment the contact joins. One per environment (epic §8.3). */
  RESEND_SEGMENT_ID?: string;
  /** Optional KV binding for the per-IP limiter. Absent → limiter is off. */
  SUBSCRIBE_RL?: KVNamespace;
}

interface EventContext {
  request: Request;
  env: Env;
}

// ── Configuration ────────────────────────────────────────────────────────────

const RESEND_CONTACTS_ENDPOINT = "https://api.resend.com/contacts";

/** Per-IP ceiling. Fixed hourly window — good enough for a signup form. */
const RATE_LIMIT = { max: 5, windowSeconds: 3600 } as const;

const json = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      // Same-origin only: no Access-Control-Allow-Origin header, deliberately.
      "Cache-Control": "no-store",
    },
  });

// ── Handler ──────────────────────────────────────────────────────────────────

export async function handleSubscribe(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    // A body we cannot parse is, from the caller's side, an unusable address.
    return json({ error: "invalid_email" }, 400);
  }

  const body = (payload ?? {}) as Record<string, unknown>;

  // Honeypot. A filled `url` field means a bot: return the success the bot
  // expects, make no upstream call, and leave no signal it can differentiate.
  const honeypot = typeof body.url === "string" ? body.url.trim() : "";
  if (honeypot.length > 0) {
    return json({ status: "subscribed" }, 200);
  }

  const email = parseEmailStrict(body.email);
  if (email === null) {
    return json({ error: "invalid_email" }, 400);
  }

  const limited = await isRateLimited(request, env);
  if (limited) {
    return json({ error: "rate_limited" }, 429);
  }

  const missing = ["RESEND_API_KEY", "RESEND_SEGMENT_ID"].filter(
    (name) => !isConfigured(env[name as "RESEND_API_KEY" | "RESEND_SEGMENT_ID"]),
  );
  if (missing.length > 0) {
    console.error(`subscribe: ${missing.join(" and ")} not configured`);
    return json({ error: "upstream" }, 502);
  }

  return subscribeToResend(email, env);
}

async function subscribeToResend(email: string, env: Env): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(RESEND_CONTACTS_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        unsubscribed: false,
        segments: [{ id: env.RESEND_SEGMENT_ID }],
        properties: { source: "landing-page" },
      }),
    });
  } catch (error) {
    console.error("subscribe: fetch to Resend threw", error);
    return json({ error: "upstream" }, 502);
  }

  if (response.ok) {
    return json({ status: "subscribed" }, 200);
  }

  const detail = await response.text().catch(() => "");

  // Duplicate handling. Resend's create-contact response for an address that
  // is already in the segment is what the L3 spike pins down (epic §8.2); the
  // mapping below covers the shapes the API has been observed to use, and any
  // of them means the same thing to the visitor: you are on the list.
  //
  // TODO(L3 spike): create the same contact twice against the preview
  // segment, record the exact status + body in the PR, and narrow this to the
  // one branch that actually fires. If create turns out not to be idempotent
  // at all, fall back to PATCH /contacts/:email here.
  if (isDuplicate(response.status, detail)) {
    return json({ status: "already_subscribed" }, 200);
  }

  if (response.status === 429) {
    // Resend is throttling us. Say so honestly rather than blaming the visitor
    // with a generic failure.
    console.error("subscribe: Resend rate-limited the request", detail);
    return json({ error: "rate_limited" }, 429);
  }

  console.error(`subscribe: Resend returned ${response.status}`, detail);
  return json({ error: "upstream" }, 502);
}

/**
 * wrangler.jsonc ships `REPLACE_WITH_…` placeholders so the file documents its
 * own shape. They are non-empty strings, so a plain truthiness check would let
 * them through and we would call Resend with a segment id that cannot exist —
 * turning a five-second configuration mistake into a confusing upstream 502.
 * Treat an unreplaced placeholder as absent.
 */
function isConfigured(value: string | undefined): boolean {
  return value !== undefined && value.length > 0 && !value.startsWith("REPLACE_WITH_");
}

function isDuplicate(status: number, detail: string): boolean {
  if (status === 409) return true;
  if (status !== 400 && status !== 422) return false;
  return /already\s+(exists|registered|subscribed|in)/i.test(detail);
}

async function isRateLimited(request: Request, env: Env): Promise<boolean> {
  const kv = env.SUBSCRIBE_RL;
  if (!kv) return false;

  const ip = request.headers.get("CF-Connecting-IP");
  if (!ip) return false;

  const window = Math.floor(Date.now() / 1000 / RATE_LIMIT.windowSeconds);
  const key = `rl:${ip}:${window}`;

  const current = Number.parseInt((await kv.get(key)) ?? "0", 10);
  const count = Number.isNaN(current) ? 0 : current;

  if (count >= RATE_LIMIT.max) return true;

  // Read-modify-write races can undercount under concurrency. For a signup
  // form that is fine: the honeypot and validation are the real filters, and
  // a limiter that occasionally allows a sixth request is not a defect worth
  // a Durable Object.
  await kv.put(key, String(count + 1), { expirationTtl: RATE_LIMIT.windowSeconds });
  return false;
}

// ── Pages Function entry point ───────────────────────────────────────────────

export const onRequest = (context: EventContext): Promise<Response> =>
  handleSubscribe(context.request, context.env);
