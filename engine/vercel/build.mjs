// Builds the engine for Vercel: vercel/dist/engine.mjs (one ES module for Node). Run by Vercel (vercel.json
// buildCommand) and by `npm run test:vercel`.
import { build } from "esbuild";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "../migrations");
const migrations = {
  name: "migrations",
  setup(b) {
    b.onResolve({ filter: /^virtual:migrations$/ }, () => ({ path: "migrations", namespace: "virtual" }));
    b.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({
      contents: `export const MIGRATIONS = ${JSON.stringify(readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort()
        .map((f) => [f, readFileSync(join(migrationsDir, f), "utf8")]))};`, loader: "js",
    }));
  },
};
await build({
  entryPoints: [join(here, "engine.js")],
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node20",
  outfile: join(here, "dist/engine.mjs"),
  loader: { ".md": "text", ".client.js": "text" },
  external: ["@libsql/client"],
  plugins: [migrations],
  logLevel: "warning",
  banner: { js: "// Built by engine/vercel/build.mjs from engine/src. Do not edit." },
});
console.log("built vercel/dist/engine.mjs");
