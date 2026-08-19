import { describe, expect, it } from "vitest";
import { parseEmail } from "../shared/email";
import { parseEmailStrict } from "../shared/email.schema";

/**
 * The client validator is a hand-rolled mirror of the server's zod schema
 * (see shared/email.ts for why). This file is the thing that keeps them
 * honest: for every address in the table, both must reach the same verdict
 * and, when they accept, the same normalised value.
 *
 * A form that accepts what the function rejects is a visitor watching a
 * spinner turn into an error for no reason they can see.
 */

const ADDRESSES = [
  // Accepted
  "dev@example.com",
  "  DEV@Example.COM  ",
  "first.last@example.co.uk",
  "user+tag@example.io",
  "a_b-c@sub.domain.example",
  "x@y.zz",
  "numbers123@example123.dev",

  // Rejected
  "",
  "   ",
  "devexample.com",
  "dev@",
  "@example.com",
  "dev@@example.com",
  "dev @example.com",
  "dev@example",
  "dev@.com",
  "dev@example..com",
  "dev@-example.com",
  "dev@example-.com",
  ".dev@example.com",
  "dev.@example.com",
  "de..v@example.com",
  "dev@example.com ,other@example.com",
  `${"a".repeat(250)}@example.com`,
  "a@b",
];

describe("client mirror agrees with the zod authority", () => {
  it.each(ADDRESSES)("%j", (address) => {
    expect(parseEmail(address)).toBe(parseEmailStrict(address));
  });

  it.each([undefined, null, 42, {}, [], true])("rejects the non-string %j", (value) => {
    expect(parseEmail(value)).toBeNull();
    expect(parseEmailStrict(value)).toBeNull();
  });
});

describe("normalisation", () => {
  it("trims and lowercases", () => {
    expect(parseEmail("  DEV@Example.COM ")).toBe("dev@example.com");
  });

  it("caps at the RFC 5321 path length", () => {
    const local = "a".repeat(254 - "@example.com".length);
    expect(parseEmail(`${local}@example.com`)).not.toBeNull();
    expect(parseEmail(`${local}a@example.com`)).toBeNull();
  });
});
