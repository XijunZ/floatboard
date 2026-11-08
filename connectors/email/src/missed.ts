import { type Env, nowISO } from "./env";
import { logEvent } from "./runlog";
import { Budget, BudgetExhausted } from "./budget";
import { tgSend } from "./telegram";
import { gmailSource, stripQuoted } from "./sources/gmail";
import type { SourceRow } from "./sources/types";

let gmailFetch: typeof fetch = (i, init) => fetch(i, init);
/** Tests replace Google's API. */
export function setGmailFetch(f: typeof fetch) { gmailFetch = f; }

const EXCERPT_CHARS = 1500, MAX_WORDS = 200, MAX_CANDIDATES = 5, MAX_INBOXES = 5, PENDING_MS = 30 * 60e3;
const NOT_LINKED = "This chat isn't linked to FloatBoard.";
const NEED_WORDS = "Send missed: and a few words first.";
export const MAX_ATTEMPTS = 5;
const RETRY_REPLY = "I couldn't search your email just now — I'll try again and message you.";
const RETRY_PARTIAL_REPLY = "I couldn't search all your inboxes just now — I'll try again and message you.";
const RETRY_AFTER_MS = 10 * 60e3;
const NO_MATCH = "I couldn't find that email from the last 14 days. Try the sender's name or a word from the subject.";

type Candidate = { sourceId: string; gmailId: string; messageId: string; subject: string; from: string; sentAt: string | null };

const addressOf = (from: string) => /<([^>]+)>/.exec(from)?.[1] ?? from.trim();

/** "missed: words", "missed words" or "/missed words" -> the words ("" if none); null if it isn't a missed request. */
export function parseMissed(text: string): string | null {
  const m = /^\s*\/?missed(?:@\w+)?(?:\s*:\s*|\s+|$)([\s\S]*)$/i.exec(text);
  return m ? m[1].replace(/\s+/g, " ").trim().slice(0, MAX_WORDS) : null;
}

/** retry: try again later; budget: ran out of calls (not the message's fault, no attempt counted); stored: the correction is saved. */
type Outcome = { retry: false } | { retry: true; error: string; budget?: boolean; stored?: boolean };
const DONE: Outcome = { retry: false };
const PRIVATE_ONLY = "Use FloatBoard in a direct chat with the bot.";

/** Calls one attempt can spend: per inbox a token, a list and up to 5 header reads; then one full read, one more token, one reply. */
export function callsNeeded(inboxes: number): number { return Math.min(inboxes, MAX_INBOXES) * (2 + MAX_CANDIDATES) + 3; }

/**
 * A text message from Telegram that might be a "missed" report. A message from a linked chat is stored in
 * telegram_inbox first (once per update_id), then processed; if that fails for a transient reason it stays
 * unprocessed and the hourly run retries it. Never throws.
 */
export async function handleChatMessage(env: Env, chatId: string, text: string, updateId: string,
    chat: { type?: string; fromId?: unknown } = {}): Promise<void> {
  let knownUser = "";
  try {
    if (parseMissed(text) === null && !/^\s*\d{1,2}\s*$/.test(text)) return; // not for us
    // Only a direct chat with the bot, written by the person whose chat it is: never answer about email anywhere else.
    if (chat.type !== "private" || chat.fromId == null || String(chat.fromId) !== chatId) {
      await trace(env, "", updateId, "missed: ignored (not a direct chat from the linked user)", `chat type ${chat.type ?? "?"}`);
      await sendReply(env, "", updateId, chatId, PRIVATE_ONLY);
      return;
    }
    const u = await env.DB.prepare("SELECT id FROM users WHERE telegram_chat_id=?").bind(chatId).first<{ id: string }>();
    if (!u) {
      await sendReply(env, "", updateId, chatId, NOT_LINKED);
      await trace(env, "", updateId, "missed: chat not linked");
      return;
    }
    knownUser = u.id;
    const uid = Number(updateId);
    let pendingCreated: string | null = null;
    if (Number.isInteger(uid) && updateId !== "") {
      const isNum = parseMissed(text) === null;
      const pend = isNum ? await env.DB.prepare("SELECT created FROM missed_pending WHERE user_id=?").bind(u.id).first<{ created: string }>() : null;
      pendingCreated = pend?.created ?? null;
      const ins = await env.DB.prepare("INSERT OR IGNORE INTO telegram_inbox(update_id,user_id,chat_id,text,received,pending_created) VALUES(?,?,?,?,?,?)")
        .bind(uid, u.id, chatId, text.slice(0, 1000), nowISO(), pendingCreated).run();
      if (!ins.meta.changes) { await trace(env, u.id, updateId, "missed: redelivered update ignored"); return; }
    }
    const calls = new Budget(); // the webhook is one Worker invocation: stay within the platform limit
    const out = await processText(env, u.id, chatId, text, updateId, calls.wrap(gmailFetch), calls, false, pendingCreated);
    if (Number.isInteger(uid) && updateId !== "") await settle(env, uid, out);
  } catch (e) {
    console.warn("missed handler failed:", (e as Error).message);
    await trace(env, knownUser, updateId, "missed: handler failed", (e as Error).message);
  }
}

async function settle(env: Env, uid: number, out: Outcome) {
  if (out.retry && out.budget) return; // out of calls: leave the row untouched, no attempt counted
  if (out.retry) {
    await env.DB.prepare("UPDATE telegram_inbox SET attempts=attempts+1, last_error=?, last_try=? WHERE update_id=?")
      .bind(out.error.slice(0, 300), nowISO(), uid).run();
  } else await env.DB.prepare("UPDATE telegram_inbox SET processed=1, last_error=NULL WHERE update_id=?").bind(uid).run();
}

/**
 * The hourly run: process stored messages that are still waiting (oldest first, 10 minutes after the last try).
 * After 5 attempts a message is given up on (processed=2; shown in needs attention). Spends from `calls`.
 */
export async function retryTelegramInbox(env: Env, userId: string, calls: Budget, fetchFn: typeof fetch = gmailFetch): Promise<number> {
  let done = 0;
  try {
    await env.DB.prepare("DELETE FROM telegram_inbox WHERE user_id=? AND processed=1 AND received < ?")
      .bind(userId, new Date(Date.now() - 30 * 86400e3).toISOString()).run();
    await env.DB.prepare("DELETE FROM telegram_inbox WHERE user_id=? AND processed=2 AND received < ?")
      .bind(userId, new Date(Date.now() - 7 * 86400e3).toISOString()).run();
    const n = (await env.DB.prepare("SELECT COUNT(*) n FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1").bind(userId).first<{ n: number }>())?.n ?? 0;
    const needed = callsNeeded(n);
    const { results } = await env.DB.prepare(`SELECT update_id, chat_id, text, attempts, pending_created FROM telegram_inbox
        WHERE user_id=? AND processed=0 AND (last_try IS NULL OR last_try < ?) ORDER BY received, update_id LIMIT 5`)
      .bind(userId, new Date(Date.now() - RETRY_AFTER_MS).toISOString()).all<{ update_id: number; chat_id: string; text: string; attempts: number; pending_created: string | null }>();
    for (const r of results) {
      if (calls.remaining < needed) break; // not enough calls for a full attempt: leave it for the next run
      const out = await processText(env, userId, r.chat_id, r.text, String(r.update_id), calls.wrap(fetchFn), calls, true, r.pending_created);
      await settle(env, r.update_id, out);
      if (!out.retry) { done++; continue; }
      if (out.retry && out.budget) break;
      if (r.attempts + 1 >= MAX_ATTEMPTS && out.retry && out.stored) { // saved, only the reply keeps failing
        await env.DB.prepare("UPDATE telegram_inbox SET processed=1 WHERE update_id=?").bind(r.update_id).run();
        await trace(env, userId, String(r.update_id), "missed: correction stored; reply could not be sent", out.error);
      } else if (r.attempts + 1 >= MAX_ATTEMPTS) {
        await env.DB.prepare("UPDATE telegram_inbox SET processed=2 WHERE update_id=?").bind(r.update_id).run();
        await trace(env, userId, String(r.update_id), "missed: gave up", `${out.error} (after ${MAX_ATTEMPTS} attempts)`);
      }
    }
  } catch (e) { console.warn("telegram inbox retry failed:", (e as Error).message); }
  return done;
}

export async function trace(env: Env, userId: string, updateId: string, decision: string, detail?: string, subject?: string) {
  try {
    await logEvent(env, { run_id: "telegram", user_id: userId, subject, decision, detail: detail?.slice(0, 500), trace: updateId }).run();
  } catch (e) { console.warn("missed trace failed:", (e as Error).message); }
}

/** Send a reply; a failure is recorded and returned as an error string (never thrown). */
async function sendReply(env: Env, userId: string, updateId: string, chatId: string, t: string, calls?: Budget): Promise<string | null> {
  try {
    calls?.take(1);
    await tgSend(env, chatId, t);
    return null;
  } catch (e) {
    if (e instanceof BudgetExhausted) throw e;
    const msg = (e as Error).message;
    await trace(env, userId, updateId, "telegram reply failed", msg);
    return `reply failed: ${msg}`;
  }
}

async function processText(env: Env, userId: string, chatId: string, text: string, updateId: string, gfetch: typeof fetch,
    calls: Budget | undefined, late: boolean, pendingCreated: string | null): Promise<Outcome> {
  const log = (decision: string, detail?: string, subject?: string) => trace(env, userId, updateId, decision, detail, subject);
  // Replies: a failed send keeps the message waiting (the correction itself, if any, is already stored).
  let sendError: string | null = null;
  let stored = false;
  const say = async (t: string) => { sendError = (await sendReply(env, userId, updateId, chatId, t, calls)) ?? sendError; };
  const result = (): Outcome => (sendError ? { retry: true, error: sendError, stored } : DONE);
  try {
    const words = parseMissed(text);
    const num = /^\s*(\d{1,2})\s*$/.exec(text)?.[1];

    if (words === null) { // a number: pick from the pending list
      const p = await env.DB.prepare("SELECT candidates_json, created FROM missed_pending WHERE user_id=?").bind(userId)
        .first<{ candidates_json: string; created: string }>();
      // Only the choice that existed when this number was received counts (a newer "missed:" replaced it otherwise).
      const live = p && p.created === pendingCreated && Date.now() - Date.parse(p.created) <= PENDING_MS;
      if (!live) {
        if (p && Date.now() - Date.parse(p.created) > PENDING_MS) await env.DB.prepare("DELETE FROM missed_pending WHERE user_id=?").bind(userId).run();
        await log("missed: number without a pending choice", late ? "processed late" : undefined); await say(NEED_WORDS); return result();
      }
      const cands: Candidate[] = JSON.parse(p.candidates_json);
      const n = Number(num);
      if (n < 1 || n > cands.length) { await log("missed: number out of range", `${n} of ${cands.length}`); await say(`Reply with a number from 1 to ${cands.length}.`); return result(); }
      const r = await record(cands[n - 1]);
      if (r) return r;
      await env.DB.prepare("DELETE FROM missed_pending WHERE user_id=?").bind(userId).run();
      return result();
    }

    if (!words) { await log("missed: no words"); await say(NEED_WORDS); return result(); }
    const { results: rows } = await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1 ORDER BY created LIMIT ?")
      .bind(userId, MAX_INBOXES).all<SourceRow>();
    const found = new Map<string, Candidate>();
    const errors: string[] = [];
    for (const row of rows) {
      try {
        for (const m of await gmailSource(env, row, gfetch).search(`${words} newer_than:14d -in:sent -in:chats -in:drafts`, MAX_CANDIDATES)) {
          const gmailId = /#all\/([A-Za-z0-9]+)$/.exec(m.link)?.[1];
          if (!gmailId || found.has(m.messageId)) continue;
          found.set(m.messageId, { sourceId: row.id, gmailId, messageId: m.messageId, subject: m.subject, from: m.from, sentAt: m.sentAt ?? null });
        }
      } catch (e) {
        if (e instanceof BudgetExhausted) throw e;
        errors.push(`${row.address}: ${(e as Error).message}`);
      }
    }
    if (errors.length) await log("missed: inbox search failed", errors.join(" | "));
    if (errors.length) { // partial results could record the wrong email or show an incomplete list: wait and search again
      if (!late) await say(errors.length === rows.length ? RETRY_REPLY : RETRY_PARTIAL_REPLY);
      return { retry: true, error: errors.join(" | ") };
    }
    const cands = [...found.values()].sort((a, b) => (b.sentAt ?? "").localeCompare(a.sentAt ?? "")).slice(0, MAX_CANDIDATES);
    if (cands.length === 0) {
      if (errors.length) { // can't tell "no match" from "couldn't look": keep the message and try again later
        if (!late) await say(RETRY_REPLY);
        return { retry: true, error: errors.join(" | ") };
      }
      await log("missed: no match", `"${words}"`); await say(NO_MATCH); return result();
    }
    if (cands.length === 1) return (await record(cands[0])) ?? result();
    await env.DB.prepare("INSERT OR REPLACE INTO missed_pending(user_id,candidates_json,created) VALUES(?,?,?)")
      .bind(userId, JSON.stringify(cands), nowISO()).run();
    await log("missed: several matches, waiting for a number", `${cands.length} for "${words}"`);
    await say(cands.map((c, i) => `${i + 1}. ${c.subject.slice(0, 80)} — ${addressOf(c.from)}`).join("\n") + "\nReply with the number.");
    return result();
  } catch (e) {
    if (e instanceof BudgetExhausted) return { retry: true, error: "out of calls", budget: true };
    await log("missed: failed", (e as Error).message);
    if (!late) await say(RETRY_REPLY);
    return { retry: true, error: (e as Error).message };
  }

  /** Store the correction and reply; returns an Outcome only when it has to be retried. */
  async function record(c: Candidate): Promise<Outcome | null> {
    const key = `missed:${userId}:${c.messageId}`;
    if (await env.DB.prepare("SELECT 1 FROM feedback WHERE event_uuid=?").bind(key).first()) {
      stored = true; await log("missed: already noted", c.messageId, c.subject); await say("Already noted — thanks."); return null;
    }
    const row = await env.DB.prepare("SELECT * FROM sources WHERE id=? AND user_id=?").bind(c.sourceId, userId).first<SourceRow>();
    if (!row) { await log("missed: inbox no longer connected", c.messageId, c.subject); await say("That inbox is no longer connected in FloatBoard."); return null; }
    let m;
    try { m = await gmailSource(env, row, gfetch).fetchFull(c.gmailId); }
    catch (e) {
      if (e instanceof BudgetExhausted) throw e;
      await log("missed: couldn't read the email", (e as Error).message, c.subject);
      if (!late) await say(RETRY_REPLY);
      return { retry: true, error: (e as Error).message };
    }
    const excerpt = stripQuoted(m.text).trim().slice(0, EXCERPT_CHARS);
    const now = nowISO();
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO feedback(user_id,item_id,verdict,created,subject,sender,detail,excerpt,event_uuid) VALUES(?,?,?,?,?,?,?,?,?)`)
        .bind(userId, "", "missed_action", now, m.subject, m.from, null, excerpt || null, key),
      env.DB.prepare(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,why,sender,subject,summary,sent_at,created)
          VALUES(?,?,?,?, 'correction', ?, 'missed_action', ?, ?, ?, ?, ?)`)
        .bind(crypto.randomUUID(), userId, row.id, m.messageId, m.subject, m.from, m.subject, excerpt, m.sentAt ?? now, now),
    ]);
    stored = true;
    await log("missed: correction stored", m.messageId, m.subject);
    await say(`Got it — I'll learn from "${m.subject.slice(0, 60)}" (from ${addressOf(m.from)}).`);
    return null;
  }
}
