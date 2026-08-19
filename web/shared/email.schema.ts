import { z } from "zod";
import { MAX_EMAIL_LENGTH } from "./email";

/**
 * The authoritative email schema. Server-side only — importing this into the
 * client would drag zod into the critical-path bundle (see ./email.ts).
 */
export const emailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .min(3)
  .max(MAX_EMAIL_LENGTH)
  .email();

/** Normalised address, or null when the input does not parse. */
export function parseEmailStrict(raw: unknown): string | null {
  const result = emailSchema.safeParse(raw);
  return result.success ? result.data : null;
}
