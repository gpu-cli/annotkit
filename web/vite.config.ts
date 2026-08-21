import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

import { DEFAULT_SITE_URL } from "./shared/site";
import { highlight } from "./plugins/highlight";

/**
 * Substitutes `%SITE_URL%` in index.html so the canonical and OpenGraph URLs
 * cannot drift from `src/config.ts`. A preview deploy can point them at its
 * own origin by setting VITE_SITE_URL in the Pages build environment.
 */
function siteUrl(url: string): Plugin {
  return {
    name: "annotkit-site-url",
    transformIndexHtml: (html) => html.replaceAll("%SITE_URL%", url.replace(/\/$/, "")),
  };
}

// One page, no router, no state library. The performance budget in the epic
// (§8.5) is ~60 KB gzip of JS — keep this config boring and the deps few.
export default defineConfig(({ mode }) => {
  const url = process.env.VITE_SITE_URL ?? DEFAULT_SITE_URL;
  return {
    plugins: [react(), siteUrl(url), highlight()],
    build: {
      target: "es2022",
      cssCodeSplit: false,
      sourcemap: mode !== "production",
      // The page is a single entry; a manual chunk split would only add a
      // round-trip on a connection we are trying to keep short.
      rollupOptions: { output: { manualChunks: undefined } },
    },
    server: { port: 5173 },
  };
});
