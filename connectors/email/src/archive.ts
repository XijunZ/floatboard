/**
 * Database size, and "Archive old data to this Mac" (docs/phone-app.md, last section).
 *
 * - `dbSizeBytes`: the D1 database's size, from `meta.size_after` on a cheap statement (else page_count * page_size).
 *   Shown on the setup page and in `GET /v2/status` as `db_size_bytes`.
 * - `GET /v2/archive?before=<ISO>&cursor=<opaque>` (user key): one archive run is the first ARCHIVE_MAX_ROWS rows of this
 *   user's archivable rows, in this order: `board_log` rows received before `before`, by id; then `items` rows created
 *   before `before`, by id. Items are only included when `before` is at least 90 days ago (newer items stop the same
 *   email making a task twice), and an action item whose link is an open task on the Mac's board copy is kept (its done
 *   event still needs it). `before` must be at least 30 days ago. Pages of up to 500 rows; `cursor` is null after the
 *   last page of the run. Rows are in canonical form (see below) and never carry `user_id`; an `add` log row's title is
 *   decrypted (the Mac already holds it).
 * - `POST /v2/archive/confirm { before, counts: { board_log, items }, sha256 }`: the engine builds the same run again and
 *   deletes exactly those rows, in one batch, only when the counts and the hash match (409 otherwise, nothing deleted).
 *   Each deleted item leaves a tombstone in `archived_items` (user, message id).
 *
 * Canonical form, shared with the Mac (FloatBoardConnectors/EngineArchive.swift): each row is a JSON object whose values
 * are text, whole numbers or null, keys sorted; one line per row is `{"row":{...},"table":"board_log"|"items"}` written
 * by JSON.stringify (no spaces; only `"`, `\` and control characters escaped; `\b \f \n \r \t`, else `\u00xx`), each
 * line ending in "\n". The run's hash is the lowercase hex SHA-256 of those lines' UTF-8 bytes, in run order: exactly
 * the bytes of the file the Mac writes.
 */
import { type Env, json, nowISO } from "./env";
import { decrypt } from "./crypto";
import { readCappedJSON } from "./http";
import { route } from "./router";

export const ARCHIVE_PAGE = 500;
/** Rows in one archive run (one GET series and one confirm): keeps the confirm within a Worker's limits. */
export const ARCHIVE_MAX_ROWS = 2000;
export const LOG_MIN_AGE_DAYS = 30;
export const ITEM_MIN_AGE_DAYS = 90;
/** D1's limit per database on the free plan, and the size from which the setup page warns. */
export const DB_LIMIT_BYTES = 500_000_000;
export const DB_WARN_BYTES = 250_000_000;

const DAY = 86400_000;

/** The database's size in bytes, or null when D1 doesn't say. */
export async function dbSizeBytes(env: Env): Promise<number | null> {
  try {
    const r = await env.DB.prepare("SELECT 1").run();
    const s = (r.meta as { size_after?: unknown }).size_after;
    if (typeof s === "number" && s > 0) return s;
  } catch { /* fall through */ }
  try {
    const pc = await env.DB.prepare("PRAGMA page_count").first<{ page_count: number }>();
    const ps = await env.DB.prepare("PRAGMA page_size").first<{ page_size: number }>();
    if (pc && ps && pc.page_count > 0 && ps.page_size > 0) return pc.page_count * ps.page_size;
  } catch { /* not available */ }
  return null;
}

// ---------------------------------------------------------------- canonical form

export type Table = "board_log" | "items";
type Canon = string | number | null;
export type ArchiveRow = { table: Table; row: Record<string, Canon> };

/** A value in canonical form: text (lone surrogates replaced by U+FFFD), a whole number, or null. Anything else becomes text. */
function canonValue(v: unknown): Canon {
  if (v === null || v === undefined) return null;
  if (typeof v === "number" && Number.isSafeInteger(v)) return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  const s = String(v);
  if (!/[\ud800-\udfff]/.test(s)) return s;
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && s.charCodeAt(i + 1) >= 0xdc00 && s.charCodeAt(i + 1) <= 0xdfff) { out += s[i] + s[i + 1]; i++; }
    else out += c >= 0xd800 && c <= 0xdfff ? "\ufffd" : s[i];
  }
  return out;
}

/** The row with sorted keys and canonical values (what the API returns and the hash covers). */
export function canonRow(row: Record<string, unknown>): Record<string, Canon> {
  const out: Record<string, Canon> = {};
  for (const k of Object.keys(row).sort()) out[k] = canonValue(row[k]);
  return out;
}

/** One line of the archive file (without its "\n"). */
export function canonLine(table: Table, row: Record<string, unknown>): string {
  return JSON.stringify({ row: canonRow(row), table });
}

export const archiveText = (rows: ArchiveRow[]) => rows.map((r) => canonLine(r.table, r.row) + "\n").join("");

export async function sha256Hex(text: string): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------------------------------------------------------------- the run

const LOG_COLS = "id, device, card_id, kind, value, made_at, received_at, client_id";
const ITEM_COLS = "id, source_id, message_id, kind, title, why, sender, subject, link, snippet, due, has_time, importance, group_name, "
  + "task_ref, summary, critical, alerted, created, sent_at, history_id";

type Position = { t: Table; a: string; n: number };
type Sel = { userId: string; before: string; items: boolean; openLinks: Set<string> };

/** Validates `before`: an ISO time at least 30 days ago. Items are included only when it is at least 90 days ago. */
function parseBefore(raw: unknown, nowMs: number): { before: string; items: boolean } | string {
  if (typeof raw !== "string" || raw.length > 40 || Number.isNaN(Date.parse(raw))) return "before must be an ISO date";
  const ms = Date.parse(raw);
  if (ms > nowMs - LOG_MIN_AGE_DAYS * DAY) return `before must be at least ${LOG_MIN_AGE_DAYS} days ago`;
  return { before: new Date(ms).toISOString(), items: ms <= nowMs - ITEM_MIN_AGE_DAYS * DAY };
}

/** Links of tasks still open on the Mac's board copy (their items are kept). */
async function openLinks(env: Env, userId: string): Promise<Set<string>> {
  const row = await env.DB.prepare("SELECT data_enc FROM board_snapshots WHERE user_id=?").bind(userId).first<{ data_enc: string }>();
  if (!row) return new Set();
  const cards = (JSON.parse(await decrypt(env, row.data_enc)).cards ?? []) as { status: string; link: string | null }[];
  return new Set(cards.filter((c) => c.status !== "done" && c.link).map((c) => c.link!));
}

async function selection(env: Env, userId: string, before: { before: string; items: boolean }): Promise<Sel> {
  return { userId, ...before, openLinks: before.items ? await openLinks(env, userId) : new Set() };
}

/** Up to `want` rows of the run from `pos` on, and where the next page starts (null: the run is complete). */
async function readRun(env: Env, sel: Sel, pos: Position, want: number): Promise<{ rows: ArchiveRow[]; next: Position | null }> {
  const rows: ArchiveRow[] = [];
  let { t, a, n } = pos;
  let exhausted = false;
  want = Math.min(want, ARCHIVE_MAX_ROWS - n);
  fill: while (rows.length < want) {
    if (t === "items" && !sel.items) { exhausted = true; break; }
    const sql = t === "board_log"
      ? `SELECT ${LOG_COLS} FROM board_log WHERE user_id=? AND received_at < ? AND id > ? ORDER BY id LIMIT ?`
      : `SELECT ${ITEM_COLS} FROM items WHERE user_id=? AND created < ? AND id > ? ORDER BY id LIMIT ?`;
    const { results } = await env.DB.prepare(sql).bind(sel.userId, sel.before, a, ARCHIVE_PAGE).all<Record<string, unknown>>();
    for (const r of results) {
      a = r.id as string;
      if (t === "items" && r.kind === "action" && typeof r.link === "string" && sel.openLinks.has(r.link)) continue;
      if (t === "board_log" && r.kind === "add" && typeof r.value === "string") {
        try { r.value = await decrypt(env, r.value); } catch { /* kept as stored */ }
      }
      rows.push({ table: t, row: canonRow(r) });
      if (rows.length >= want) break fill;
    }
    if (results.length < ARCHIVE_PAGE) {
      if (t === "items") { exhausted = true; break; }
      t = "items"; a = "";
    }
  }
  n += rows.length;
  return { rows, next: exhausted || n >= ARCHIVE_MAX_ROWS ? null : { t, a, n } };
}

const encodeCursor = (before: string, p: Position) => btoa(JSON.stringify({ b: before, ...p })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function decodeCursor(raw: string, before: string): Position | null {
  try {
    const p = JSON.parse(atob(raw.replace(/-/g, "+").replace(/_/g, "/")));
    if (p.b !== before || (p.t !== "board_log" && p.t !== "items") || typeof p.a !== "string" || p.a.length > 200
      || !Number.isSafeInteger(p.n) || p.n < 0 || p.n > ARCHIVE_MAX_ROWS) return null;
    return { t: p.t, a: p.a, n: p.n };
  } catch { return null; }
}

route("GET", "/v2/archive", async (req, env, user) => {
  const q = new URL(req.url).searchParams;
  const b = parseBefore(q.get("before"), Date.now());
  if (typeof b === "string") return json({ error: b }, 400);
  let pos: Position = { t: "board_log", a: "", n: 0 };
  const c = q.get("cursor");
  if (c) {
    const p = decodeCursor(c, b.before);
    if (!p) return json({ error: "Invalid cursor (it belongs to another cut-off, or is damaged)" }, 400);
    pos = p;
  }
  const { rows, next } = await readRun(env, await selection(env, user.id, b), pos, ARCHIVE_PAGE);
  return json({
    rows: { board_log: rows.filter((r) => r.table === "board_log").map((r) => r.row), items: rows.filter((r) => r.table === "items").map((r) => r.row) },
    cursor: next ? encodeCursor(b.before, next) : null,
  });
});

const count = (v: unknown) => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= ARCHIVE_MAX_ROWS;

route("POST", "/v2/archive/confirm", async (req, env, user) => {
  const rb = await readCappedJSON(req, 10_000);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  const body = rb.body ?? {};
  const b = parseBefore(body.before, Date.now());
  if (typeof b === "string") return json({ error: b }, 400);
  if (!body.counts || typeof body.counts !== "object" || !count(body.counts.board_log) || !count(body.counts.items)) {
    return json({ error: "counts must be { board_log, items } whole numbers" }, 400);
  }
  if (typeof body.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(body.sha256)) return json({ error: "sha256 must be 64 lowercase hex characters" }, 400);
  const { rows } = await readRun(env, await selection(env, user.id, b), { t: "board_log", a: "", n: 0 }, ARCHIVE_MAX_ROWS);
  const logIds = rows.filter((r) => r.table === "board_log").map((r) => r.row.id as string);
  const itemIds = rows.filter((r) => r.table === "items").map((r) => r.row.id as string);
  if (logIds.length !== body.counts.board_log || itemIds.length !== body.counts.items || await sha256Hex(archiveText(rows)) !== body.sha256) {
    return json({ error: "The engine's data changed or doesn't match what was saved; nothing was deleted." }, 409);
  }
  const now = nowISO();
  const stmts: D1PreparedStatement[] = [];
  const chunks = (ids: string[]) => Array.from({ length: Math.ceil(ids.length / 90) }, (_, i) => ids.slice(i * 90, i * 90 + 90));
  for (const part of chunks(itemIds)) {
    const q = part.map(() => "?").join(",");
    stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO archived_items(user_id,message_id,archived_at) SELECT user_id, message_id, ? FROM items WHERE user_id=? AND id IN (${q})`)
      .bind(now, user.id, ...part));
    stmts.push(env.DB.prepare(`DELETE FROM items WHERE user_id=? AND id IN (${q})`).bind(user.id, ...part));
  }
  for (const part of chunks(logIds)) {
    stmts.push(env.DB.prepare(`DELETE FROM board_log WHERE user_id=? AND id IN (${part.map(() => "?").join(",")})`).bind(user.id, ...part));
  }
  if (stmts.length) await env.DB.batch(stmts);
  return json({ ok: true, deleted: { board_log: logIds.length, items: itemIds.length } });
});
