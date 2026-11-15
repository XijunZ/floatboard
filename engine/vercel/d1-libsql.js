// The engine's database (Cloudflare D1's API) on libSQL / Turso, which speaks the same SQLite dialect, so every query
// in the engine runs unchanged. Used by the Vercel build (docs/architecture.md, Edition 2, C3).
const norm = (v) => (v === undefined ? null : typeof v === "boolean" ? (v ? 1 : 0) : v);
const plain = (row, columns) => {
  const o = {};
  for (const c of columns) { const v = row[c]; o[c] = typeof v === "bigint" ? Number(v) : v instanceof ArrayBuffer ? new Uint8Array(v) : v; }
  return o;
};
const shape = (rs) => ({ results: rs.rows.map((r) => plain(r, rs.columns)), success: true,
  meta: { changes: rs.rowsAffected, last_row_id: rs.lastInsertRowid == null ? 0 : Number(rs.lastInsertRowid), duration: 0 } });

class Statement {
  constructor(client, sql, params = []) { this.client = client; this.sql = sql; this.params = params; }
  bind(...p) { return new Statement(this.client, this.sql, p.map(norm)); }
  async all() { return shape(await this.client.execute({ sql: this.sql, args: this.params })); }
  async run() { return this.all(); }
  async first(col) { const r = await this.all(); const row = r.results[0]; if (!row) return null; return col === undefined ? row : (row[col] ?? null); }
  async raw(opts) {
    const rs = await this.client.execute({ sql: this.sql, args: this.params });
    const rows = rs.rows.map((r) => rs.columns.map((c) => plain(r, rs.columns)[c]));
    return opts?.columnNames ? [rs.columns, ...rows] : rows;
  }
}

export function d1(client) {
  return {
    prepare: (sql) => new Statement(client, sql),
    async batch(stmts) { return (await client.batch(stmts.map((s) => ({ sql: s.sql, args: s.params })), "write")).map(shape); },
    async exec(sql) { await client.executeMultiple(sql); return { count: 1, duration: 0 }; },
    dump: async () => { throw new Error("dump is not available here"); },
  };
}

/** Applies the engine's migrations this database hasn't had yet, in order (each in one transaction). */
export async function migrate(client, migrations) {
  await client.execute("CREATE TABLE IF NOT EXISTS _engine_migrations(name TEXT PRIMARY KEY, applied TEXT NOT NULL)");
  const done = new Set((await client.execute("SELECT name FROM _engine_migrations")).rows.map((r) => r.name));
  let applied = 0;
  for (const [name, sql] of migrations) {
    if (done.has(name)) continue;
    await client.executeMultiple(`BEGIN;\n${sql}\n;INSERT INTO _engine_migrations(name,applied) VALUES('${name.replace(/'/g, "''")}', '${new Date().toISOString()}');\nCOMMIT;`);
    applied++;
  }
  return applied;
}
