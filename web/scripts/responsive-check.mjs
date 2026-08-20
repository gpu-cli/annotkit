/**
 * Drives headless Chrome over the DevTools protocol to verify the responsive
 * floor the epic sets (§6.4) and Hallmark gates 34, 49, and 50 enforce:
 *
 *   34 · the document never scrolls horizontally
 *   49 · no button, nav link, or CTA label wraps to two lines
 *   50 · no image-bearing grid track pushes the layout past the viewport
 *
 * Chrome's own window is clamped to a 500 px minimum, so `--window-size` alone
 * cannot test 320 px — the metrics have to be overridden through CDP.
 *
 *   node scripts/responsive-check.mjs [--shots <dir>] [--url <url>]
 *
 * With no --url it serves ./dist itself. Exits non-zero on any failure.
 */

import { createServer } from "node:http";
import { createReadStream, existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";
import { connect, launch, openPage, sleep } from "./lib/chrome.mjs";

const WIDTHS = [320, 375, 414, 768, 1280];
const HEIGHT = 900;

/** Affordances that must read as one line at every width. */
const AFFORDANCES = [
  ".link",
  ".mast__nav a",
  ".foot__links a",
  ".foot__powered",
  ".submit",
  ".copy",
  ".skip",
].join(", ");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".json": "application/json",
  ".webm": "video/webm",
  ".avif": "image/avif",
  ".webp": "image/webp",
};

// ── args ─────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const flag = (name) => {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
};
const shotDir = flag("--shots");
let url = flag("--url");

// ── static server (only when no --url was given) ─────────────────────────────

async function serveDist() {
  const root = resolve("dist");
  if (!existsSync(root)) {
    console.error("responsive-check: dist/ is missing — run `npm run build` first.");
    process.exit(1);
  }

  const server = createServer((request, response) => {
    const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
    let file = join(root, path);
    if (!file.startsWith(root)) {
      response.writeHead(403).end();
      return;
    }
    if (!existsSync(file) || statSync(file).isDirectory()) file = join(root, "index.html");
    response.writeHead(200, { "Content-Type": MIME[extname(file)] ?? "application/octet-stream" });
    createReadStream(file).pipe(response);
  });

  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  return { server, origin: `http://127.0.0.1:${server.address().port}/` };
}

// ── the page-side probe ──────────────────────────────────────────────────────

const PROBE = (selector) => `(() => {
  const doc = document.documentElement;
  const overflow = Math.max(doc.scrollWidth, document.body.scrollWidth) - window.innerWidth;

  const widest = [...document.querySelectorAll("body *")]
    .map((node) => ({ node, right: node.getBoundingClientRect().right }))
    .filter((entry) => entry.right > window.innerWidth + 1)
    .sort((a, b) => b.right - a.right)
    .slice(0, 5)
    .map((entry) => entry.node.className || entry.node.tagName);

  // Measure the stacked height, not the rect count. An inline-flex affordance
  // (label + arrow glyph, vertically centred) yields several rects at several
  // tops on a SINGLE line, so both counting rects and counting tops would call
  // every one of them wrapped. A real wrap is the only thing that makes the
  // union of the rects meaningfully taller than the tallest single rect.
  const wrapped = [...document.querySelectorAll(${JSON.stringify(selector)})]
    .filter((node) => {
      const range = document.createRange();
      range.selectNodeContents(node);
      const rects = [...range.getClientRects()];
      if (rects.length < 2) return false;
      const top = Math.min(...rects.map((rect) => rect.top));
      const bottom = Math.max(...rects.map((rect) => rect.bottom));
      const tallest = Math.max(...rects.map((rect) => rect.height));
      return bottom - top > tallest * 1.5;
    })
    .map((node) => node.textContent.trim().slice(0, 40));

  return JSON.stringify({ overflow, widest, wrapped });
})()`;

// ── run ──────────────────────────────────────────────────────────────────────

let server;
if (!url) {
  const served = await serveDist();
  server = served.server;
  url = served.origin;
}

const { child, endpoint } = await launch();
const cdp = connect(endpoint);
await cdp.ready;
const sessionId = await openPage(cdp);

if (shotDir) mkdirSync(shotDir, { recursive: true });

let failures = 0;
console.log(`\nresponsive-check · ${url}\n`);

for (const width of WIDTHS) {
  await cdp.send(
    "Emulation.setDeviceMetricsOverride",
    { width, height: HEIGHT, deviceScaleFactor: 1, mobile: width < 768 },
    sessionId,
  );
  await cdp.send("Page.navigate", { url }, sessionId);
  await sleep(1200);

  const { result } = await cdp.send(
    "Runtime.evaluate",
    { expression: PROBE(AFFORDANCES), returnByValue: true },
    sessionId,
  );
  const report = JSON.parse(result.value);

  const problems = [];
  if (report.overflow > 0) {
    problems.push(`horizontal overflow of ${report.overflow}px (gate 34)`);
    if (report.widest.length) problems.push(`  widest: ${report.widest.join(", ")}`);
  }
  if (report.wrapped.length > 0) {
    problems.push(`affordance wraps to two lines (gate 49): ${report.wrapped.join(" · ")}`);
  }

  if (problems.length === 0) {
    console.log(`  ${String(width).padStart(4)}px  PASS`);
  } else {
    failures++;
    console.log(`  ${String(width).padStart(4)}px  FAIL`);
    for (const problem of problems) console.log(`          ${problem}`);
  }

  if (shotDir) {
    const shot = await cdp.send(
      "Page.captureScreenshot",
      { format: "png", captureBeyondViewport: true },
      sessionId,
    );
    writeFileSync(join(shotDir, `w${width}.png`), Buffer.from(shot.data, "base64"));
  }
}

console.log("");
cdp.close();
child.kill();
server?.close();

process.exit(failures > 0 ? 1 : 0);
