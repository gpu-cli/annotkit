import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleSubscribe, type Env } from "../functions/api/subscribe";

/**
 * One test per row of the §8.2 status table, plus the request shape we send
 * to Resend. `fetch` is stubbed throughout — these tests never touch the
 * network, and the L3 acceptance criterion that exercises the real API is a
 * curl against a preview deploy, not this file.
 */

const SEGMENT = "seg_test_0001";

function env(overrides: Partial<Env> = {}): Env {
  return {
    RESEND_API_KEY: "re_test_key",
    RESEND_SEGMENT_ID: SEGMENT,
    ...overrides,
  };
}

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://annotkit.gpu-cli.sh/api/subscribe", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

/** An in-memory stand-in for the SUBSCRIBE_RL KV binding. */
function memoryKv() {
  const store = new Map<string, string>();
  return {
    store,
    get: async (key: string) => store.get(key) ?? null,
    put: async (key: string, value: string) => {
      store.set(key, value);
    },
  };
}

const resendResponse = (status: number, body = "{}") =>
  new Response(body, { status, headers: { "Content-Type": "application/json" } });

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn(async () => resendResponse(201, JSON.stringify({ id: "c_1" })));
  vi.stubGlobal("fetch", fetchMock);
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("method handling", () => {
  it.each(["GET", "PUT", "DELETE", "PATCH"])("%s is 405 with an Allow header", async (method) => {
    const response = await handleSubscribe(
      new Request("https://annotkit.gpu-cli.sh/api/subscribe", { method }),
      env(),
    );

    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("validation", () => {
  it.each([
    ["no at sign", "devexample.com"],
    ["no domain", "dev@"],
    ["empty", ""],
    ["whitespace only", "   "],
    ["not a string", 42],
    ["missing", undefined],
    ["over 254 chars", `${"a".repeat(250)}@example.com`],
  ])("400 invalid_email — %s", async (_label, email) => {
    const response = await handleSubscribe(post({ email }), env());

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "invalid_email" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("400 invalid_email on a body that is not JSON", async () => {
    const response = await handleSubscribe(post("{ not json"), env());

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "invalid_email" });
  });

  it("trims and lowercases before sending upstream", async () => {
    await handleSubscribe(post({ email: "  DEV@Example.COM  " }), env());

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(String(init.body)).email).toBe("dev@example.com");
  });
});

describe("honeypot", () => {
  it("200 subscribed, and never calls Resend", async () => {
    const response = await handleSubscribe(
      post({ email: "dev@example.com", url: "http://spam.example" }),
      env(),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "subscribed" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("is indistinguishable from a real success", async () => {
    const trap = await handleSubscribe(post({ email: "a@example.com", url: "x" }), env());
    const real = await handleSubscribe(post({ email: "a@example.com", url: "" }), env());

    expect(trap.status).toBe(real.status);
    await expect(trap.json()).resolves.toEqual(await real.json());
  });
});

describe("Resend", () => {
  it("200 subscribed on a created contact", async () => {
    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "subscribed" });
  });

  it("posts to the Contacts endpoint with the segment, not an audience", async () => {
    await handleSubscribe(post({ email: "dev@example.com" }), env());

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.resend.com/contacts");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer re_test_key");

    const sent = JSON.parse(String(init.body));
    expect(sent).toEqual({
      email: "dev@example.com",
      unsubscribed: false,
      segments: [{ id: SEGMENT }],
      properties: { source: "landing-page" },
    });
    expect(sent).not.toHaveProperty("audience_id");
  });

  it.each([
    ["409 conflict", 409, "{}"],
    ["422 with a duplicate message", 422, JSON.stringify({ message: "Contact already exists" })],
    ["400 with a duplicate message", 400, JSON.stringify({ message: "already subscribed" })],
  ])("200 already_subscribed — %s", async (_label, status, body) => {
    fetchMock.mockResolvedValueOnce(resendResponse(status, body));

    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "already_subscribed" });
  });

  it("429 rate_limited when Resend throttles us", async () => {
    fetchMock.mockResolvedValueOnce(resendResponse(429, "{}"));

    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toEqual({ error: "rate_limited" });
  });

  it.each([
    ["500", 500],
    ["401 — bad key", 401],
    ["403 — key lacks Contacts:write", 403],
    ["422 without a duplicate message", 422],
  ])("502 upstream — %s", async (_label, status) => {
    fetchMock.mockResolvedValueOnce(resendResponse(status, JSON.stringify({ message: "nope" })));

    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: "upstream" });
  });

  it("502 upstream when the fetch itself throws", async () => {
    fetchMock.mockRejectedValueOnce(new Error("connection reset"));

    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: "upstream" });
  });

  it.each([
    ["no API key", { RESEND_API_KEY: undefined }],
    ["no segment id", { RESEND_SEGMENT_ID: undefined }],
    ["empty segment id", { RESEND_SEGMENT_ID: "" }],
    // The placeholders wrangler.jsonc ships with. Non-empty, so a truthiness
    // check would call Resend with a segment that cannot exist.
    ["unreplaced segment placeholder", { RESEND_SEGMENT_ID: "REPLACE_WITH_PRODUCTION_SEGMENT_ID" }],
    ["unreplaced key placeholder", { RESEND_API_KEY: "REPLACE_WITH_RESEND_API_KEY" }],
  ])("502 upstream when misconfigured — %s", async (_label, overrides) => {
    const response = await handleSubscribe(
      post({ email: "dev@example.com" }),
      env(overrides as Partial<Env>),
    );

    expect(response.status).toBe(502);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("never leaks upstream detail to the client", async () => {
    fetchMock.mockResolvedValueOnce(
      resendResponse(500, JSON.stringify({ message: "re_live_secret leaked here" })),
    );

    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    await expect(response.text()).resolves.toBe('{"error":"upstream"}');
  });
});

describe("rate limiting", () => {
  it("allows the first five requests from an IP and blocks the sixth", async () => {
    const kv = memoryKv();
    const headers = { "CF-Connecting-IP": "203.0.113.7" };

    for (let attempt = 0; attempt < 5; attempt++) {
      const response = await handleSubscribe(
        post({ email: `dev+${attempt}@example.com` }, headers),
        env({ SUBSCRIBE_RL: kv }),
      );
      expect(response.status).toBe(200);
    }

    const blocked = await handleSubscribe(
      post({ email: "dev+6@example.com" }, headers),
      env({ SUBSCRIBE_RL: kv }),
    );

    expect(blocked.status).toBe(429);
    await expect(blocked.json()).resolves.toEqual({ error: "rate_limited" });
    expect(fetchMock).toHaveBeenCalledTimes(5);
  });

  it("counts per IP, not globally", async () => {
    const kv = memoryKv();

    for (let attempt = 0; attempt < 5; attempt++) {
      await handleSubscribe(
        post({ email: `a+${attempt}@example.com` }, { "CF-Connecting-IP": "203.0.113.7" }),
        env({ SUBSCRIBE_RL: kv }),
      );
    }

    const other = await handleSubscribe(
      post({ email: "b@example.com" }, { "CF-Connecting-IP": "198.51.100.4" }),
      env({ SUBSCRIBE_RL: kv }),
    );

    expect(other.status).toBe(200);
  });

  it("is off when the KV binding is absent", async () => {
    for (let attempt = 0; attempt < 8; attempt++) {
      const response = await handleSubscribe(
        post({ email: `dev+${attempt}@example.com` }, { "CF-Connecting-IP": "203.0.113.7" }),
        env(),
      );
      expect(response.status).toBe(200);
    }
  });
});

describe("CORS", () => {
  it("sends no Access-Control-Allow-Origin header — same origin only", async () => {
    const response = await handleSubscribe(post({ email: "dev@example.com" }), env());

    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});
