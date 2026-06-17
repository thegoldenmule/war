import { defineConfig } from "tsup";

/**
 * tsup build config for @war/logic.
 *
 * Builds the public API surface (src/index.ts) to dist/ in both ESM and CJS
 * with type declarations. The validator service and any tooling consume the
 * built `dist` package; the logic itself stays dependency-free so it remains
 * trivially portable and byte-for-byte comparable with the GDScript twin.
 */
export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  dts: true,
  sourcemap: true,
  clean: true,
  treeshake: true,
  target: "es2022",
});
