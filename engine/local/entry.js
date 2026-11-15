// Entry point of the engine as it runs inside the Mac app (Mac only mode, docs/architecture.md C2).
// The same engine code as online; only the platform differs: `env.DB` is the Mac's local SQLite file (through
// `__fb.sql*`), the schedule is a timer in the app, and requests come straight from the app (no network listener).
import "./runtime.js";
import { bytesToB64, b64ToBytes } from "./runtime.js";
import engine from "../src/index";
import { MIGRATIONS } from "virtual:migrations";

const host = globalThis.__fb;

// ---- D1 on the Mac's SQLite -----------------------------------------------------------------------------------------
const norm = (v) => (v === undefined ? null : typeof v === "boolean" ? (v ? 1 : 0) : v);
function call(fn, ...args) {
  const out = JSON.parse(fn(...args));
  if (out.error) throw new Error(`D1_ERROR: ${out.error}`);
  return out;
}
class Statement {
  constructor(sql, params = []) { this.sql = sql; this.params = params; }
  bind(...p) { return new Statement(this.sql, p.map(norm)); }
  _exec() { return call(host.sql, this.sql, JSON.stringify(this.params)); }
  async all() { const r = this._exec(); return { results: r.rows, success: true, meta: { changes: r.changes, last_row_id: r.last_row_id, duration: 0 } }; }
  async first(col) { const r = this._exec(); const row = r.rows[0]; if (!row) return null; return col === undefined ? row : (row[col] ?? null); }
  async run() { const r = this._exec(); return { results: r.rows, success: true, meta: { changes: r.changes, last_row_id: r.last_row_id, duration: 0 } }; }
  async raw(opts) { const r = this._exec(); const rows = r.rows.map((o) => Object.values(o)); return opts?.columnNames ? [r.rows[0] ? Object.keys(r.rows[0]) : [], ...rows] : rows; }
}
const DB = {
  prepare: (sql) => new Statement(sql),
  async batch(stmts) {
    const out = call(host.sqlBatch, JSON.stringify(stmts.map((s) => ({ sql: s.sql, params: s.params }))));
    return out.results.map((r) => ({ results: r.rows, success: true, meta: { changes: r.changes, last_row_id: r.last_row_id, duration: 0 } }));
  },
  async exec(sql) { call(host.sqlExec, sql); return { count: 1, duration: 0 }; },
  dump: async () => { throw new Error("dump is not available on this Mac"); },
};

// Applies the engine's migrations that this Mac's database hasn't had yet (same files as online, in order).
function migrate() {
  call(host.sqlExec, "CREATE TABLE IF NOT EXISTS _local_migrations(name TEXT PRIMARY KEY, applied TEXT NOT NULL)");
  const done = new Set(call(host.sql, "SELECT name FROM _local_migrations", "[]").rows.map((r) => r.name));
  let applied = 0;
  for (const [name, sql] of MIGRATIONS) {
    if (done.has(name)) continue;
    call(host.sqlExec, "BEGIN;" + sql + `;INSERT INTO _local_migrations(name,applied) VALUES('${name.replace(/'/g, "''")}', '${new Date().toISOString()}');COMMIT;`);
    applied++;
  }
  return applied;
}

const pending = new Set();
const env = () => ({ DB, ENC_KEY: host.secret("ENC_KEY"), ADMIN_KEY: host.secret("ADMIN_KEY"), ON_DEVICE: host.secret("ON_DEVICE") });
const ctx = { waitUntil(p) { const q = Promise.resolve(p).catch((e) => console.warn("background work failed:", e?.message ?? String(e))); pending.add(q); q.finally(() => pending.delete(q)); },
  passThroughOnException() {} };

globalThis.FloatBoardEngine = {
  migrate,
  /** One request from the app: {url, method, headers, body (base64|null)} → {status, headers, body (base64)}. */
  async handle(reqJSON) {
    const r = JSON.parse(reqJSON);
    const req = new Request(r.url, { method: r.method, headers: r.headers, body: r.body == null ? null : b64ToBytes(r.body) });
    const res = await engine.fetch(req, env(), ctx);
    const body = new Uint8Array(await res.arrayBuffer());
    return JSON.stringify({ status: res.status, headers: [...res.headers], body: bytesToB64(body) });
  },
  /** One schedule tick, as Cloudflare's cron would run it. */
  async scheduled(cron, atMillis) {
    await engine.scheduled({ cron, scheduledTime: atMillis, noRetry() {} }, env(), ctx);
    await Promise.all([...pending]);
    return "ok";
  },
  /** Waits for background work started by requests (tests and shutdown). */
  async idle() { while (pending.size) await Promise.all([...pending]); return "ok"; },
};
