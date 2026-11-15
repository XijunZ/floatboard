#!/usr/bin/env node
// One-step engine set-up on your own Cloudflare account (docs/architecture.md, Edition 2, C4):
//   npm run setup            sign in to Cloudflare if needed, create the database, apply its schema, make the two
//                            secrets, deploy, and open the setup page ("Make this engine yours").
//   npm run setup -- --dry-run   print what it would do, change nothing.
// Running it again is safe: whatever already exists is kept.
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = join(dirname(fileURLToPath(import.meta.url)), "..");
const dry = process.argv.includes("--dry-run");
const CONFIG = join(here, "wrangler.local.toml");
const DB = "floatboard";
const wrangler = (args, opts = {}) => {
  if (dry && opts.changes) { console.log("  would run: wrangler " + args.join(" ")); return ""; }
  const r = spawnSync("npx", ["wrangler", ...args], { cwd: here, encoding: "utf8", input: opts.input, stdio: opts.interactive ? "inherit" : ["pipe", "pipe", "pipe"] });
  if (r.status !== 0 && !opts.allowFail) {
    console.error((r.stderr || r.stdout || "").trim());
    throw new Error(`wrangler ${args[0]} failed`);
  }
  return `${r.stdout ?? ""}${r.stderr ?? ""}`;
};
const step = (n, text) => console.log(`\n${n}. ${text}`);

try {
  step(1, "Cloudflare sign-in");
  if (/not authenticated|You are not logged in/i.test(wrangler(["whoami"], { allowFail: true }))) {
    if (dry) console.log("  would open the Cloudflare sign-in in your browser");
    else wrangler(["login"], { interactive: true });
  }
  console.log("  signed in ✓");

  step(2, "Database");
  let id = existsSync(CONFIG) ? /database_id\s*=\s*"([0-9a-f-]{36})"/.exec(readFileSync(CONFIG, "utf8"))?.[1] : undefined;
  if (id && id.startsWith("00000000")) id = undefined;
  if (!id) {
    const list = wrangler(["d1", "list", "--json"], { allowFail: true });
    try { id = JSON.parse(list.slice(list.indexOf("["))).find((d) => d.name === DB)?.uuid; } catch { /* none yet */ }
  }
  if (!id) {
    const out = wrangler(["d1", "create", DB], { changes: true });
    id = /"?database_id"?\s*[:=]\s*"([0-9a-f-]{36})"/.exec(out)?.[1] ?? (dry ? "<new database id>" : undefined);
    if (!id) throw new Error("couldn't read the new database's id from wrangler's answer");
    console.log("  created ✓");
  } else console.log("  found ✓");
  if (!existsSync(CONFIG) || /0{8}-0{4}/.test(readFileSync(CONFIG, "utf8"))) {
    const cfg = readFileSync(join(here, "wrangler.local.toml.example"), "utf8").replace(/database_id = "0{8}-0{4}-0{4}-0{4}-0{12}"/, `database_id = "${id}"`);
    if (dry) console.log("  would write wrangler.local.toml"); else writeFileSync(CONFIG, cfg);
  }

  step(3, "Database schema");
  wrangler(["d1", "migrations", "apply", DB, "--remote", "--config", "wrangler.local.toml"], { changes: true, input: "y\n" });
  console.log("  up to date ✓");

  step(4, "Secrets");
  const have = dry ? "" : wrangler(["secret", "list", "--config", "wrangler.local.toml"], { allowFail: true });
  let admin = null;
  for (const name of ["ENC_KEY", "ADMIN_KEY"]) {
    if (have.includes(`"${name}"`)) { console.log(`  ${name} already set ✓`); continue; }
    const value = randomBytes(32).toString("base64url");
    if (name === "ADMIN_KEY") admin = value;
    wrangler(["secret", "put", name, "--config", "wrangler.local.toml"], { changes: true, input: value + "\n" });
    console.log(`  ${name} made ✓`);
  }

  step(5, "Deploy");
  const out = wrangler(["deploy", "--config", "wrangler.local.toml"], { changes: true });
  const url = /https:\/\/[^\s]+\.workers\.dev/.exec(out)?.[0] ?? (dry ? "https://floatboard.<you>.workers.dev" : null);
  console.log(url ? `  live at ${url} ✓` : "  deployed ✓ (open your engine's address + /setup)");

  step(6, "Make it yours");
  if (admin && !dry) {
    try { execFileSync("pbcopy", { input: admin }); console.log("  Your admin key is on the clipboard: paste it on the page that opens."); }
    catch { console.log(`  Your admin key (keep it somewhere safe): ${admin}`); }
  } else console.log("  Use the admin key you set before (or set a new one: npx wrangler secret put ADMIN_KEY --config wrangler.local.toml).");
  if (url && !dry) spawnSync("open", [`${url}/setup`]);
  console.log("  Then press “Connect to FloatBoard”. Keys (Claude, Google) go in the Mac app: Settings › Keys.\n");
} catch (e) {
  console.error(`\nSet-up stopped: ${e.message}. Fix the problem above and run npm run setup again; finished steps are skipped.`);
  process.exit(1);
}
