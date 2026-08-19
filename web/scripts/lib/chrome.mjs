/**
 * A minimal headless-Chrome driver over the DevTools protocol.
 *
 * Chrome's own window is clamped to a 500 px minimum width, so `--window-size`
 * cannot reach the 320 px responsive floor and `--screenshot` cannot render a
 * fixed 1200×630 card reliably. Overriding the device metrics through CDP can
 * do both, and needs no Puppeteer.
 */

import { spawn } from "node:child_process";
import { existsSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CANDIDATES = [
  process.env.CHROME_PATH,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
].filter(Boolean);

export const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

export function findChrome() {
  const binary = CANDIDATES.find((candidate) => existsSync(candidate));
  if (!binary) {
    console.error("No Chrome found. Set CHROME_PATH to a Chrome or Chromium binary.");
    process.exit(1);
  }
  return binary;
}

/** Launches Chrome and resolves once it reports its debugger endpoint. */
export async function launch() {
  const profile = mkdtempSync(join(tmpdir(), "annotkit-chrome-"));
  const child = spawn(
    findChrome(),
    [
      "--headless=new",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  const endpoint = await new Promise((done, fail) => {
    let buffer = "";
    const timer = setTimeout(() => fail(new Error("Chrome never reported a debug port")), 20000);
    child.stderr.on("data", (chunk) => {
      buffer += String(chunk);
      const match = buffer.match(/ws:\/\/[^\s]+/);
      if (match) {
        clearTimeout(timer);
        done(match[0]);
      }
    });
  });

  return { child, endpoint };
}

/** One socket, one promise per command. */
export function connect(endpoint) {
  const socket = new WebSocket(endpoint);
  const pending = new Map();
  let nextId = 1;

  const ready = new Promise((done, fail) => {
    socket.addEventListener("open", () => done());
    socket.addEventListener("error", fail);
  });

  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    message.error ? entry.fail(new Error(message.error.message)) : entry.done(message.result);
  });

  return {
    ready,
    send(method, params = {}, sessionId) {
      const id = nextId++;
      return new Promise((done, fail) => {
        pending.set(id, { done, fail });
        socket.send(JSON.stringify({ id, method, params, sessionId }));
      });
    },
    close: () => socket.close(),
  };
}

/** Opens a page target and returns its CDP session id. */
export async function openPage(cdp) {
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  return sessionId;
}
