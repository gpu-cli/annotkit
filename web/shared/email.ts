/**
 * Email format checking, shared by the form and the Pages Function.
 *
 * Two implementations sit behind one contract, on purpose:
 *
 *  - `parseEmail` is dependency-free and runs in the browser. Pulling zod into
 *    the client bundle costs ~13 KB gzip for one regex, and the epic's
 *    performance budget (§8.5) does not have 13 KB spare.
 *  - `emailSchema` is the zod schema the function validates with. It is the
 *    authority; the client is a mirror of it.
 *
 * `tests/email.test.ts` asserts the two agree over a table of addresses, so
 * the mirror cannot silently drift from the authority.
 *
 * Format only. Never existence: an MX probe is slow, wrong about valid
 * addresses often enough to matter, and not our business.
 */

/** RFC 5321 §4.5.3.1.3 — the longest address a path may carry. */
export const MAX_EMAIL_LENGTH = 254;

/**
 * The shape zod's `.email()` accepts, as a single expression.
 *
 * Note the domain labels allow a TRAILING hyphen (`example-.com`). That is
 * not valid per RFC 1034, but zod accepts it, and the mirror must never be
 * stricter than the authority — a form that rejects an address the server
 * would have taken is a visitor staring at an error nobody can explain.
 * tests/email.test.ts pins this.
 */
const EMAIL_PATTERN =
  /^(?!\.)(?!.*\.\.)[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+(?<!\.)@[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/;

/** Normalised address, or null when the input does not parse. */
export function parseEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  if (value.length < 3 || value.length > MAX_EMAIL_LENGTH) return null;
  return EMAIL_PATTERN.test(value) ? value : null;
}
