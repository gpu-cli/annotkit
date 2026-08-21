import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import { highlight } from "./plugins/highlight";

// Two projects in one run: the Pages Function and validator tests are plain
// node, the page tests need a DOM. Neither pays for the other's setup.
export default defineConfig({
  plugins: [react(), highlight()],
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: "node",
          environment: "node",
          include: ["tests/**/*.test.ts"],
          // `*.dom.test.ts` belongs to the DOM project below. Without this
          // exclude it would match here first and fail on `window`.
          exclude: ["tests/**/*.dom.test.ts"],
        },
      },
      {
        extends: true,
        test: {
          name: "dom",
          environment: "jsdom",
          include: ["tests/**/*.dom.test.ts", "tests/**/*.dom.test.tsx"],
          setupFiles: ["tests/setup.dom.ts"],
        },
      },
    ],
  },
});
