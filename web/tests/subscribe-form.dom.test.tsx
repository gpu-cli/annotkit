import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { SubscribeForm } from "../src/components/SubscribeForm";
import { signup } from "../src/copy";

/**
 * The five structural states from epic §7 — default, loading, error, success
 * (new), success (duplicate). The three styling states (hover, focus-visible,
 * active) live in base.css and are not reachable from jsdom.
 */

const jsonResponse = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn(async () => jsonResponse(200, { status: "subscribed" }));
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const input = () => screen.getByLabelText(signup.label) as HTMLInputElement;
const submit = () => screen.getByRole("button", { name: new RegExp(signup.submit, "i") });

async function fillAndSubmit(value: string) {
  fireEvent.change(input(), { target: { value } });
  fireEvent.click(screen.getByRole("button"));
}

describe("default", () => {
  it("shows the helper line and an enabled control pair", () => {
    render(<SubscribeForm />);

    expect(screen.getByText(signup.helper)).toBeTruthy();
    expect(input().disabled).toBe(false);
    expect(submit().hasAttribute("disabled")).toBe(false);
  });
});

describe("client validation", () => {
  it("rejects a malformed address without calling the endpoint", async () => {
    render(<SubscribeForm />);
    await fillAndSubmit("not-an-email");

    await waitFor(() => {
      expect(screen.getByText(signup.errors.invalid_email)).toBeTruthy();
    });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(input().getAttribute("aria-invalid")).toBe("true");
  });

  it("keeps the typed value so the visitor can fix the typo", async () => {
    render(<SubscribeForm />);
    await fillAndSubmit("dev@exampl");

    await waitFor(() => expect(screen.getByText(signup.errors.invalid_email)).toBeTruthy());
    expect(input().value).toBe("dev@exampl");
  });

  it("moves focus to the message so it is not missed", async () => {
    render(<SubscribeForm />);
    await fillAndSubmit("nope");

    await waitFor(() => {
      expect(document.activeElement?.textContent).toBe(signup.errors.invalid_email);
    });
  });
});

describe("loading", () => {
  it("swaps the label, marks itself busy, and disables the pair", async () => {
    let release: (value: Response) => void = () => {};
    fetchMock.mockImplementationOnce(
      () => new Promise<Response>((resolve) => (release = resolve)),
    );

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => {
      expect(screen.getByRole("button", { name: signup.submitLoading })).toBeTruthy();
    });
    const button = screen.getByRole("button", { name: signup.submitLoading });
    expect(button.getAttribute("aria-busy")).toBe("true");
    expect(input().disabled).toBe(true);

    release(jsonResponse(200, { status: "subscribed" }));
    await waitFor(() => expect(screen.getByText(signup.successNew)).toBeTruthy());
  });
});

describe("success", () => {
  it("replaces the form with a confirmation — no toast", async () => {
    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => expect(screen.getByText(signup.successNew)).toBeTruthy());
    expect(screen.queryByLabelText(signup.label)).toBeNull();
    expect(screen.getByRole("status")).toBeTruthy();
  });

  it("says 'already' for a duplicate, in the same shape", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(200, { status: "already_subscribed" }));

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => expect(screen.getByText(signup.successDuplicate)).toBeTruthy());
  });

  it("sends the normalised address and the honeypot field", async () => {
    render(<SubscribeForm />);
    await fillAndSubmit("  DEV@Example.COM ");

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/api/subscribe");
    expect(JSON.parse(String(init.body))).toEqual({ email: "dev@example.com", url: "" });
  });
});

describe("error", () => {
  it.each([
    [429, "rate_limited"],
    [502, "upstream"],
    [400, "invalid_email"],
  ])("renders the %i copy", async (status, kind) => {
    fetchMock.mockResolvedValueOnce(jsonResponse(status, { error: kind }));

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => {
      expect(
        screen.getByText(signup.errors[kind as keyof typeof signup.errors]),
      ).toBeTruthy();
    });
    expect(input().value).toBe("dev@example.com");
  });

  it("names a network failure as a network failure", async () => {
    fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => expect(screen.getByText(signup.errors.network)).toBeTruthy());
  });

  it("clears the error as soon as the visitor edits the field", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse(502, { error: "upstream" }));

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");
    await waitFor(() => expect(screen.getByText(signup.errors.upstream)).toBeTruthy());

    fireEvent.change(input(), { target: { value: "dev2@example.com" } });
    await waitFor(() => expect(screen.getByText(signup.helper)).toBeTruthy());
  });

  it("falls back to the upstream copy when the body is unreadable", async () => {
    fetchMock.mockResolvedValueOnce(new Response("<html>502</html>", { status: 502 }));

    render(<SubscribeForm />);
    await fillAndSubmit("dev@example.com");

    await waitFor(() => expect(screen.getByText(signup.errors.upstream)).toBeTruthy());
  });
});
