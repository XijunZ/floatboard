/**
 * Watch: tasks waiting on someone. Everything here is a fixed rule (no Claude):
 * - Reply detection (email): for each Watch task whose contact is "email:<address>", the engine searches the user's
 *   Gmail inboxes for a message from that address after the task went to Watch. A hit writes one `watch_reply` phone
 *   action (made at the reply's time), which the Mac applies by moving the task back to To do. WhatsApp replies are
 *   detected on the Mac (it has the chats).
 * - Chase reminders: every CHASE_DAYS on Watch with no reply, one reminder "Still waiting on <person> · N days".
 */
import type { Env } from "./env";
import { nowISO } from "./env";
import { Budget, BudgetExhausted } from "./budget";
import { logEvent } from "./runlog";
import { gmailSource } from "./sources/gmail";
import type { SourceRow } from "./sources/types";
import { type Card, currentBoard } from "./app/board";

export const CHASE_DAYS = 3;
const DAY_MS = 86_400_000;
/** Calls one inbox search can take (a token, the list, one header read). */
const SEARCH_CALLS = 3;

let gmailFetch: typeof fetch | undefined;
/** Tests replace Google's API. */
export function setWatchGmailFetch(f: typeof fetch | undefined) { gmailFetch = f; }

/** The chase reminder due now for a Watch task, or null: the n-th comes after n × CHASE_DAYS days. */
export function chaseFor(c: Pick<Card, "status" | "watch">, nowMs: number): { key: string; text: string } | null {
  if (c.status !== "watch" || !c.watch) return null;
  const since = Date.parse(c.watch.since);
  if (Number.isNaN(since)) return null;
  const n = Math.floor((nowMs - since) / (CHASE_DAYS * DAY_MS));
  if (n < 1) return null;
  const days = n * CHASE_DAYS;
  return { key: `chase:${c.watch.since}:${n}`, text: `Still waiting on ${c.watch.person.trim() || "a reply"} · ${days} days` };
}

/** Gmail's search for a message from `address` after `since` (Gmail reads `after:` as seconds since 1970). */
export function replyQuery(address: string, since: string): string {
  return `from:${address} after:${Math.floor(Date.parse(since) / 1000)} -in:sent -in:drafts`;
}

/**
 * Looks for replies to this user's Watch tasks that wait on an email address. Never throws; returns how many tasks
 * got a reply. Each task is searched once per inbox per call; a task already answered (an untaken watch_reply) is skipped.
 */
export async function checkWatchReplies(env: Env, userId: string, calls: Budget): Promise<number> {
  let found = 0;
  try {
    const watched = (await currentBoard(env, userId)).filter((c) => c.id > 0 && c.status === "watch" && c.watch?.contact.startsWith("email:"));
    if (!watched.length) return 0;
    const { results: inboxes } = await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1 ORDER BY created")
      .bind(userId).all<SourceRow>();
    for (const c of watched) {
      const w = c.watch!;
      const clientId = `watch:${c.id}:${w.since}`;
      if (await env.DB.prepare("SELECT 1 FROM phone_actions WHERE user_id=? AND client_id=?").bind(userId, clientId).first()) continue;
      const address = w.contact.slice("email:".length);
      for (const row of inboxes) {
        if (calls.remaining < SEARCH_CALLS) return found;
        const hit = (await gmailSource(env, row, calls.wrap(gmailFetch)).search(replyQuery(address, w.since), 1))[0];
        if (!hit) continue;
        const at = hit.sentAt && Date.parse(hit.sentAt) > Date.parse(w.since) ? hit.sentAt : nowISO();
        const who = w.person.trim() || address;
        await env.DB.prepare(`INSERT OR IGNORE INTO phone_actions(id,user_id,card_id,action,created,client_id,made_at,payload)
            VALUES(?,?,?, 'watch_reply', ?,?,?,?)`)
          .bind(crypto.randomUUID(), userId, c.id, nowISO(), clientId, at, JSON.stringify({ reason: `${who} replied by email`, via: "email" })).run();
        await logEvent(env, { run_id: "watch", user_id: userId, decision: "watched person replied", detail: `${who} (email)`, trace: `card ${c.id}` }).run();
        found++;
        break;
      }
    }
  } catch (e) {
    if (!(e instanceof BudgetExhausted)) {
      try {
        await logEvent(env, { run_id: "watch", user_id: userId, decision: "reply check failed; will try again",
          detail: String((e as Error)?.message ?? e).slice(0, 300) }).run();
      } catch { /* the next run tries again */ }
    }
  }
  return found;
}
