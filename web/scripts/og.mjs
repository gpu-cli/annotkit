/**
 * Renders public/og.png (1200×630) from scripts/og-template.html.
 *
 * The card is built from the same tokens and the same fonts as the page, so
 * regenerating it after a copy or palette change is one command rather than a
 * design-tool round trip:
 *
 *   npm run og
 *
 * Serves the project root itself so `/src/styles/tokens.css` and `/fonts/*`
 * resolve exactly as they do in dev. Validate the result with opengraph.xyz
 * before launch (epic §8.6).
 */

import { createServer } from "node:http";
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";
import { connect, launch, openPage, sleep } from "./lib/chrome.mjs";

const OUT = resolve("public/og.png");
const TEMPLATE = "/scripts/og-template.html";
const SIZE = { width: 1200, height: 630 };

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css",
  ".woff2": "font/woff2",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

const root = resolve(".");

// `tokens.css` sits under src/ and its @font-face rules point at /fonts/*,
// which live in public/. Serve both trees from one origin.
const server = createServer((request, response) => {
  const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
  const candidates = [join(root, path), join(root, "public", path)];
  const file = candidates.find((candidate) => existsSync(candidate) && statSync(candidate).isFile());

  if (!file || !file.startsWith(root)) {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, { "Content-Type": MIME[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(response);
});

await new Promise((done) => server.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${server.address().port}`;

if (!existsSync(resolve("public/fonts/fraunces-latin-wght-normal.woff2"))) {
  console.error("og: public/fonts is empty — run `npm run fonts` first.");
  process.exit(1);
}

const { child, endpoint } = await launch();
const cdp = connect(endpoint);
await cdp.ready;
const session = await openPage(cdp);

await cdp.send("Emulation.setDeviceMetricsOverride", { ...SIZE, deviceScaleFactor: 1, mobile: false }, session);
await cdp.send("Page.navigate", { url: origin + TEMPLATE }, session);
await sleep(2500); // fonts

const { result } = await cdp.send(
  "Runtime.evaluate",
  { expression: "document.fonts.status", returnByValue: true },
  session,
);
if (result.value !== "loaded") console.warn("og: fonts reported", result.value);

const shot = await cdp.send(
  "Page.captureScreenshot",
  { format: "png", clip: { x: 0, y: 0, ...SIZE, scale: 1 }, captureBeyondViewport: true },
  session,
);

writeFileSync(OUT, Buffer.from(shot.data, "base64"));

cdp.close();
child.kill();
server.close();

const bytes = readFileSync(OUT).length;
console.log(`og: public/og.png · ${SIZE.width}×${SIZE.height} · ${(bytes / 1024).toFixed(0)} KB`);
