// Prints the WCAG 2.1 contrast table for the token pairs the page actually
// renders, in BOTH themes. Hallmark gates 40–41 and the L1 acceptance
// criterion ("AA contrast table recorded in the PR") are both satisfied by
// `node scripts/contrast.mjs`.
//
// The palettes are READ from src/styles/tokens.css, not mirrored here. They
// used to be mirrored, with a comment asking you to remember to update both;
// a second palette doubles the number of values that can silently drift, and
// a contrast check measuring last month's colours is worse than none.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const tokensCss = readFileSync(
  resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles/tokens.css"),
  "utf8",
);

/**
 * Pulls the `--color-*` declarations out of one selector's block.
 *
 * Two notations, because the palette holds two kinds of colour. Everything
 * derived from this page's own scheme is an `oklch(L% C H)`, which is what
 * makes the palette legible as a system. `--color-gpu` is a hex, because it
 * is a constant borrowed from another brand and re-deriving it would be the
 * only way to get it wrong. Each is stored as its notation and normalised to
 * linear sRGB at the point of comparison.
 */
function palette(selector) {
  const at = tokensCss.indexOf(selector + " {");
  if (at === -1) throw new Error(`contrast: no ${selector} block in tokens.css`);
  const block = tokensCss.slice(at, tokensCss.indexOf("\n}", at));
  const out = {};

  const oklchRe = /--color-([a-z0-9-]+):\s*oklch\(\s*([\d.]+)%\s+([\d.]+)\s+([\d.]+)\s*\)/g;
  for (const m of block.matchAll(oklchRe)) out[m[1]] = { oklch: [+m[2], +m[3], +m[4]] };

  const hexRe = /--color-([a-z0-9-]+):\s*#([0-9a-fA-F]{6})\b/g;
  for (const m of block.matchAll(hexRe)) {
    const hex = m[2];
    out[m[1]] = { srgb: [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255) };
  }

  return out;
}

const THEMES = {
  light: palette(":root"),
  dark: palette(':root[data-theme="dark"]'),
};

// ── OKLCH → sRGB ─────────────────────────────────────────────────────────────
function oklchToRgb([L, C, H]) {
  const l = L / 100;
  const a = C * Math.cos((H * Math.PI) / 180);
  const b = C * Math.sin((H * Math.PI) / 180);

  const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = l - 0.0894841775 * a - 1.291485548 * b;

  const L3 = l_ ** 3, M3 = m_ ** 3, S3 = s_ ** 3;

  const lin = [
    +4.0767416621 * L3 - 3.3077115913 * M3 + 0.2309699292 * S3,
    -1.2684380046 * L3 + 2.6097574011 * M3 - 0.3413193965 * S3,
    -0.0041960863 * L3 - 0.7034186147 * M3 + 1.707614701 * S3,
  ];
  return lin.map((v) => Math.min(1, Math.max(0, v)));
}

/** sRGB 0–1 → linear-light, the space the luminance sum wants. */
const srgbToLinear = (channels) =>
  channels.map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));

/** Either notation → linear-light sRGB. */
const toLinear = (value) =>
  value.oklch ? oklchToRgb(value.oklch) : srgbToLinear(value.srgb);

const relLuminance = (linRgb) =>
  0.2126 * linRgb[0] + 0.7152 * linRgb[1] + 0.0722 * linRgb[2];

const ratio = (a, b) => {
  const [hi, lo] = [relLuminance(a), relLuminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

const hex = (linRgb) =>
  "#" +
  linRgb
    .map((v) => {
      const s = v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055;
      return Math.round(Math.min(1, Math.max(0, s)) * 255)
        .toString(16)
        .padStart(2, "0");
    })
    .join("");

// ── The pairs the page renders ───────────────────────────────────────────────
// [ text token, background token, threshold, where it appears, waived? ]
//
// A fifth element makes the row a WAIVER: the ratio is still computed and
// still printed, and a shortfall reports as WAIVED with its reason instead of
// failing the run. That is for a pair the maintainer has instructed against
// the measurement — it keeps the number in front of whoever reads this table
// rather than letting the row be deleted, which is what actually happens to
// gates that block a decision someone has already made. Add one only with a
// reason you would be willing to defend in the design record.
const PAIRS = [
  ["ink", "paper", 4.5, "body copy, headings"],
  ["ink", "paper-2", 4.5, "copy inside the code block"],
  ["ink", "paper-3", 4.5, "figure caption plate"],
  ["ink-2", "paper", 4.5, "standfirst, section leads"],
  ["muted", "paper", 4.5, "dateline, captions, privacy line"],
  ["muted", "paper-2", 4.5, "code-block label, scrollbar thumb"],
  ["neutral", "paper", 3.0, "hairline labels (large/decorative only)"],
  ["accent", "paper", 4.5, "section numbers, link underlines, error-free marks"],
  ["accent", "paper-2", 4.5, "accent inside the code block"],
  ["accent-ink", "accent", 4.5, "the submit, and the sub-footer band"],
  ["focus", "paper", 3.0, "focus ring against the page"],
  ["focus", "paper-2", 3.0, "focus ring against a tinted field"],
  ["error", "paper", 4.5, "form error message"],
  ["rule-2", "paper", 3.0, "input border, figure frame (UI boundary)"],
  [
    "gpu",
    "accent",
    4.5,
    "the GPU CLI link, on hover and on focus",
    "#19DC6A is GPU CLI's brand value and was specified exactly; the band it " +
      "sits on was specified as the accent. The two cannot both hold and also " +
      "clear AA. Written up under Maintainer feedback in .hallmark/slop-test.md.",
  ],
];

let failed = 0;
let total = 0;
const waivers = [];

const pad = (s, n) => String(s).padEnd(n);
console.log("\nAnnotKit · token contrast (WCAG 2.1)");

for (const [theme, tokens] of Object.entries(THEMES)) {
  const rgb = Object.fromEntries(Object.entries(tokens).map(([k, v]) => [k, toLinear(v)]));

  const rows = PAIRS.map(([fg, bg, min, where, waived]) => {
    if (!rgb[fg]) throw new Error(`contrast: ${theme} palette has no --color-${fg}`);
    if (!rgb[bg]) throw new Error(`contrast: ${theme} palette has no --color-${bg}`);
    const r = ratio(rgb[fg], rgb[bg]);
    const pass = r >= min;
    if (!pass && waived) waivers.push({ theme, fg, bg, r, min, why: waived });
    else if (!pass) failed++;
    total++;
    return { fg, bg, r, min, verdict: pass ? "PASS" : waived ? "WAIVED" : "FAIL", where };
  });

  console.log(`\n  ${theme.toUpperCase()}\n`);
  console.log(
    pad("text", 12) + pad("on", 10) + pad("hex", 9) + pad("ratio", 9) + pad("min", 6) + pad("", 8) + "where",
  );
  console.log("-".repeat(98));
  for (const row of rows) {
    console.log(
      pad(row.fg, 12) +
        pad(row.bg, 10) +
        pad(hex(rgb[row.fg]), 9) +
        pad(row.r.toFixed(2) + ":1", 9) +
        pad(row.min + ":1", 6) +
        pad(row.verdict, 8) +
        row.where,
    );
  }
  console.log("-".repeat(98));
}

console.log(
  `\n${total - failed - waivers.length}/${total} pass across ${Object.keys(THEMES).length} themes` +
    (waivers.length ? `, ${waivers.length} waived` : "") +
    (failed ? `, ${failed} FAILED` : "") +
    "\n",
);

for (const w of waivers) {
  console.log(`  WAIVED · ${w.theme} · ${w.fg} on ${w.bg} — ${w.r.toFixed(2)}:1 against ${w.min}:1`);
  console.log(`           ${w.why}\n`);
}

if (failed > 0) process.exit(1);
