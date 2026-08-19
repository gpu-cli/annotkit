// Prints the WCAG 2.1 contrast table for the token pairs the page actually
// renders. Hallmark gates 40–41 and the L1 acceptance criterion ("AA contrast
// table recorded in the PR") are both satisfied by `node scripts/contrast.mjs`.
//
// Token values are mirrored here from src/styles/tokens.css. If you change a
// colour there, change it here and re-run — CI runs this as a check.

const TOKENS = {
  paper:       [96.5, 0.010, 78],
  "paper-2":   [93.5, 0.012, 78],
  "paper-3":   [90.0, 0.013, 76],
  rule:        [86.0, 0.011, 76],
  "rule-2":    [64.0, 0.014, 70],
  neutral:     [56.0, 0.012, 62],
  muted:       [43.0, 0.015, 55],
  "ink-2":     [32.0, 0.017, 48],
  ink:         [22.0, 0.018, 48],
  accent:      [51.0, 0.145, 45],
  "accent-ink":[97.5, 0.008, 78],
  focus:       [45.0, 0.160, 45],
  error:       [47.0, 0.180, 25],
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
// [ text token, background token, threshold, where it appears ]
const PAIRS = [
  ["ink", "paper", 4.5, "body copy, headings"],
  ["ink", "paper-2", 4.5, "copy inside the code block"],
  ["ink", "paper-3", 4.5, "figure caption plate"],
  ["ink-2", "paper", 4.5, "standfirst, section leads"],
  ["muted", "paper", 4.5, "dateline, captions, privacy line"],
  ["muted", "paper-2", 4.5, "code-block label"],
  ["neutral", "paper", 3.0, "hairline labels (large/decorative only)"],
  ["accent", "paper", 4.5, "section numbers, link underlines, error-free marks"],
  ["accent", "paper-2", 4.5, "accent inside the code block"],
  ["accent-ink", "accent", 4.5, "text on the one accent-filled surface"],
  ["focus", "paper", 3.0, "focus ring against the page"],
  ["focus", "paper-2", 3.0, "focus ring against a tinted field"],
  ["error", "paper", 4.5, "form error message"],
  ["rule-2", "paper", 3.0, "input border (UI boundary)"],
];

const rgb = Object.fromEntries(
  Object.entries(TOKENS).map(([k, v]) => [k, oklchToRgb(v)]),
);

let failed = 0;
const rows = PAIRS.map(([fg, bg, min, where]) => {
  const r = ratio(rgb[fg], rgb[bg]);
  const pass = r >= min;
  if (!pass) failed++;
  return { fg, bg, r, min, pass, where };
});

const pad = (s, n) => String(s).padEnd(n);
console.log("\nAnnotKit · token contrast (WCAG 2.1)\n");
console.log(
  pad("text", 12) + pad("on", 10) + pad("hex", 9) + pad("ratio", 9) + pad("min", 6) + pad("", 6) + "where",
);
console.log("-".repeat(96));
for (const row of rows) {
  console.log(
    pad(row.fg, 12) +
      pad(row.bg, 10) +
      pad(hex(rgb[row.fg]), 9) +
      pad(row.r.toFixed(2) + ":1", 9) +
      pad(row.min + ":1", 6) +
      pad(row.pass ? "PASS" : "FAIL", 6) +
      row.where,
  );
}
console.log("-".repeat(96));
console.log(`${rows.length - failed}/${rows.length} pass\n`);

if (failed > 0) process.exit(1);
