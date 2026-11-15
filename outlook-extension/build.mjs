// Bundles the extension into dist/ (load it in Chrome with "Load unpacked").
import { build } from "esbuild";
import { copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";

const entries = ["content", "options", "background"].filter((n) => existsSync(`src/${n}.ts`));

rmSync("dist", { recursive: true, force: true });
mkdirSync("dist");
await build({
  entryPoints: Object.fromEntries(entries.map((n) => [n, `src/${n}.ts`])),
  outdir: "dist",
  bundle: true,
  format: "iife",
  target: "chrome120",
  logLevel: "info",
});
copyFileSync("manifest.json", "dist/manifest.json");
copyFileSync("src/options.html", "dist/options.html");
console.log(`built dist/ (${entries.join(", ")})`);
