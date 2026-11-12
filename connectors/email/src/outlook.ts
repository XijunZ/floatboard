/**
 * Outlook on the web: rows the FloatBoard Chrome extension (connectors/outlook-web) read from the user's own signed-in
 * Outlook tab arrive at POST /ingest/outlook with an ingest-only token. The token is not the user key: it can only add
 * rows to (and report problems for) its one source, and it opens nothing else on the engine. Rows are stored once by
 * their key and judged later by the triage run (src/sources/outlook.ts).
 *
 * Answers the extension relies on: 2xx = the whole batch is acknowledged (rows it couldn't use are skipped, never
 * refused, so one bad row can't block its queue); 401/403 = token rejected; 409 = a different mailbox than the one this
 * source is connected to; anything else = try again later.
 */
import { randomToken, sha256Hex } from "./auth";
import { type Env, json, nowISO } from "./env";
import { readJSON } from "./http";
import { logEvent } from "./runlog";
import { Budget, CALLS_PER_INVOCATION } from "./budget";
import { recordCrash, runUser } from "./run";
import { alertFor } from "./alerts";
import { zonedParts } from "./time";

export const OUTLOOK_KIND = "outlook_web";
export const WRONG_MAILBOX = "This isn't the connected Outlook mailbox";
/** Most rows one request may carry (the extension sends at most 50). */
const MAX_ITEMS = 500;
const KEEP_PROCESSED_MS = 30 * 86400e3;

/** Create the user's Outlook source, or give it a new token. The token exists in clear only in the return value. */
export async function issueOutlookToken(env: Env, userId: string): Promise<{ id: string; token: string; created: boolean }> {
  const token = `fbo_${randomToken(32)}`, hash = await sha256Hex(token);
  const existing = await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind='outlook_web'").bind(userId).first<{ id: string }>();
  if (existing) {
    await env.DB.prepare("UPDATE sources SET hook_id=? WHERE id=?").bind(hash, existing.id).run();
    return { id: existing.id, token, created: false };
  }
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,hook_id,enabled,created) VALUES(?,?,'outlook_web','',?,1,?)")
    .bind(id, userId, hash, nowISO()).run();
  return { id, token, created: true };
}

/** A row as stored: the extension's Row after checking. */
export type OutlookRow = { key: string; fromName: string; fromAddr: string | null; subject: string; preview: string; received: string };

const text = (v: unknown, max: number): string | null => (typeof v === "string" ? v.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").trim().slice(0, max) : null);

/** The extension's Row (src/parse.ts) checked and trimmed, or null when it can't be used. */
export function readRow(x: unknown): OutlookRow | null {
  if (!x || typeof x !== "object") return null;
  const r = x as Record<string, unknown>;
  if (r.unread === false) return null; // only unread rows become tasks
  const rowId = typeof r.rowId === "string" ? r.rowId.trim() : "";
  if (!rowId || rowId.length > 1000) return null;
  const t = typeof r.received === "string" ? Date.parse(r.received) : NaN;
  if (!Number.isFinite(t)) return null;
  const fromName = text(r.fromName, 200), subject = text(r.subject, 500), preview = text(r.preview, 2000);
  if (fromName === null || subject === null || preview === null) return null;
  const addr = r.fromAddr === undefined || r.fromAddr === null ? "" : text(r.fromAddr, 320);
  if (addr === null) return null;
  const received = new Date(t).toISOString();
  return { key: `owa:${rowId}:${received}`, fromName, fromAddr: addr ? addr.toLowerCase() : null, subject, preview, received };
}

/** Rows judged more than 30 days ago go (unjudged rows are kept until the run gets to them). */
export function pruneOutlookRows(env: Env, userId: string) {
  return env.DB.prepare("DELETE FROM outlook_rows WHERE user_id=? AND processed=1 AND processed_at < ?")
    .bind(userId, new Date(Date.now() - KEEP_PROCESSED_MS).toISOString());
}

type Src = { id: string; user_id: string; address: string; enabled: number };

/** POST /ingest/outlook. `afterStore` runs once new rows are stored (triage right away, in the background). */
export async function ingestOutlook(req: Request, env: Env, afterStore?: (userId: string) => void): Promise<Response> {
  const m = /^Bearer\s+(\S+)\s*$/.exec(req.headers.get("Authorization") ?? "");
  if (!m || m[1].length > 200) return json({ error: "unauthorized" }, 401);
  const src = await env.DB.prepare("SELECT id, user_id, address, enabled FROM sources WHERE kind='outlook_web' AND hook_id=?")
    .bind(await sha256Hex(m[1])).first<Src>();
  if (!src) return json({ error: "unauthorized" }, 401);
  if (!src.enabled) return json({ error: "This Outlook connection is turned off" }, 403);
  const rb = await readJSON(req);
  if (!rb.ok) return rb.res;
  const body = rb.body as Record<string, unknown>;
  const items = body.items ?? [];
  if (!Array.isArray(items) || items.length > MAX_ITEMS) return json({ error: `items must be a list of at most ${MAX_ITEMS}` }, 400);
  if (body.problem !== undefined && typeof body.problem !== "string") return json({ error: "problem must be text" }, 400);
  if (body.mailbox !== undefined && body.mailbox !== null && typeof body.mailbox !== "string") return json({ error: "mailbox must be text" }, 400);
  const mailbox = typeof body.mailbox === "string" ? body.mailbox.trim().toLowerCase().slice(0, 320) : "";
  const problem = typeof body.problem === "string" ? text(body.problem, 300) : null;
  const now = nowISO();

  // A problem report (page not recognised, signed in to another mailbox, ...): always acknowledged so the extension
  // stops resending it, shown in needs attention, and it never sets or checks the mailbox.
  if (problem !== null && items.length === 0) {
    await env.DB.batch([
      env.DB.prepare("UPDATE sources SET last_error=?, last_run=? WHERE id=?").bind(problem || "The Chrome extension reported a problem", now, src.id),
      logEvent(env, { run_id: "outlook", user_id: src.user_id, source: "Outlook", decision: "extension reported a problem", detail: problem }),
    ]);
    return json({ ok: true, stored: 0, duplicates: 0, skipped: 0 });
  }

  // One mailbox per source: the first send names it; any other is refused (the extension then stops sending its rows).
  let address = src.address;
  if (mailbox && !address) {
    await env.DB.prepare("UPDATE sources SET address=? WHERE id=? AND address=''").bind(mailbox, src.id).run();
    address = (await env.DB.prepare("SELECT address FROM sources WHERE id=?").bind(src.id).first<{ address: string }>())?.address ?? "";
  }
  if (mailbox && address && mailbox !== address) {
    const msg = `${WRONG_MAILBOX} (${mailbox} was refused)`;
    await env.DB.batch([
      env.DB.prepare("UPDATE sources SET last_error=?, last_run=? WHERE id=?").bind(msg, now, src.id),
      logEvent(env, { run_id: "outlook", user_id: src.user_id, source: address, decision: "Outlook rows refused: another mailbox", detail: mailbox }),
    ]);
    return json({ error: WRONG_MAILBOX }, 409);
  }

  const rows = items.map(readRow);
  const good = rows.filter((r): r is OutlookRow => r !== null);
  const skipped = rows.length - good.length;
  const results = good.length ? await env.DB.batch(good.map((r) => env.DB.prepare(`INSERT OR IGNORE INTO outlook_rows
      (user_id,source_id,row_key,from_name,from_addr,subject,preview,received,created) VALUES(?,?,?,?,?,?,?,?,?)`)
    .bind(src.user_id, src.id, r.key, r.fromName, r.fromAddr, r.subject, r.preview, r.received, now))) : [];
  const stored = results.filter((r) => r.meta.changes > 0).length;
  // Rows read, or a mailbox read from the page, mean the page and the mailbox are fine again: an earlier problem
  // clears. A connection test (no rows, no mailbox) proves only the token, so it changes nothing but last_run.
  const stmts = [items.length || mailbox
    ? env.DB.prepare("UPDATE sources SET last_run=?, last_error=NULL WHERE id=?").bind(now, src.id)
    : env.DB.prepare("UPDATE sources SET last_run=? WHERE id=?").bind(now, src.id),
  pruneOutlookRows(env, src.user_id)];
  if (skipped) stmts.push(logEvent(env, { run_id: "outlook", user_id: src.user_id, source: address || "Outlook",
    decision: "Outlook rows skipped: unreadable", detail: `${skipped} of ${rows.length} rows` }));
  await env.DB.batch(stmts);
  if (stored && afterStore) afterStore(src.user_id);
  return json({ ok: true, stored, duplicates: good.length - stored, skipped });
}

/** New rows judged right after they arrive (in the background of the ingest request): at most this many, the rest by the hourly run. */
export const JUDGE_NOW = 5;

/** Judge up to JUDGE_NOW waiting Outlook rows now. Never throws: a crash is recorded as a run like any other. */
export async function judgeOutlookNow(env: Env, userId: string, fetchFn?: typeof fetch): Promise<void> {
  const started = nowISO();
  // The run plans 2 calls a message and keeps 3 spare (Outlook rows need only the Claude call; the rest may go to alerts).
  const calls = new Budget(Math.min(CALLS_PER_INVOCATION, 2 * JUDGE_NOW + 4));
  try {
    const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
    if (!u?.anthropic_key_enc) return; // nothing can be judged yet; the hourly run says why
    await runUser(env, userId, { kinds: [OUTLOOK_KIND], budget: JUDGE_NOW, calls, fetchFn, alert: alertFor(env, userId) });
  } catch (e) {
    await recordCrash(env, userId, started, e, calls.used);
  }
}

const WORKING_DAYS_SILENT = 2;
export const SILENT_NOTICE = "Outlook hasn't reported for 2 working days: sign in to Outlook in Chrome, or check the FloatBoard extension.";

/**
 * True when the extension hasn't reported for 2 working days since `since`: the same time of day two working days
 * (Monday to Friday, as the days fall in `zone`) later has passed. Friday 17:00 -> Tuesday 17:00.
 */
export function outlookSilent(since: string, now: Date, zone: string): boolean {
  const t0 = Date.parse(since);
  if (!Number.isFinite(t0)) return false;
  let t = t0;
  for (let n = 0; n < WORKING_DAYS_SILENT; n++) {
    do t += 86400e3; while (["Saturday", "Sunday"].includes(zonedParts(new Date(t), zone).weekday));
  }
  return now.getTime() > t;
}
