import { retryTelegramInbox } from "./missed";
import Anthropic from "@anthropic-ai/sdk";
import { type Action, classify, type FeedbackExample } from "./classify";
import { Budget, BudgetExhausted } from "./budget";
import { decrypt } from "./crypto";
import { type Env, nowISO } from "./env";
import { logEvent } from "./runlog";
import { DEFAULT_RECAP_SENDERS, prefilter, senderAddress } from "./filter";
import { makeClient } from "./llm";
import { processEvents } from "./events";
import { pendingCorrections } from "./learn";
import { processRecap } from "./recap";
import { GmailSource } from "./sources/gmail";
import { OutlookSource } from "./sources/outlook";
import { pruneOutlookRows } from "./outlook";
import { DEFAULT_TIME_ZONE, zonedParts, zoneOrDefault } from "./time";
import { type Message, type Source, SourceAuthError, type SourceRow } from "./sources/types";

export const BATCH_SIZE = 10;

export type AlertItem = { id: string; title: string; why: string; sender: string; due: string | null; link: string };

export type RunOptions = {
  budget?: number;                             // max messages per pass
  calls?: Budget;                              // outgoing-call budget for this Worker invocation
  sourceFor?: (row: SourceRow) => Source;     // tests inject fake sources
  fetchFn?: typeof fetch;                      // tests inject a fake Claude API
  alert?: (item: AlertItem) => Promise<void>;  // Telegram
  lookbackDays?: number;                       // first-run lookback (default 7)
  /** Only these source kinds, and only the reading part of a run (no app events, no Telegram retries): used to judge
   *  Outlook rows right after they arrive. Default: every kind the run reads, and everything else a run does. */
  kinds?: string[];
};

/** Source kinds the triage run reads. */
export const TRIAGE_KINDS = ["gmail", "outlook_web"];

export type RunStats = { fetched: number; skippedSeen: number; dropped: number; classified: number; actions: number;
  recaps: number; noAction: number; alerts: number; errors: number };

type Event = { source?: string; sender?: string; subject?: string; decision: string; detail?: string; trace?: string };

const MAX_JUDGE_TRIES = 3;

/** One structured log line (visible in `wrangler tail` and Cloudflare Workers Logs). */
export function log(evt: string, fields: Record<string, unknown>) {
  console.log(JSON.stringify({ evt, ...fields }));
}

/** Wall-clock time in `zone` ("YYYY-MM-DD" or "YYYY-MM-DDTHH:mm") → instant. Date-only = 23:59. */
export function wallClockToDate(s: string, zone: string = DEFAULT_TIME_ZONE): Date {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/.exec(s);
  if (!m) return new Date(NaN);
  const [y, mo, d, h, mi] = [m[1], m[2], m[3], m[4] ?? "23", m[5] ?? "59"].map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const wall = (t: number) => {
    const p = zonedParts(new Date(t), zone);
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
  };
  const offset = wall(guess) - guess;
  return new Date(guess - offset);
}

/** Critical = explicitly urgent, or due within `hours` (or overdue by less than a day: older ones are stale, not alarms). */
export function isCritical(a: Action, now: Date, hours: number, zone: string = DEFAULT_TIME_ZONE): boolean {
  if (a.urgent) return true;
  if (!a.due) return false;
  const t = wallClockToDate(a.due, zone).getTime(), d = t - now.getTime();
  return !isNaN(t) && d <= hours * 3600e3 && d > -24 * 3600e3;
}

/**
 * One pass for one user: read new messages across their enabled Gmail and Outlook sources, filter, classify /
 * summarise, store results, alert on critical actions. Never spends more outgoing calls than `opts.calls`
 * allows: a page is only fetched if every message on it can be finished, so nothing is skipped or lost.
 * Every run records statistics and a per-message decision trace (runs / run_events).
 */
export async function runUser(env: Env, userId: string, opts: RunOptions = {}): Promise<{ processed: number; done: boolean }> {
  const runId = crypto.randomUUID();
  const t0 = Date.now();
  const calls = opts.calls ?? new Budget();
  const callsAtStart = calls.used;
  const stats: RunStats = { fetched: 0, skippedSeen: 0, dropped: 0, classified: 0, actions: 0, recaps: 0, noAction: 0, alerts: 0, errors: 0 };
  const events: Event[] = [];
  const ev = (e: Event) => { if (events.length < 300) events.push(e); };
  await env.DB.prepare("INSERT INTO runs(id,user_id,started) VALUES(?,?,?)").bind(runId, userId, nowISO()).run();
  log("run_start", { runId, userId, callsLeft: calls.remaining });

  const finish = async (processed: number, error: string | null, stopped: string) => {
    const now = nowISO();
    const week = new Date(Date.now() - 7 * 86400e3).toISOString(), month = new Date(Date.now() - 30 * 86400e3).toISOString();
    await env.DB.batch([
      env.DB.prepare("UPDATE runs SET finished=?, processed=?, error=?, stopped=?, stats=?, calls=?, ms=? WHERE id=?")
        .bind(now, processed, error, stopped, JSON.stringify(stats), calls.used - callsAtStart, Date.now() - t0, runId),
      ...events.map((e) => logEvent(env, { ...e, run_id: runId, user_id: userId, at: now })),
      env.DB.prepare("DELETE FROM judge_attempts WHERE user_id=? AND updated < ?").bind(userId, month),
      env.DB.prepare("DELETE FROM run_events WHERE user_id=? AND at < ?").bind(userId, week),
      env.DB.prepare("DELETE FROM runs WHERE user_id=? AND started < ?").bind(userId, month),
      // Rejected app events are reported for 7 days and kept for 30 (processed and waiting ones are never pruned here).
      env.DB.prepare("DELETE FROM app_events WHERE user_id=? AND processed=2 AND received < ?").bind(userId, month),
      pruneOutlookRows(env, userId),
    ]);
    log("run_end", { runId, userId, processed, stopped, error, stats, calls: calls.used - callsAtStart, ms: Date.now() - t0 });
  };

  // Telegram "missed:" reports that couldn't be processed when they arrived (needs no Claude key).
  const full = !opts.kinds;
  const retried = full ? await retryTelegramInbox(env, userId, calls) : 0;
  if (retried) log("telegram_inbox_retried", { runId, userId, retried });
  const user = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  if (!user?.anthropic_key_enc) {
    await finish(0, "Add your Claude API key in Connections to start reading email.", "no_key");
    return { processed: 0, done: true };
  }
  const client = makeClient(await decrypt(env, user.anthropic_key_enc), calls.wrap(opts.fetchFn));
  const s = await env.DB.prepare("SELECT * FROM settings WHERE user_id=?").bind(userId).first<any>();
  const unreadOnly = !!(s?.unread_only ?? 1);
  const rules = { ignore: JSON.parse(s?.ignore_senders ?? "[]"), allow: JSON.parse(s?.allow_senders ?? "[]"), recapSenders: DEFAULT_RECAP_SENDERS, unreadOnly };
  const criticalHours: number = s?.critical_hours ?? 24;
  const groups: string[] = JSON.parse(s?.groups ?? "[]");
  const groupNotes: Record<string, string> = JSON.parse(s?.group_notes ?? "{}");
  const myRules: string = s?.my_rules ?? "";
  const alertsOn = !!(s?.alerts_on ?? 1);
  const timeZone = zoneOrDefault(s?.time_zone);
  // Least recently read first, so one inbox's backlog can't starve another.
  const kinds = (opts.kinds ?? TRIAGE_KINDS).filter((k) => TRIAGE_KINDS.includes(k));
  const { results: rows } = await env.DB.prepare(`SELECT * FROM sources WHERE user_id=? AND kind IN (SELECT value FROM json_each(?)) AND enabled=1
      ORDER BY COALESCE(last_run, '') ASC, created ASC`)
    .bind(userId, JSON.stringify(kinds)).all<SourceRow>();
  const me = rows.map((r) => r.address.toLowerCase()).filter(Boolean);
  /** How a source is named in the run log and to Claude ("Received in:"); an Outlook mailbox is unknown until its first send. */
  const labelOf = (r: SourceRow) => r.address || (r.kind === "outlook_web" ? "Outlook" : "");
  // App events first (mark read, corrections); learning runs at the end of processEvents, at most once per run.
  if (full && (await processEvents(env, userId, calls, opts.fetchFn, runId)).learned) ev({ decision: "learned from your corrections" });
  const learned: string = (await env.DB.prepare("SELECT learned FROM settings WHERE user_id=?").bind(userId).first<{ learned: string }>())?.learned ?? "";
  const fb: FeedbackExample[] = await pendingCorrections(env, userId);

  // Critical alerts that couldn't be sent last time (e.g. out of calls) go first.
  if (alertsOn && opts.alert) {
    const { results: pending } = await env.DB.prepare(`SELECT id,title,why,sender,due,link FROM items
        WHERE user_id=? AND kind<>'draft' AND critical=1 AND alerted=0 AND created > ? ORDER BY created LIMIT 5`)
      .bind(userId, new Date(Date.now() - 2 * 86400e3).toISOString()).all<AlertItem>();
    for (const p of pending) {
      if (calls.remaining < 1) break;
      calls.take(1);
      if (await tryAlert(opts.alert, { ...p, why: p.why ?? "", sender: p.sender ?? "", link: p.link ?? "" }, ev)) {
        await env.DB.prepare("UPDATE items SET alerted=1 WHERE id=?").bind(p.id).run();
        stats.alerts++;
        ev({ subject: p.title, decision: "alert sent (retry)", trace: p.id });
      }
    }
  }

  let remaining = opts.budget ?? BATCH_SIZE, processed = 0, done = true, stopped = "done";

  /**
   * Claude's answer for this message couldn't be read. Counts the try; below MAX_JUDGE_TRIES the message is left
   * unseen and remembered with its Gmail id (retried by id at the start of the next run) and false is returned; at
   * MAX_JUDGE_TRIES it is recorded as given up (shown in /v2/status needs_attention) and true is returned so the caller marks it seen.
   */
  const judgeFailed = async (m: Message, base: Omit<Event, "decision">, reason: string, kind: "email" | "recap", sourceId: string | null): Promise<boolean> => {
    const n = await bumpAttempt(m.messageId, reason, m.subject, m.link, m.gmailId ?? null, sourceId, kind);
    stats.errors++;
    if (n >= MAX_JUDGE_TRIES) {
      ev({ ...base, decision: kind === "recap" ? "meeting notes saved without a summary \u2014 couldn't read the model's answer" : `couldn't judge (${MAX_JUDGE_TRIES} tries)`,
        detail: reason, trace: m.messageId });
      return true;
    }
    ev({ ...base, decision: `couldn't judge (try ${n} of ${MAX_JUDGE_TRIES}); will retry`, detail: reason, trace: m.messageId });
    return false;
  };
  const bumpAttempt = async (messageId: string, reason: string, subject: string, link: string, gmailId: string | null, sourceId: string | null, kind: string): Promise<number> => {
    const row = await env.DB.prepare(`INSERT INTO judge_attempts(user_id,message_id,attempts,last_error,subject,link,updated,gmail_id,source_id,kind) VALUES(?,?,1,?,?,?,?,?,?,?)
        ON CONFLICT(user_id,message_id) DO UPDATE SET attempts=attempts+1, last_error=excluded.last_error, updated=excluded.updated,
          gmail_id=COALESCE(excluded.gmail_id, gmail_id), source_id=COALESCE(excluded.source_id, source_id)
        RETURNING attempts`).bind(userId, messageId, reason.slice(0, 300), subject.slice(0, 200), link, nowISO(), gmailId, sourceId, kind).first<{ attempts: number }>();
    return row?.attempts ?? 1;
  };

  /** Returns true when the message is settled (marked seen), false when it must be read again next run. */
  const handle = async (m: Message, source: string, sourceId: string | null = null): Promise<boolean> => {
    const base = { source, sender: senderAddress(m.from), subject: m.subject, trace: m.messageId };
    if (await env.DB.prepare("SELECT 1 FROM seen WHERE user_id=? AND message_id=?").bind(userId, m.messageId).first()) {
      stats.skippedSeen++;
      return true;
    }
    if (m.thread?.superseded) {
      stats.dropped++;
      ev({ ...base, decision: "skipped: a newer message in the same thread is read instead" });
      await env.DB.prepare("INSERT OR IGNORE INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(userId, m.messageId, nowISO()).run();
      return true;
    }
    const route = prefilter(m, rules);
    if (route === "drop") {
      stats.dropped++;
      const why = unreadOnly && !m.labels.includes("UNREAD") ? "already read" : m.labels.some((l) => ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"].includes(l)) ? "bulk category"
        : m.headers["list-unsubscribe"] ? "newsletter (unsubscribe link)" : rules.ignore.length && rules.ignore.some((r: string) =>
          senderAddress(m.from).endsWith(r.toLowerCase()) || (m.fromName ?? "").trim().toLowerCase() === r.toLowerCase()) ? "on your ignore list" : "automated sender";
      ev({ ...base, decision: `dropped: ${why}` });
    }
    if (route === "recap") {
      let gaveUp = false;
      let out = await processRecap(env, userId, m, calls.wrap(opts.fetchFn));
      if (out.status === "unusable") {
        if (!(await judgeFailed(m, base, `Claude's answer for the meeting notes could not be used (${out.reason})`, "recap", sourceId))) return false;
        out = await processRecap(env, userId, m, undefined, { useClaude: false }); // gave up on Claude: keep the raw notes
        gaveUp = true;
      }
      if (out.status === "stored") stats.recaps++;
      if (!gaveUp) ev({ ...base, decision: out.status === "stored" ? "meeting notes summarised" : "meeting notes already handled" });
    }
    if (route === "classify") {
      stats.classified++;
      const res = await classify(m, me, fb, client, groups, { groupNotes, myRules, inbox: source, learned, timeZone });
      const a = res.ok ? res.action : null;
      if (!res.ok) {
        stats.classified--; // not judged
        if (!(await judgeFailed(m, base, `Claude's answer could not be used (${res.reason})`, "email", sourceId))) return false;
      }
      else if (!a) {
        stats.noAction++;
        // Already proposed as a task, now judged "not an action" (e.g. after a Re-check): withdraw the stale task.
        const known = await env.DB.prepare("SELECT title, source_id, sent_at FROM items WHERE user_id=? AND message_id=? AND kind='action'")
          .bind(userId, m.messageId).first<{ title: string; source_id: string | null; sent_at: string | null }>();
        if (known) {
          // Legacy item without a sent time: give it the key now, so its task and the withdraw carry the same one.
          if (!known.sent_at && m.sentAt) {
            await env.DB.prepare("UPDATE items SET sent_at=? WHERE user_id=? AND message_id=? AND kind='action'").bind(m.sentAt, userId, m.messageId).run();
            known.sent_at = m.sentAt;
          }
          const w = await env.DB.prepare(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,sent_at,created)
              VALUES(?,?,?,?, 'withdraw', ?,?,?)`).bind(crypto.randomUUID(), userId, known.source_id, m.messageId, known.title, known.sent_at, nowISO()).run();
          ev({ ...base, decision: w.meta.changes ? "task withdrawn: no longer an action (Claude)" : "no action needed (Claude); already withdrawn" });
        } else ev({ ...base, decision: "no action needed (Claude)" });
      }
      else if (a.due && a.hasTime && wallClockToDate(a.due, timeZone).getTime() < Date.now()) {
        stats.noAction++; ev({ ...base, decision: "skipped: event already happened", detail: `${a.title} (${a.due})` });
      }
      else {
        const critical = isCritical(a, new Date(), criticalHours, timeZone);
        const id = crypto.randomUUID();
        const ins = await env.DB.prepare(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,why,sender,subject,link,snippet,due,has_time,importance,group_name,critical,created,sent_at,history_id,summary)
            VALUES(?,?,?,?, 'action', ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
          .bind(id, userId, m.sourceId, m.messageId, a.title, a.why, senderAddress(m.from), m.subject, m.link, m.text.slice(0, 300),
            a.due, a.hasTime ? 1 : 0, a.importance, a.group, critical ? 1 : 0, nowISO(), m.sentAt ?? null, m.historyId ?? null,
            linksNote(a.links)).run();
        if (ins.meta.changes) {
          stats.actions++;
          ev({ ...base, trace: id, decision: "action created", detail: `${a.title}${critical ? " (critical)" : ""}` });
          if (critical && alertsOn && opts.alert && calls.remaining >= 1) {
            calls.take(1);
            if (await tryAlert(opts.alert, { id, title: a.title, why: a.why, sender: m.from, due: a.due, link: m.link }, ev)) {
              await env.DB.prepare("UPDATE items SET alerted=1 WHERE id=?").bind(id).run();
              stats.alerts++;
            }
          }
        }
      }
    }
    await env.DB.prepare("INSERT OR IGNORE INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(userId, m.messageId, nowISO()).run();
    await env.DB.prepare("DELETE FROM judge_attempts WHERE user_id=? AND message_id=? AND attempts<?").bind(userId, m.messageId, MAX_JUDGE_TRIES).run();
    return true;
  };

  // First, messages Claude couldn't judge earlier: read each again by id (1 call) and judge again (1 call), a few per run,
  // leaving room for new mail. A message that can't be read again counts as a failed try too.
  const sources = new Map<string, Source>();
  const sourceOf = (row: SourceRow) => {
    if (!sources.has(row.id)) sources.set(row.id, opts.sourceFor ? opts.sourceFor(row)
      : row.kind === "outlook_web" ? new OutlookSource(env, row)
      : new GmailSource(env, row, calls.wrap(), opts.lookbackDays ?? 7, [...DEFAULT_RECAP_SENDERS, ...rules.allow], unreadOnly));
    return sources.get(row.id)!;
  };
  try {
    if (rows.length) {
      const { results: waiting } = await env.DB.prepare(`SELECT message_id, gmail_id, source_id, subject, link, kind FROM judge_attempts
          WHERE user_id=? AND attempts<? AND gmail_id IS NOT NULL ORDER BY updated ASC LIMIT 5`).bind(userId, MAX_JUDGE_TRIES).all<any>();
      for (const w of waiting) {
        if (calls.remaining < 10) break; // keep room for new mail and a possible alert
        const row = rows.find((r) => r.id === w.source_id);
        if (!row) continue; // inbox disabled or removed: wait for it
        const src = sourceOf(row);
        if (!src.fetchFull) continue;
        let m: Message;
        try { m = await src.fetchFull(w.gmail_id); }
        catch (e) {
          if (isBudgetStop(e)) throw e;
          if (e instanceof SourceAuthError) break; // reconnect needed: the normal page read reports it
          const n = await bumpAttempt(w.message_id, `couldn't read the message again: ${(e as Error).message}`, w.subject ?? "", w.link ?? "", null, null, w.kind);
          ev({ source: labelOf(row), subject: w.subject ?? "", decision: n >= MAX_JUDGE_TRIES ? `couldn't judge (${MAX_JUDGE_TRIES} tries)` : `couldn't judge (try ${n} of ${MAX_JUDGE_TRIES}); will retry`,
            detail: `couldn't read the message again: ${(e as Error).message}`, trace: w.message_id });
          if (n >= MAX_JUDGE_TRIES) await env.DB.prepare("INSERT OR IGNORE INTO seen(user_id,message_id,at) VALUES(?,?,?)").bind(userId, w.message_id, nowISO()).run();
          continue;
        }
        stats.fetched++;
        await handle({ ...m, messageId: w.message_id }, labelOf(row), row.id);
      }
    }
    for (const [index, row] of rows.entries()) {
      // Each message may need 2 calls (fetch + Claude); a page also needs a token + list call, plus one spare
      // for a Telegram alert. The message cap is shared fairly between the inboxes still to read.
      const affordable = Math.floor((calls.remaining - 3) / 2);
      const fairShare = Math.ceil(remaining / (rows.length - index));
      const pageSize = Math.min(fairShare, affordable);
      if (pageSize < 1) { done = false; stopped = remaining < 1 ? "message_cap" : "call_budget"; break; }
      try {
        const source = sourceOf(row);
        const res = await source.fetchBatch(row.cursor, pageSize);
        stats.fetched += res.messages.length;
        log("page", { runId, source: labelOf(row), messages: res.messages.length, done: res.done, callsLeft: calls.remaining });
        for (const n of res.notes ?? []) { stats.errors++; ev({ source: labelOf(row), decision: n.decision, detail: n.detail, trace: n.messageId }); }
        // A message Claude couldn't judge stays unseen and is retried by id at the start of the next run (Gmail), or read
        // again on the next sweep (Outlook: its row stays unprocessed); the cursor moves on.
        for (const m of res.messages) {
          const settled = await handle(m, labelOf(row), row.id);
          if (settled && source.settled) await source.settled(m.messageId);
          processed++; remaining--;
        }
        // An Outlook source's last_run and last_error belong to the extension (when it last reported, what it reported).
        if (row.kind === "outlook_web") await env.DB.prepare("UPDATE sources SET cursor=? WHERE id=?").bind(res.cursor, row.id).run();
        else await env.DB.prepare("UPDATE sources SET cursor=?, last_run=?, last_error=NULL WHERE id=?").bind(res.cursor, nowISO(), row.id).run();
        if (!res.done) done = false;
      } catch (e) {
        if (isBudgetStop(e)) { done = false; stopped = "call_budget"; break; } // page not saved: redone next run
        if (e instanceof Anthropic.APIError) throw e; // a Claude problem affects every source: stop the run
        if (e instanceof BudgetExhausted) { done = false; stopped = "call_budget"; break; } // page not saved: redone next run
        stats.errors++;
        const msg = e instanceof SourceAuthError ? e.message : `Couldn't read ${labelOf(row)}: ${(e as Error).message}`;
        ev({ source: labelOf(row), decision: "source error", detail: msg });
        log("source_error", { runId, source: labelOf(row), error: msg, stack: (e as Error).stack?.slice(0, 500) });
        if (row.kind === "outlook_web") await env.DB.prepare("UPDATE sources SET last_error=? WHERE id=?").bind(msg, row.id).run();
        else await env.DB.prepare("UPDATE sources SET last_error=?, last_run=? WHERE id=?").bind(msg, nowISO(), row.id).run();
      }
    }
    if (!done && stopped === "done") stopped = remaining < 1 ? "message_cap" : "more_to_read";
  } catch (e) {
    if (isBudgetStop(e)) { await finish(processed, null, "call_budget"); return { processed, done: false }; }
    stats.errors++;
    const msg = e instanceof Anthropic.AuthenticationError ? "Claude API key was rejected. Update it in Connections."
      : `Claude API error: ${(e as Error).message}`;
    ev({ decision: "claude error", detail: msg });
    log("claude_error", { runId, error: msg, stack: (e as Error).stack?.slice(0, 500) });
    await finish(processed, msg, "claude_error");
    return { processed, done: false };
  }
  await finish(processed, null, stopped);
  return { processed, done };
}

/** True when an error is just this invocation's call budget running out (possibly wrapped by the Claude SDK). */
function isBudgetStop(e: unknown): boolean {
  return e instanceof BudgetExhausted || (e instanceof Anthropic.APIConnectionError && (e as { cause?: unknown }).cause instanceof BudgetExhausted);
}

/** Send an alert; a failure (e.g. bot blocked, rate limit) is recorded and retried next run, never blamed on Gmail. */
async function tryAlert(alert: (i: AlertItem) => Promise<void>, item: AlertItem, ev: (e: Event) => void): Promise<boolean> {
  try { await alert(item); return true; }
  catch (e) { ev({ subject: item.title, decision: "alert failed", detail: (e as Error).message }); log("alert_failed", { error: (e as Error).message }); return false; }
}

/**
 * Record a crashed run: finish the run's own open row (started at/after `since`) if it made one, else insert one.
 * Shared by the cron and POST /v2/run. Never throws. Returns the message stored.
 */
export async function recordCrash(env: Env, userId: string, since: string, err: unknown, callsUsed: number): Promise<string> {
  const msg = `Run crashed: ${(err as Error)?.message ?? String(err)}`.slice(0, 500);
  log("run_crashed", { userId, error: msg, stack: (err as Error)?.stack?.slice(0, 500) });
  try {
    const now = nowISO();
    const open = await env.DB.prepare("SELECT id FROM runs WHERE user_id=? AND finished IS NULL AND started >= ? ORDER BY started DESC LIMIT 1")
      .bind(userId, since).first<{ id: string }>();
    if (open) {
      await env.DB.prepare("UPDATE runs SET finished=?, error=?, stopped='crashed', calls=? WHERE id=?").bind(now, msg, callsUsed, open.id).run();
    } else {
      await env.DB.prepare("INSERT INTO runs(id,user_id,started,finished,processed,error,stopped,calls) VALUES(?,?,?,?,0,?,'crashed',?)")
        .bind(crypto.randomUUID(), userId, now, now, msg, callsUsed).run();
    }
  } catch (e2) { console.warn("could not record crashed run:", (e2 as Error).message); }
  return msg;
}

/** Passes for one user until caught up or this invocation's call budget runs low. */
export async function runRounds(env: Env, userId: string, opts: RunOptions = {}) {
  const calls = opts.calls ?? new Budget();
  let total = 0, done = false;
  for (let i = 0; i < 20 && !done && calls.remaining >= 4; i++) {
    const r = await runUser(env, userId, { ...opts, calls });
    total += r.processed;
    done = r.done || r.processed === 0;
  }
  return { processed: total, done };
}

/** The task's links as the text the app shows under the task (null when there are none). */
export function linksNote(links: string[] | undefined): string | null {
  return links?.length ? `Links from the email:\n${links.join("\n")}` : null;
}
