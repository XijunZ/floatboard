/**
 * Jots' online copy (docs/superpowers/specs/2026-11-17-jots-design.md §4, features J3, J9, J11, J13).
 *
 * - The Mac sends its jots added in the last 30 days (`PUT /v2/jots`), with the daily nudge's state. Each is stored encrypted
 *   in `jot_copies` under its Mac number; `mac_saved_at` is when the Mac last saved its latest version.
 * - The phone reads the copy (`GET /app/api/jots`: added in the last 30 days, not deleted) and sends captures, edits,
 *   deletes and Make task / Make decision (`POST /app/api/jots`, a batch with `sent_at`; times are moved onto the engine's
 *   clock; each action id is applied once). A change older than the copy's version is "superseded" (newest wins).
 * - Phone changes and Fathom meeting notes wait (`waiting=1`) until the Mac takes them (`GET /v2/jots/waiting`) and acks
 *   them (`POST /v2/jots/ack`, only for the same `rev`, so a newer phone change keeps waiting).
 * - Hourly: a copy is removed 30 days after the Mac saved its latest version; never while a change waits, never before the
 *   Mac has saved it, however long the Mac is off.
 * - Every 5 minutes: the daily nudge by Web Push when the Mac has not shown it within 10 minutes and nobody jotted today.
 */
import { type Env, json, nowISO } from "../env";
import { decrypt, encrypt } from "../lib/crypto";
import { readCappedJSON } from "../lib/http";
import { route } from "../lib/router";
import { logEvent } from "../lib/runlog";
import { isTimeZone, zonedParts } from "../lib/time";
import { alertFor } from "../reminders/alerts";
import type { AlertItem } from "../triage/run";
import { recapKey } from "../sources/fathom";
import type { Message } from "../sources/types";
import { appJSON, requireAppSession, sameOrigin } from "../phone/auth";
import { corrected, skewOf } from "../phone/board";

const DAY = 86400_000;
export const KEEP_DAYS = 30;
const MAX_JOTS = 200;
const MAX_TEXT = 100_000;
const MAX_PHONE_TEXT = 20_000;
const MAX_SELECTION = 2_000;
const MAX_TAGS = 20;
const MAX_TAG = 60;
const MAX_ACTIONS = 100;
const MAX_WAITING = 100;
const MAX_PUT_BYTES = 4_000_000;
const MAX_PHONE_BYTES = 512_000;
const SEEN_KEEP_DAYS = 7;
const NUDGE_GRACE_MS = 10 * 60_000;
const ACTION_ID = /^[A-Za-z0-9-]{8,64}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
export const KINDS = ["jot", "task_note", "meeting_notes"] as const;
const SOURCES = ["typed", "phone", "meeting", "message", "claude"] as const;
const OPS = ["add", "edit", "delete", "restore", "make_task", "make_decision"] as const;

type Row = { key: string; mac_id: number | null; text_enc: string; kind: string; source: string; tags: string; added: string; updated: string;
  deleted: number; waiting: number; rev: number; recap_key: string | null; ref: string | null };
type MacJot = { id: number; text: string; kind: string; source: string; tags: string[]; added: string; updated: string; deleted: boolean };

const isISO = (v: unknown): v is string => typeof v === "string" && !Number.isNaN(Date.parse(v));
const iso = (ms: number) => new Date(ms).toISOString();
const dayOf = (p: Record<string, string>) => `${p.year}-${p.month}-${p.day}`;

/** True while the Mac has Jots switched on (settings.modules, sent with the board). */
export async function jotsOn(env: Env, userId: string): Promise<boolean> {
  const s = await env.DB.prepare("SELECT modules FROM settings WHERE user_id=?").bind(userId).first<{ modules: string | null }>();
  try { return !!(s?.modules && JSON.parse(s.modules)?.jots === true); } catch { return false; }
}

function parseTags(v: unknown): string[] | null {
  if (!Array.isArray(v) || v.length > MAX_TAGS) return null;
  return v.every((t) => typeof t === "string" && t.trim() && t.length <= MAX_TAG) ? (v as string[]) : null;
}

function parseMacJot(j: any, i: number): MacJot | string {
  const at = `jots[${i}]`;
  if (!j || typeof j !== "object") return `${at} must be an object`;
  if (!Number.isInteger(j.id) || j.id < 1) return `${at}.id must be a positive whole number`;
  if (typeof j.text !== "string" || j.text.length > MAX_TEXT) return `${at}.text must be text up to ${MAX_TEXT} characters`;
  if (!(KINDS as readonly string[]).includes(j.kind)) return `${at}.kind must be one of ${KINDS.join(", ")}`;
  if (!(SOURCES as readonly string[]).includes(j.source)) return `${at}.source must be one of ${SOURCES.join(", ")}`;
  const tags = parseTags(j.tags ?? []);
  if (!tags) return `${at}.tags must be up to ${MAX_TAGS} names of 1 to ${MAX_TAG} characters`;
  if (!isISO(j.added) || !isISO(j.updated)) return `${at}.added and .updated must be ISO times`;
  if (typeof j.deleted !== "boolean") return `${at}.deleted must be true or false`;
  return { id: j.id, text: j.text, kind: j.kind, source: j.source, tags, added: iso(Date.parse(j.added)), updated: iso(Date.parse(j.updated)), deleted: j.deleted };
}

type Nudge = { minutes: number | null; zone: string; shown_day: string | null; jotted_day: string | null; done_today: string[] };
function parseNudge(n: any): Nudge | string {
  if (!n || typeof n !== "object") return "nudge must be an object";
  if (n.minutes !== null && !(Number.isInteger(n.minutes) && n.minutes >= 0 && n.minutes < 1440)) return "nudge.minutes must be 0 to 1439 or null";
  if (!isTimeZone(n.zone)) return "nudge.zone must be a time zone";
  for (const k of ["shown_day", "jotted_day"]) if (n[k] !== null && n[k] !== undefined && !(typeof n[k] === "string" && DAY_RE.test(n[k]))) return `nudge.${k} must be YYYY-MM-DD or null`;
  const done = n.done_today ?? [];
  if (!Array.isArray(done) || done.length > 10 || !done.every((t: unknown) => typeof t === "string" && t.length <= 200)) return "nudge.done_today must be up to 10 titles";
  return { minutes: n.minutes, zone: n.zone, shown_day: n.shown_day ?? null, jotted_day: n.jotted_day ?? null, done_today: done };
}

async function rowOut(env: Env, r: Row) {
  return { key: r.key, mac_id: r.mac_id, text: await decrypt(env, r.text_enc), kind: r.kind, source: r.source, tags: JSON.parse(r.tags) as string[],
    added: r.added, updated: r.updated, deleted: !!r.deleted, rev: r.rev };
}

// ---- Mac ----------------------------------------------------------------------------------------

route("PUT", "/v2/jots", async (req, env, user) => {
  const rb = await readCappedJSON(req, MAX_PUT_BYTES);
  if (!rb.ok) return json({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400);
  const list = rb.body.jots ?? [];
  if (!Array.isArray(list) || list.length > MAX_JOTS) return json({ error: `jots must be a list of at most ${MAX_JOTS}` }, 400);
  const jots: MacJot[] = [];
  for (const [i, j] of list.entries()) {
    const p = parseMacJot(j, i);
    if (typeof p === "string") return json({ error: p }, 400);
    jots.push(p);
  }
  let nudge: Nudge | null = null;
  if (rb.body.nudge !== undefined) {
    const n = parseNudge(rb.body.nudge);
    if (typeof n === "string") return json({ error: n }, 400);
    nudge = n;
  }
  const now = nowISO();
  for (const j of jots) {
    const have = await env.DB.prepare("SELECT key, waiting, updated FROM jot_copies WHERE user_id=? AND mac_id=?").bind(user.id, j.id)
      .first<{ key: string; waiting: number; updated: string }>();
    const enc = await encrypt(env, j.text);
    if (!have) {
      await env.DB.prepare(`INSERT INTO jot_copies(user_id,key,mac_id,text_enc,kind,source,tags,added,updated,deleted,mac_saved_at,waiting,rev)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,0,0) ON CONFLICT(user_id,key) DO UPDATE SET mac_id=excluded.mac_id, text_enc=excluded.text_enc, kind=excluded.kind,
          source=excluded.source, tags=excluded.tags, added=excluded.added, updated=excluded.updated, deleted=excluded.deleted, mac_saved_at=excluded.mac_saved_at, waiting=0`)
        .bind(user.id, `J-${j.id}`, j.id, enc, j.kind, j.source, JSON.stringify(j.tags), j.added, j.updated, j.deleted ? 1 : 0, now).run();
    } else if (have.waiting && Date.parse(have.updated) > Date.parse(j.updated)) {
      // A newer phone change waits for the Mac: keep its text; the tags are the Mac's (the phone does not edit them).
      await env.DB.prepare("UPDATE jot_copies SET tags=? WHERE user_id=? AND key=?").bind(JSON.stringify(j.tags), user.id, have.key).run();
    } else {
      await env.DB.prepare(`UPDATE jot_copies SET text_enc=?, kind=?, source=?, tags=?, added=?, updated=?, deleted=?, mac_saved_at=?, waiting=0
          WHERE user_id=? AND key=?`).bind(enc, j.kind, j.source, JSON.stringify(j.tags), j.added, j.updated, j.deleted ? 1 : 0, now, user.id, have.key).run();
    }
  }
  if (nudge) {
    await env.DB.prepare(`INSERT INTO jot_nudges(user_id,minutes,zone,shown_day,jotted_day,done_enc,updated) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(user_id) DO UPDATE SET minutes=excluded.minutes, zone=excluded.zone, shown_day=excluded.shown_day, jotted_day=excluded.jotted_day,
        done_enc=excluded.done_enc, updated=excluded.updated`)
      .bind(user.id, nudge.minutes, nudge.zone, nudge.shown_day, nudge.jotted_day, await encrypt(env, JSON.stringify(nudge.done_today)), now).run();
  }
  return json({ accepted: jots.map((j) => j.id) });
});

route("GET", "/v2/jots/waiting", async (_req, env, user) => {
  const rows = (await env.DB.prepare(`SELECT * FROM jot_copies WHERE user_id=? AND waiting=1 ORDER BY updated, key LIMIT ${MAX_WAITING}`)
    .bind(user.id).all<Row>()).results;
  const out = [];
  for (const r of rows) {
    const o: Record<string, unknown> = await rowOut(env, r);
    if (r.ref) o.ref = r.ref;
    if (r.recap_key) {
      const m = await env.DB.prepare("SELECT recap_key, fathom_url, meeting_url, title, scheduled_start, invitees FROM meetings WHERE user_id=? AND recap_key=?")
        .bind(user.id, r.recap_key).first<{ recap_key: string; fathom_url: string; meeting_url: string; title: string; scheduled_start: string | null; invitees: string }>();
      o.meeting = m ? { ...m, invitees: JSON.parse(m.invitees) } : { recap_key: r.recap_key, fathom_url: "", meeting_url: "", title: "", scheduled_start: null, invitees: [] };
    }
    out.push(o);
  }
  return json({ jots: out });
});

route("POST", "/v2/jots/ack", async (req, env, user) => {
  const rb = await readCappedJSON(req, 200_000);
  if (!rb.ok) return json({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400);
  const items = rb.body.items;
  if (!Array.isArray(items) || items.length > 500) return json({ error: "items must be a list of at most 500" }, 400);
  let acked = 0;
  const now = nowISO();
  for (const it of items) {
    if (!it || typeof it.key !== "string" || !Number.isInteger(it.rev)) return json({ error: "each item needs key and rev" }, 400);
    if (it.mac_id !== undefined && it.mac_id !== null && !(Number.isInteger(it.mac_id) && it.mac_id > 0)) return json({ error: "mac_id must be a positive whole number" }, 400);
    if (it.key.startsWith("action:")) {
      acked += (await env.DB.prepare("DELETE FROM jot_copies WHERE user_id=? AND key=? AND rev=?").bind(user.id, it.key, it.rev).run()).meta.changes;
      continue;
    }
    if (it.mac_id) {
      // A copy the Mac sent under its own number before acking this capture is the same jot: one copy stays.
      await env.DB.prepare("DELETE FROM jot_copies WHERE user_id=? AND mac_id=? AND key<>?").bind(user.id, it.mac_id, it.key).run();
    }
    acked += (await env.DB.prepare(`UPDATE jot_copies SET waiting=0, mac_id=coalesce(?, mac_id), mac_saved_at=? WHERE user_id=? AND key=? AND rev=? AND waiting=1`)
      .bind(it.mac_id ?? null, now, user.id, it.key, it.rev).run()).meta.changes;
  }
  return json({ acked });
});

// ---- Meeting notes (Fathom) ---------------------------------------------------------------------

/** Keeps a meeting's full Fathom notes (summary, action items, link) for the Mac's Jots, once per meeting, while Jots is on. */
export async function recordMeetingNotes(env: Env, userId: string, m: Message): Promise<void> {
  if (!(await jotsOn(env, userId)) || !m.text.trim()) return;
  const key = recapKey(m), now = nowISO();
  await env.DB.prepare(`INSERT OR IGNORE INTO jot_copies(user_id,key,text_enc,kind,source,tags,added,updated,waiting,rev,recap_key)
      VALUES(?,?,?,'meeting_notes','meeting','[]',?,?,1,1,?)`).bind(userId, key, await encrypt(env, m.text.slice(0, MAX_TEXT)), now, now, key).run();
}

// ---- Phone --------------------------------------------------------------------------------------

async function phoneList(env: Env, userId: string, nowMs = Date.now()) {
  const rows = (await env.DB.prepare(`SELECT * FROM jot_copies WHERE user_id=? AND deleted=0 AND kind NOT LIKE 'action:%' AND added>=?
      ORDER BY added DESC, key LIMIT 1000`).bind(userId, iso(nowMs - KEEP_DAYS * DAY)).all<Row>()).results;
  const out = [];
  for (const r of rows) {
    const o = await rowOut(env, r);
    out.push({ key: o.key, text: o.text, kind: o.kind, source: o.source, tags: o.tags, added: o.added, updated: o.updated });
  }
  return out;
}

type Dropped = { id: string | null; reason: string };

async function applyPhone(env: Env, userId: string, a: any, skew: number | null, receivedMs: number): Promise<"ok" | Dropped> {
  const id = typeof a?.id === "string" ? a.id : null;
  if (!id || !ACTION_ID.test(id)) return { id, reason: "bad id" };
  if (await env.DB.prepare("SELECT 1 FROM jot_actions_seen WHERE user_id=? AND id=?").bind(userId, id).first()) return "ok";
  const made = corrected(isISO(a.made_at) ? a.made_at : null, skew, receivedMs) ?? iso(receivedMs);
  const drop = (reason: string): Dropped => ({ id, reason });
  if (!(OPS as readonly string[]).includes(a.op)) return drop("unknown op");
  const text = typeof a.text === "string" ? a.text : "";
  const needsText = a.op === "add" || a.op === "edit" || a.op === "make_task" || a.op === "make_decision";
  const limit = a.op === "make_task" || a.op === "make_decision" ? MAX_SELECTION : MAX_PHONE_TEXT;
  if (needsText && (!text.trim() || text.length > limit)) return drop(text.trim() ? "text too long" : "text is required");
  const seen = env.DB.prepare("INSERT OR IGNORE INTO jot_actions_seen(user_id,id,at) VALUES(?,?,?)").bind(userId, id, iso(receivedMs));
  if (a.op === "add") {
    await env.DB.batch([env.DB.prepare(`INSERT OR IGNORE INTO jot_copies(user_id,key,text_enc,kind,source,tags,added,updated,waiting,rev)
        VALUES(?,?,?,'jot','phone','[]',?,?,1,1)`).bind(userId, `phone:${id}`, await encrypt(env, text), made, made), seen]);
    return "ok";
  }
  const row = typeof a.key === "string"
    ? await env.DB.prepare("SELECT key, updated, deleted FROM jot_copies WHERE user_id=? AND key=? AND kind NOT LIKE 'action:%'").bind(userId, a.key)
      .first<{ key: string; updated: string; deleted: number }>()
    : null;
  if (!row) return drop("unknown jot");
  if (a.op === "make_task" || a.op === "make_decision") {
    await env.DB.batch([env.DB.prepare(`INSERT OR IGNORE INTO jot_copies(user_id,key,text_enc,kind,source,tags,added,updated,waiting,rev,ref)
        VALUES(?,?,?,?,'phone','[]',?,?,1,1,?)`).bind(userId, `action:${id}`, await encrypt(env, text), `action:${a.op}`, made, made, row.key), seen]);
    return "ok";
  }
  if (Date.parse(made) < Date.parse(row.updated)) { await seen.run(); return drop("superseded"); }
  const set = a.op === "edit" ? ["text_enc=?", [await encrypt(env, text)]] as const : ["deleted=?", [a.op === "delete" ? 1 : 0]] as const;
  await env.DB.batch([env.DB.prepare(`UPDATE jot_copies SET ${set[0]}, updated=?, waiting=1, rev=rev+1 WHERE user_id=? AND key=?`)
    .bind(...set[1], made, userId, row.key), seen]);
  return "ok";
}

/** The phone's jots routes (session cookie); null for other paths. */
export async function handleJotsApp(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path !== "/app/api/jots") return null;
  if (req.method === "POST" && !sameOrigin(req)) return appJSON({ error: "refused" }, 403);
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "not signed in" }, 401);
  if (!(await jotsOn(env, s.userId))) return appJSON({ error: "jots_off" }, 409, s.setCookie);
  if (req.method === "GET") return appJSON({ jots: await phoneList(env, s.userId) }, 200, s.setCookie);
  if (req.method !== "POST") return appJSON({ error: "not found" }, 404, s.setCookie);
  const receivedMs = Date.now();
  const rb = await readCappedJSON(req, MAX_PHONE_BYTES);
  if (!rb.ok) return appJSON({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400, s.setCookie);
  const actions = rb.body.actions;
  if (!Array.isArray(actions) || actions.length > MAX_ACTIONS) return appJSON({ error: `actions must be a list of at most ${MAX_ACTIONS}` }, 400, s.setCookie);
  const skew = skewOf(isISO(rb.body.sent_at) ? rb.body.sent_at : null, receivedMs);
  const accepted: string[] = [], dropped: Dropped[] = [];
  for (const a of actions) {
    const r = await applyPhone(env, s.userId, a, skew, receivedMs);
    if (r === "ok") accepted.push(a.id); else dropped.push(r);
  }
  return appJSON({ accepted, dropped, jots: await phoneList(env, s.userId) }, 200, s.setCookie);
}

// ---- Housekeeping and the nudge -----------------------------------------------------------------

/** Hourly: copies the Mac saved more than 30 days ago (and nothing waits on them) go; old action ids go. */
export async function purgeJots(env: Env, nowMs = Date.now()): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM jot_copies WHERE waiting=0 AND mac_saved_at IS NOT NULL AND mac_saved_at<?").bind(iso(nowMs - KEEP_DAYS * DAY)),
    env.DB.prepare("DELETE FROM jot_actions_seen WHERE at<?").bind(iso(nowMs - SEEN_KEEP_DAYS * DAY)),
  ]);
}

/** "Done today: A, B, C and 2 more." (as the Mac words it), or a plain line. */
export function nudgePrompt(done: string[]): string {
  if (!done.length) return "A line about your day, an idea, or what's on your mind.";
  return `Done today: ${done.slice(0, 3).join(", ")}${done.length > 3 ? ` and ${done.length - 3} more.` : "."}`;
}

/**
 * The daily nudge by Web Push: from 10 minutes after its time (the Mac's turn first), on a day the Mac has not shown it and
 * no jot was written (on the Mac, or on the phone), once per day (claimed in due_alerts_sent). Never throws.
 */
export async function runJotNudges(env: Env, nowMs = Date.now(),
    sender: (env: Env, userId: string) => (item: AlertItem) => Promise<void> = alertFor): Promise<number> {
  let sent = 0;
  const rows = (await env.DB.prepare("SELECT * FROM jot_nudges WHERE minutes IS NOT NULL").all<{ user_id: string; minutes: number; zone: string;
    shown_day: string | null; jotted_day: string | null; done_enc: string | null }>()).results;
  for (const n of rows) {
    try {
      if (!(await jotsOn(env, n.user_id))) continue;
      const p = zonedParts(new Date(nowMs), n.zone);
      const day = dayOf(p);
      if (Number(p.hour) * 60 + Number(p.minute) < n.minutes + NUDGE_GRACE_MS / 60_000) continue;
      if (n.shown_day === day || n.jotted_day === day) continue;
      const phone = (await env.DB.prepare(`SELECT added FROM jot_copies WHERE user_id=? AND kind='jot' AND source IN ('typed','phone') AND deleted=0 AND added>=?`)
        .bind(n.user_id, iso(nowMs - 2 * DAY)).all<{ added: string }>()).results;
      if (phone.some((r) => dayOf(zonedParts(new Date(r.added), n.zone)) === day)) continue;
      const key = `jotnudge:${day}`;
      const claim = await env.DB.prepare("INSERT OR IGNORE INTO due_alerts_sent(user_id,card_id,due,sent_at) VALUES(?,0,?,?)")
        .bind(n.user_id, key, iso(nowMs)).run();
      if (!claim.meta.changes) continue;
      const done = n.done_enc ? (JSON.parse(await decrypt(env, n.done_enc)) as string[]) : [];
      try {
        await sender(env, n.user_id)({ id: key, title: "Anything to jot today?", why: nudgePrompt(done), sender: "", due: null, link: "/app/?go=jot", reminder: true });
        sent++;
      } catch (e) {
        await env.DB.prepare("DELETE FROM due_alerts_sent WHERE user_id=? AND card_id=0 AND due=?").bind(n.user_id, key).run();
        await logEvent(env, { run_id: "due", user_id: n.user_id, decision: "jot nudge not sent; will try again",
          detail: String((e as Error)?.message ?? e).slice(0, 300), trace: key }).run();
      }
    } catch (e) {
      console.warn(JSON.stringify({ event: "jot_nudge_failed", error: String((e as Error)?.message ?? e).slice(0, 300) }));
    }
  }
  return sent;
}
