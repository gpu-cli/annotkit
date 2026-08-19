import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Two projects in one run: the Pages Function and validator tests are plain
// node, the page tests need a DOM. Neither pays for the other's setup.
export default defineConfig({
  plugins: [react()],
  test: {
    projects: [
      {
        extends: true,
        test: {
          name: "node",
          environment: "node",
          include: ["tests/**/*.test.ts"],
        },
      },
      {
        extends: true,
        test: {
          name: "dom",
          environment: "jsdom",
          include: ["tests/**/*.dom.test.tsx"],
          setupFiles: ["tests/setup.dom.ts"],
        },
      },
    ],
  },
});
