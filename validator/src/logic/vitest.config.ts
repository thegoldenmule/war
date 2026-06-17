import { defineConfig } from "vitest/config";

/**
 * Vitest config for @war/logic.
 *
 * The determinism suite (tests/determinism.test.ts) is the GENERATOR of the
 * golden vector that the GDScript headless verifier checks against. Keep it
 * fast and dependency-free so it can run in CI on every change.
 */
export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    environment: "node",
    globals: false,
  },
});
