import { SKILL } from "../classify";
import { json, nowISO } from "../env";
import { HAIKU, SONNET } from "../llm";
import { route } from "../router";
import { readJSON } from "../http";
import { Budget, CALLS_PER_INVOCATION } from "../budget";
import { recordCrash, runRounds } from "../run";
import { alertFor } from "../alerts";
import { LEARNING_PAUSED } from "../learn";
import { processEvents } from "../events";
import { DEFAULT_TIME_ZONE, isTimeZone, zoneOrDefault } from "../time";
import { outlookSilent, SILENT_NOTICE } from "../outlook";

const isObj = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);

let skillVersion: Promise<string> | undefined;
/** First 12 hex characters of the SHA-256 of the skill file: which rules produced a proposal. */
export function getSkillVersion(): Promise<string> {
  skillVersion ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(SKILL))
    .then((h) => [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 12));
  return skillVersion;
}

// ---- proposals ----------------------------------------------------------------------------------

const KIND = { action: "task", summary: "summary", withdraw: "withdraw", draft: "draft" } as const;
/** How far behind the cursor items are read again (see /v2/proposals). */
const OVERLAP_MS = 2 * 60e3;

/** Items to propose to the app, ordered by (created, id), paged with an opaque cursor. */
route("GET", "/v2/proposals", async (req, env, user) => {
  const q = new URL(req.url).searchParams;
  const after = q.get("after");
  // Cursor "<created>|<id>|<seq>": the last item handed out, and the highest item rowid when that page was read.
  // D1 commits one write at a time, so a later commit always gets a higher rowid.
  let created = "", id = "", seq = 0;
  if (after) {
    const parts = after.split("|");
    if (parts.length !== 3 || !parts[0] || isNaN(Date.parse(parts[0])) || !/^\d+$/.test(parts[2])) return json({ error: "Invalid cursor" }, 400);
    [created, id] = parts;
    seq = Number(parts[2]);
  }
  const lq = q.get("limit");
  const limit = lq === null ? 100 : Number(lq);
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) return json({ error: "limit must be 1-500" }, 400);
  const top = (await env.DB.prepare("SELECT COALESCE(MAX(rowid), 0) n FROM items").first<{ n: number }>())?.n ?? 0; // before the page is read
  const { results: page } = await env.DB.prepare(`SELECT i.*, s.address AS source_address FROM items i LEFT JOIN sources s ON s.id=i.source_id
      WHERE i.user_id=? AND (i.created > ? OR (i.created = ? AND i.id > ?)) ORDER BY i.created, i.id LIMIT ?`)
    .bind(user.id, created, created, id, limit).all<any>();
  // `created` is set before the INSERT commits, so a slower writer can commit an item just behind a cursor already handed
  // out. Items up to OVERLAP_MS behind the cursor that were committed after it was handed out (rowid > seq) are sent
  // again; the app ignores duplicates. The cursor itself never moves back.
  let overlap: any[] = [];
  if (after) {
    const from = new Date(Date.parse(created) - OVERLAP_MS).toISOString();
    overlap = (await env.DB.prepare(`SELECT i.*, s.address AS source_address FROM items i LEFT JOIN sources s ON s.id=i.source_id
        WHERE i.user_id=? AND i.created >= ? AND (i.created < ? OR (i.created = ? AND i.id <= ?)) AND i.rowid > ?
        ORDER BY i.created, i.id LIMIT 100`)
      .bind(user.id, from, created, created, id, seq).all<any>()).results;
  }
  const skill_version = await getSkillVersion();
  const items = [...overlap, ...page].map((r) => ({
    id: r.id,
    kind: (KIND as Record<string, string>)[r.kind] ?? r.kind,
    // Rows from before migration 0007 have no sent_at; the app matches those by message id alone.
    // A `draft` is the result of a Draft reply request: link = the Gmail draft (null when it failed), why = the reason it
    // failed (null when ready), task_ref = the request id it answers.
    source_key: r.sent_at || (r.kind === "action" || r.kind === "withdraw" || r.kind === "draft") ? { message_id: r.message_id, sent_at: r.sent_at ?? null } : null,
    title: r.title, why: r.why ?? null, due: r.due ?? null, has_time: !!r.has_time, group: r.group_name ?? null,
    importance: r.importance, source_label: r.source_address ?? null, link: r.link ?? null, summary: r.summary ?? null,
    task_ref: r.task_ref ?? null, learned: r.kind === "learned" ? r.summary : null,
    provenance: { model: r.kind === "draft" ? SONNET : HAIKU, skill_version, created: r.created },
  }));
  const last = page[page.length - 1];
  // An empty page keeps the position but raises the seq, so overlap items already sent aren't re-sent on every sync.
  return json({ items, cursor: last ? `${last.created}|${last.id}|${top}` : after ? `${created}|${id}|${Math.max(top, seq)}` : null });
});

// ---- events from the app ------------------------------------------------------------------------

const EVENT_KINDS = ["done", "deleted", "changed", "correction", "settings", "draft_reply"];

/** [processed, last_error]: an event we can't understand is acked (so the app's outbox drains) but marked failed (2). */
function eventProblem(e: any): [number, string | null] {
  if (!EVENT_KINDS.includes(e.kind)) return [FAILED, "unknown kind"];
  if (!isObj(e.payload)) return [FAILED, "payload must be an object"];
  return [0, null];
}
const FAILED = 2;

/** Draft requests the background of one /v2/events request works on: background work only lives about 30 s after the
 *  answer, and one draft takes about 6 to 12 s. The rest are done by /v2/drafts/run (the app calls it every 15 s while
 *  it waits for a draft) or the hourly run. */
export const IMMEDIATE_DRAFTS = 2;

/** Idempotent intake: store each event once (by uuid), then ack. Processing happens later (hourly), except draft requests:
 *  up to IMMEDIATE_DRAFTS of those are processed right away in the background of this request, so a draft is usually
 *  ready in seconds. */
route("POST", "/v2/events", async (req, env, user, _params, ctx) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const events = b.body.events;
  if (!Array.isArray(events) || events.length > 500) return json({ error: "events must be an array of at most 500" }, 400);
  for (const [i, e] of events.entries()) {
    if (!isObj(e) || typeof e.uuid !== "string" || !e.uuid || e.uuid.length > 100) return json({ error: `events[${i}]: uuid required` }, 400);
    if (typeof e.kind !== "string" || !e.kind) return json({ error: `events[${i}]: kind required` }, 400);
  }
  const now = nowISO();
  if (events.length) {
    await env.DB.batch(events.map((e: any) => env.DB.prepare(
      "INSERT OR IGNORE INTO app_events(uuid,user_id,kind,payload,received,processed,last_error) VALUES(?,?,?,?,?,?,?)")
      .bind(e.uuid, user.id, e.kind, JSON.stringify(e.payload ?? {}), now, ...eventProblem(e))));
  }
  const drafts = events.filter((e: any) => e.kind === "draft_reply").length;
  if (drafts) { // about 7 calls per draft
    const n = Math.min(drafts, IMMEDIATE_DRAFTS);
    ctx.waitUntil(processEvents(env, user.id, new Budget(Math.min(CALLS_PER_INVOCATION, 10 * n)), undefined, "draft", "draft_reply", n)
      .catch((err) => console.warn("immediate draft processing failed:", (err as Error)?.message)));
  }
  return json({ acked: events.map((e: any) => e.uuid) });
});

/** Work on at most one waiting draft request now, before answering (the app calls this every 15 s while it waits for a
 *  draft, then pulls /v2/proposals). `waiting` = draft requests still not processed. */
route("POST", "/v2/drafts/run", async (_req, env, user) => {
  let processed = 0;
  try {
    processed = (await processEvents(env, user.id, new Budget(10), undefined, "draft", "draft_reply", 1)).processed;
  } catch (e) {
    console.warn("draft run failed:", (e as Error)?.message);
    return json({ error: "Drafts could not be worked on just now" }, 500);
  }
  const w = await env.DB.prepare("SELECT COUNT(*) n FROM app_events WHERE user_id=? AND kind='draft_reply' AND processed=0").bind(user.id).first<{ n: number }>();
  return json({ processed, waiting: w?.n ?? 0 });
});

// ---- settings -----------------------------------------------------------------------------------

type Field = { key: string; label: string; kind: "text" | "longtext" | "list" | "bool" | "int" | "choice" | "groupNotes"; help?: string; options?: string[] };
/** Matches the app's binding format; test/fixtures/v2-status.example.json is the shared example. */
export const SCHEMA: Field[] = [
  { "key": "group_notes", "label": "What each group means", "kind": "groupNotes", "help": "Claude uses these to put new tasks in the right group." },
  { "key": "my_rules", "label": "Your own rules", "kind": "longtext", "help": "Plain words, one per line. These override the shared email skill." },
  { "key": "learned", "label": "What FloatBoard has learned about you", "kind": "longtext", "help": "Built from your corrections. You can edit it." },
  { "key": "ignore_senders", "label": "Always ignore", "kind": "list", "help": "Addresses or @domains, one per line." },
  { "key": "allow_senders", "label": "Always include", "kind": "list", "help": "Addresses or @domains that are always read, even from tabs that are normally skipped." },
  { "key": "unread_only", "label": "Only unread emails become tasks", "kind": "bool" },
  { "key": "mark_read_on_done", "label": "Mark the email read when I finish its task", "kind": "bool" },
  { "key": "ai_footer", "label": "End reply drafts with \"Assisted by AI\"", "kind": "bool", "help": "Adds an italic Assisted by AI line at the end of every reply draft." },
  { "key": "alerts_on", "label": "Send critical tasks to Telegram", "kind": "bool" },
  { "key": "critical_hours", "label": "Critical means due within (hours)", "kind": "int" },
  { "key": "learn_at", "label": "Learn from my corrections every", "kind": "choice", "options": ["50", "100"], "help": "Number of corrections before your learned preferences are updated." },
];

/** Current values in the shape of the schema, plus the app-sent groups and time_zone (also what /v2/export returns). */
function valuesOf(s: any): Record<string, unknown> {
  return {
    group_notes: JSON.parse(s?.group_notes ?? "{}"), my_rules: s?.my_rules ?? "", learned: s?.learned ?? "",
    ignore_senders: JSON.parse(s?.ignore_senders ?? "[]"), allow_senders: JSON.parse(s?.allow_senders ?? "[]"),
    unread_only: !!(s?.unread_only ?? 1), mark_read_on_done: !!(s?.mark_read_on_done ?? 1), ai_footer: !!(s?.ai_footer ?? 0), alerts_on: !!(s?.alerts_on ?? 1),
    critical_hours: s?.critical_hours ?? 24, learn_at: s?.learn_at ?? null, groups: JSON.parse(s?.groups ?? "[]"),
    time_zone: s?.time_zone ?? DEFAULT_TIME_ZONE,
  };
}

/** A whole number given as a number or a numeric string ("50"); anything else is null. */
function wholeNumber(v: unknown): number | null {
  if (typeof v === "number") return Number.isInteger(v) ? v : null;
  if (typeof v === "string" && /^\s*\d+\s*$/.test(v)) return Number(v);
  return null;
}

/** Validate `values` into column assignments; returns an error message or the SQL pieces. */
function toColumns(values: Record<string, any>): { error: string } | { set: string[]; vals: unknown[] } {
  const set: string[] = [], vals: unknown[] = [];
  const list = (v: unknown) => Array.isArray(v) ? JSON.stringify(v.map(String).map((x) => x.trim().toLowerCase()).filter(Boolean)) : null;
  for (const [k, v] of Object.entries(values)) {
    switch (k) {
      case "ignore_senders": case "allow_senders": {
        const l = list(v); if (l === null) return { error: `${k} must be a list` };
        set.push(`${k}=?`); vals.push(l); break;
      }
      case "groups":
        if (!Array.isArray(v)) return { error: "groups must be a list" };
        set.push("groups=?"); vals.push(JSON.stringify(v.map(String).map((g) => g.trim()).filter(Boolean).slice(0, 30))); break;
      case "group_notes": {
        if (!isObj(v)) return { error: "group_notes must be an object" };
        const notes = Object.fromEntries(Object.entries(v).slice(0, 30)
          .map(([a, b]) => [String(a).trim(), String(b ?? "").trim().slice(0, 300)]).filter(([a, b]) => a && b));
        set.push("group_notes=?"); vals.push(JSON.stringify(notes)); break;
      }
      case "my_rules": case "learned":
        if (typeof v !== "string") return { error: `${k} must be text` };
        set.push(`${k}=?`); vals.push(v.trim().slice(0, k === "learned" ? 4000 : 2000)); break;
      case "unread_only": case "mark_read_on_done": case "ai_footer": case "alerts_on":
        if (typeof v !== "boolean") return { error: `${k} must be true or false` };
        set.push(`${k}=?`); vals.push(v ? 1 : 0); break;
      case "critical_hours": {
        const n = wholeNumber(v);
        if (n === null || n < 1 || n > 720) return { error: "critical_hours must be a whole number of hours (1-720)" };
        set.push("critical_hours=?"); vals.push(n); break;
      }
      case "learn_at": {
        const n = wholeNumber(v);
        if (n !== 50 && n !== 100) return { error: "learn_at must be 50 or 100" };
        set.push("learn_at=?"); vals.push(n); break;
      }
      case "time_zone": // sent by the app from the device, not part of SCHEMA
        if (!isTimeZone(v)) return { error: "time_zone must be an IANA time zone name such as Europe/Berlin" };
        set.push("time_zone=?"); vals.push(v.trim()); break;
      default: return { error: `Unknown setting: ${k}` };
    }
  }
  return { set, vals };
}

/** Versioned settings: the app's version wins unless it is older than what is stored (409 with the stored version). */
route("PUT", "/v2/settings", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const { version, values } = b.body;
  if (!Number.isInteger(version) || version < 0) return json({ error: "version must be a whole number" }, 400);
  if (!isObj(values)) return json({ error: "values must be an object" }, 400);
  const cols = toColumns(values);
  if ("error" in cols) return json({ error: cols.error }, 400);
  const cur = await env.DB.prepare("SELECT settings_version FROM settings WHERE user_id=?").bind(user.id).first<{ settings_version: number }>();
  if (!cur) return json({ error: "not found" }, 404);
  if (version < cur.settings_version) return json({ error: "stale settings version", settings_version: cur.settings_version }, 409);
  const set = [...cols.set, "settings_version=?"];
  const r = await env.DB.prepare(`UPDATE settings SET ${set.join(",")} WHERE user_id=? AND settings_version<=?`)
    .bind(...cols.vals, version, user.id, version).run();
  if (!r.meta.changes) { // lost a race with a newer write
    const now = await env.DB.prepare("SELECT settings_version FROM settings WHERE user_id=?").bind(user.id).first<{ settings_version: number }>();
    return json({ error: "stale settings version", settings_version: now?.settings_version ?? 0 }, 409);
  }
  return json({ ok: true, settings_version: version });
});

/** How a source is named in needs attention: its address; Outlook says so (its address is empty until the first send). */
const sourceLabel = (r: { kind: string; address: string }) => r.kind === "outlook_web" ? (r.address ? `Outlook ${r.address}` : "Outlook") : r.address;

// ---- status, recheck, export --------------------------------------------------------------------

route("GET", "/v2/status", async (_req, env, user) => {
  const s = await env.DB.prepare("SELECT settings_version FROM settings WHERE user_id=?").bind(user.id).first<{ settings_version: number }>();
  const run = await env.DB.prepare("SELECT error FROM runs WHERE user_id=? AND finished IS NOT NULL ORDER BY started DESC LIMIT 1")
    .bind(user.id).first<{ error: string | null }>();
  // last_run_ok: when the newest run that finished without an error ended (ISO text), or null if none has.
  const good = await env.DB.prepare("SELECT finished FROM runs WHERE user_id=? AND finished IS NOT NULL AND error IS NULL ORDER BY finished DESC LIMIT 1")
    .bind(user.id).first<{ finished: string }>();
  const week = new Date(Date.now() - 7 * 86400e3).toISOString();
  const oldest = await env.DB.prepare("SELECT MIN(received) t FROM app_events WHERE user_id=? AND processed=0").bind(user.id).first<{ t: string | null }>();
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(user.id).first<{ anthropic_key_enc: string | null }>();
  const { results: bad } = await env.DB.prepare("SELECT kind, address, last_error FROM sources WHERE user_id=? AND enabled=1 AND last_error IS NOT NULL").bind(user.id).all<any>();
  const needs_attention: string[] = bad.map((r) => `${sourceLabel(r)}: ${r.last_error}`);
  if (!u?.anthropic_key_enc) needs_attention.unshift("Add your Claude API key to start reading email.");
  // The Outlook extension only reports from an open, signed-in Outlook tab: a long silence is worth a line.
  const { results: outlook } = await env.DB.prepare("SELECT last_run, created FROM sources WHERE user_id=? AND kind='outlook_web' AND enabled=1")
    .bind(user.id).all<{ last_run: string | null; created: string }>();
  if (outlook.length) {
    const zone = zoneOrDefault((await env.DB.prepare("SELECT time_zone FROM settings WHERE user_id=?").bind(user.id).first<{ time_zone: string | null }>())?.time_zone);
    if (outlook.some((o) => outlookSilent(o.last_run ?? o.created, new Date(), zone))) needs_attention.push(SILENT_NOTICE);
  }
  // Rejected events and a removed inbox's finished emails are reported for 7 days (then the line clears by itself).
  const REMOVED = "(last_error LIKE 'inbox removed%' OR last_error LIKE 'inbox not connected%')";
  const rejected = await env.DB.prepare(`SELECT COUNT(*) n FROM app_events WHERE user_id=? AND processed=? AND received > ? AND (last_error IS NULL OR NOT ${REMOVED})`)
    .bind(user.id, FAILED, week).first<{ n: number }>();
  if (rejected?.n) needs_attention.push(`${rejected.n} event(s) from the app could not be understood (unknown kind or malformed) and were skipped.`);
  const { results: gone } = await env.DB.prepare(`SELECT last_error, COUNT(*) n FROM app_events WHERE user_id=? AND processed=0 AND kind='done' AND last_error LIKE 'inbox not connected%' GROUP BY last_error`)
    .bind(user.id).all<any>();
  for (const g of gone) {
    const addr = /\((.*?)\)/.exec(g.last_error)?.[1] || "An inbox";
    needs_attention.push(`${addr} isn't connected \u2014 ${g.n} finished email${g.n === 1 ? " wasn't" : "s weren't"} marked read. Reconnect it in the setup page.`);
  }
  const removed = await env.DB.prepare(`SELECT COUNT(*) n FROM app_events WHERE user_id=? AND processed=? AND kind='done' AND received > ? AND ${REMOVED}`)
    .bind(user.id, FAILED, week).first<{ n: number }>();
  if (removed?.n) needs_attention.push(`An inbox was removed \u2014 ${removed.n} finished email${removed.n === 1 ? " wasn't" : "s weren't"} marked read`);
  const { results: stuck } = await env.DB.prepare("SELECT COUNT(*) n FROM app_events WHERE user_id=? AND kind='done' AND processed=0 AND attempts>=5").bind(user.id).all<any>();
  if (stuck[0]?.n) needs_attention.push(`${stuck[0].n} finished task(s) could not be marked read in Gmail after 5 tries; will keep retrying.`);
  const { results: giveUps } = await env.DB.prepare("SELECT text FROM telegram_inbox WHERE user_id=? AND processed=2 ORDER BY received DESC LIMIT 5").bind(user.id).all<{ text: string }>();
  // Quoted, so shared diagnostics (which redact quoted text) never carry what the user typed.
  for (const g of giveUps) needs_attention.push(`A missed-email report couldn't be processed: "${g.text.replace(/"/g, "").slice(0, 40)}"`);
  const paused = await env.DB.prepare("SELECT learn_paused_at FROM settings WHERE user_id=?").bind(user.id).first<{ learn_paused_at: string | null }>();
  if (paused?.learn_paused_at) needs_attention.push(LEARNING_PAUSED);
  const { results: gaveUp } = await env.DB.prepare(`SELECT subject, link, kind FROM judge_attempts WHERE user_id=? AND attempts>=3 AND updated > ?
      ORDER BY updated DESC LIMIT 5`).bind(user.id, week).all<{ subject: string | null; link: string | null; kind: string }>();
  for (const g of gaveUp) {
    const subj = (g.subject || "(no subject)").slice(0, 60), link = g.link ? ` ${g.link}` : "";
    needs_attention.push(g.kind === "recap"
      ? `Meeting notes "${subj}" were saved without a summary: couldn't read Claude's answer after 3 tries.${link}`
      : `Couldn't read Claude's answer for "${subj}" after 3 tries; it was skipped.${link}`);
  }
  const count = async (sql: string) => (await env.DB.prepare(sql).bind(user.id).first<{ n: number }>())?.n ?? 0;
  return json({
    settings_version: s?.settings_version ?? 0, schema: SCHEMA, needs_attention,
    waiting: await count("SELECT COUNT(*) n FROM app_events WHERE user_id=? AND processed=0"),
    last_run_ok: good?.finished ?? null, last_run_error: run?.error ?? null, oldest_unprocessed_event: oldest?.t ?? null,
  });
});

/** Re-read the last N days: forget what was read (items stay), and restart each inbox's cursor N days back. */
route("POST", "/v2/recheck", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const days = Number(new URL(req.url).searchParams.get("days"));
  if (!Number.isInteger(days) || days < 1 || days > 30) return json({ error: "days must be 1-30" }, 400);
  const since = Date.now() - days * 86400e3;
  await env.DB.batch([
    env.DB.prepare("DELETE FROM seen WHERE user_id=? AND at > ?").bind(user.id, new Date(since).toISOString()),
    env.DB.prepare("DELETE FROM judge_attempts WHERE user_id=?").bind(user.id),
    env.DB.prepare("UPDATE sources SET cursor=?, last_error=NULL WHERE user_id=? AND kind='gmail'")
      .bind(JSON.stringify({ after: Math.floor(since / 1000) }), user.id),
    // Outlook rows are kept 30 days after they were judged: the ones received in the window are judged again.
    env.DB.prepare("UPDATE outlook_rows SET processed=0, processed_at=NULL WHERE user_id=? AND received > ?").bind(user.id, new Date(since).toISOString()),
    env.DB.prepare("UPDATE sources SET cursor=NULL WHERE user_id=? AND kind='outlook_web'").bind(user.id),
  ]);
  return json({ ok: true, days });
});

/** Check now: passes for this user until caught up or the call budget runs low (what the hourly cron does, immediately). */
route("POST", "/v2/run", async (_req, env, user) => {
  const started = nowISO();
  const calls = new Budget();
  try {
    const r = await runRounds(env, user.id, { calls, alert: alertFor(env, user.id) });
    return json({ processed: r.processed, done: r.done });
  } catch (e) {
    const msg = await recordCrash(env, user.id, started, e, calls.used);
    return json({ error: msg }, 500);
  }
});

/** Everything worth keeping if the engine is rebuilt: settings and the corrections the engine has learned from. */
route("GET", "/v2/export", async (_req, env, user) => {
  const s = await env.DB.prepare("SELECT * FROM settings WHERE user_id=?").bind(user.id).first<any>();
  const { results } = await env.DB.prepare(`SELECT item_id, verdict, detail, subject, sender, created, consolidated FROM feedback
      WHERE user_id=? ORDER BY created, rowid`).bind(user.id).all<any>();
  return json({ settings: { version: s?.settings_version ?? 0, ...valuesOf(s) },
    feedback: results.map((r) => ({ ...r, consolidated: !!r.consolidated })) });
});
