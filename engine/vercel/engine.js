// The engine on Vercel (docs/architecture.md, Edition 2, C3): the same engine code as on Cloudflare, with Turso
// (libSQL, the same SQLite dialect as D1) as its database. Bundled by vercel/build.mjs into vercel/dist/engine.mjs,
// which api/engine.js and api/cron.js load. Migrations run on the first request after each deploy.
import { createClient } from "@libsql/client";
import engine from "../src/index";
import { MIGRATIONS } from "virtual:migrations";
import { d1, migrate } from "./d1-libsql.js";

let ready = null;
function setup() {
  ready ??= (async () => {
    const url = process.env.TURSO_DATABASE_URL ?? process.env.LIBSQL_URL;
    if (!url) throw new Error("TURSO_DATABASE_URL is not set: add a Turso database to this Vercel project");
    const client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
    await migrate(client, MIGRATIONS);
    for (const k of ["ENC_KEY", "ADMIN_KEY"]) if (!process.env[k]) throw new Error(`${k} is not set in this Vercel project's environment variables`);
    return { DB: d1(client), ENC_KEY: process.env.ENC_KEY, ADMIN_KEY: process.env.ADMIN_KEY, PLATFORM: "vercel" };
  })().catch((e) => { ready = null; throw e; });
  return ready;
}

/** `waitUntil` from Vercel when present, else the work is awaited before answering (slower, never lost). */
function context(pending) {
  return { waitUntil: (p) => pending.push(Promise.resolve(p).catch((e) => console.warn("background work failed:", e?.message ?? e))), passThroughOnException() {} };
}

export async function handle(req, waitUntil) {
  const env = await setup();
  const pending = [];
  const res = await engine.fetch(req, env, context(pending));
  if (pending.length) { if (waitUntil) waitUntil(Promise.all(pending)); else await Promise.all(pending); }
  return res;
}

export async function scheduled(at = Date.now()) {
  const env = await setup();
  const pending = [];
  await engine.scheduled({ cron: "*/5 * * * *", scheduledTime: at, noRetry() {} }, env, context(pending));
  await Promise.all(pending);
}

/** Tests: start from a different database. */
export function resetForTesting() { ready = null; }
