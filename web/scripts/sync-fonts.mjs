// Copies the three latin woff2 faces out of the @fontsource packages into
// public/fonts/ under stable, unhashed names so index.html can preload them
// and tokens.css can declare @font-face against a path we control.
//
// Three files, latin subset only, roman only (italic display is banned —
// Hallmark gate 38a). Run by `npm run build`; safe to re-run.
import { copyFileSync, mkdirSync, existsSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const out = resolve(root, "public/fonts");

const FACES = [
  {
    from: "node_modules/@fontsource-variable/fraunces/files/fraunces-latin-wght-normal.woff2",
    to: "fraunces-latin-wght-normal.woff2",
  },
  {
    from: "node_modules/@fontsource-variable/newsreader/files/newsreader-latin-wght-normal.woff2",
    to: "newsreader-latin-wght-normal.woff2",
  },
  {
    from: "node_modules/@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2",
    to: "ibm-plex-mono-latin-400-normal.woff2",
  },
];

mkdirSync(out, { recursive: true });

let bytes = 0;
for (const face of FACES) {
  const src = resolve(root, face.from);
  if (!existsSync(src)) {
    console.error(`sync-fonts: missing ${face.from} — run npm install first.`);
    process.exit(1);
  }
  copyFileSync(src, resolve(out, face.to));
  bytes += statSync(src).size;
}

console.log(`sync-fonts: ${FACES.length} woff2 → public/fonts (${(bytes / 1024).toFixed(0)} KB)`);
