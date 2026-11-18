// Builds the engine for the Mac app (Mac only mode): one script, mac/Resources/engine.js, run by JavaScriptCore.
// Usage: node local/build.mjs   (npm run build:mac)
import { build } from "esbuild";
import { readdirSync, readFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "../migrations");
const out = process.env.FLOATBOARD_ENGINE_OUT || join(here, "../../mac/Resources/engine.js");   // the env: tests only
mkdirSync(dirname(out), { recursive: true });

const migrations = {
  name: "migrations",
  setup(b) {
    b.onResolve({ filter: /^virtual:migrations$/ }, () => ({ path: "migrations", namespace: "virtual" }));
    b.onLoad({ filter: /.*/, namespace: "virtual" }, () => {
      const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
      const list = files.map((f) => [f, readFileSync(join(migrationsDir, f), "utf8")]);
      return { contents: `export const MIGRATIONS = ${JSON.stringify(list)};`, loader: "js" };
    });
  },
};

// The Claude SDK can read local files and run commands for credentials when on Node; the engine never uses that
// (it always passes the key), so Node's built-in modules are empty stand-ins here.
const nodeStubs = {
  name: "node-stubs",
  setup(b) {
    b.onResolve({ filter: /^node:/ }, (a) => ({ path: a.path, namespace: "node-stub" }));
    b.onLoad({ filter: /.*/, namespace: "node-stub" }, () => ({ contents: "export default {};", loader: "js" }));
  },
};

await build({
  entryPoints: [join(here, "entry.js")],
  bundle: true,
  format: "iife",
  platform: "neutral",
  mainFields: ["browser", "module", "main"],
  conditions: ["worker", "browser", "import", "default"],
  target: "es2022",
  outfile: out,
  loader: { ".md": "text", ".client.js": "text" },
  plugins: [migrations, nodeStubs],
  legalComments: "none",
  logLevel: "warning",
  banner: { js: "// Built from engine/ by engine/local/build.mjs. Do not edit: run `npm run build:mac` in engine/." },
});
console.log("built", out);
