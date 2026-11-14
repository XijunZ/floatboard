/**
 * Due reminders for every task, whatever made it: every 15 minutes the engine reads each user's board copy (the Mac's
 * encrypted copy plus phone moves the Mac has not applied yet) and reminds them, through the same channels as urgent
 * emails, of open tasks (To do, Doing, Watch) that are due:
 * - timed: from 15 minutes before the due time until 15 minutes after it ("Due 14:30", in the user's time zone);
 * - date only: on that day from 09:00 in the user's time zone ("Due today").
 * Each (user, task, due value) is reminded once (`due_alerts_sent`); a reminder no channel could deliver is tried
 * again on the next run. Nothing is sent while the user's alerts are off.
 */
import { alertFor } from "./alerts";
import { type Env, nowISO } from "./env";
import { logEvent } from "./runlog";
import type { AlertItem } from "./run";
import { zonedParts, zoneOrDefault } from "./time";
import { type Card, currentBoard } from "./app/board";
import { chaseFor } from "./watch";

export const DUE_WINDOW_MS = 15 * 60_000;
export const DAY_REMINDER_HOUR = 9;
const KEEP_DAYS = 30;
const OPEN = new Set(["todo", "doing", "watch"]);

const dayOf = (parts: Record<string, string>) => `${parts.year}-${parts.month}-${parts.day}`;

/** The reminder text for a task at `nowMs` ("Due 14:30" or "Due today"), or null when it is not due for a reminder now. */
export function dueAlertText(c: { status: string; due: string | null; has_time: boolean }, nowMs: number, zone: string): string | null {
  if (!OPEN.has(c.status) || !c.due) return null;
  if (c.has_time) {
    const t = Date.parse(c.due);
    if (Number.isNaN(t) || nowMs < t - DUE_WINDOW_MS || nowMs >= t + DUE_WINDOW_MS) return null;
    const p = zonedParts(new Date(t), zone);
    return `Due ${p.hour}:${p.minute}`;
  }
  // The Mac sends a date-only due as the local day ("YYYY-MM-DD"); anything else is read as an instant in the user's zone.
  const day = /^\d{4}-\d{2}-\d{2}$/.test(c.due) ? c.due : Number.isNaN(Date.parse(c.due)) ? null : dayOf(zonedParts(new Date(c.due), zone));
  const now = zonedParts(new Date(nowMs), zone);
  return day === dayOf(now) && Number(now.hour) >= DAY_REMINDER_HOUR ? "Due today" : null;
}

/** The email link on a task, when it has one (the alert opens it); else nothing (the phone app opens). */
const emailLink = (c: Card) => c.links?.find((l) => l.kind === "email")?.url ?? "";

/** One pass over every user with a board copy. Never throws: a problem with one user or task never stops the others. */
export async function runDueAlerts(env: Env, nowMs = Date.now(),
    sender: (env: Env, userId: string) => (item: AlertItem) => Promise<void> = alertFor): Promise<number> {
  let sent = 0;
  const users = (await env.DB.prepare(`SELECT b.user_id, s.alerts_on, s.time_zone FROM board_snapshots b
      LEFT JOIN settings s ON s.user_id=b.user_id`).all<{ user_id: string; alerts_on: number | null; time_zone: string | null }>()).results;
  for (const u of users) {
    if (u.alerts_on === 0) continue;
    try {
      const zone = zoneOrDefault(u.time_zone);
      const send = sender(env, u.user_id);
      for (const c of await currentBoard(env, u.user_id)) {
        // Watch tasks with no reply: one chase every 3 days (claimed like a due reminder, keyed by when Watch began).
        const chase = c.id > 0 ? chaseFor(c, nowMs) : null;
        if (chase) {
          const claim = await env.DB.prepare("INSERT OR IGNORE INTO due_alerts_sent(user_id,card_id,due,sent_at) VALUES(?,?,?,?)")
            .bind(u.user_id, c.id, chase.key, new Date(nowMs).toISOString()).run();
          if (claim.meta.changes) {
            try {
              await send({ id: `chase:${c.id}`, title: c.title, why: chase.text, sender: "", due: null, link: emailLink(c), reminder: true });
              sent++;
            } catch (e) {
              await env.DB.prepare("DELETE FROM due_alerts_sent WHERE user_id=? AND card_id=? AND due=?").bind(u.user_id, c.id, chase.key).run();
              await logEvent(env, { run_id: "due", user_id: u.user_id, decision: "chase reminder not sent; will try again",
                detail: String((e as Error)?.message ?? e).slice(0, 300), trace: `card ${c.id}` }).run();
            }
          }
        }
        const text = dueAlertText(c, nowMs, zone);
        if (!text || c.id < 0) continue;
        // Claim first, so two runs at once never remind twice; given back when no channel got it through.
        const claim = await env.DB.prepare("INSERT OR IGNORE INTO due_alerts_sent(user_id,card_id,due,sent_at) VALUES(?,?,?,?)")
          .bind(u.user_id, c.id, c.due, new Date(nowMs).toISOString()).run();
        if (!claim.meta.changes) continue;
        try {
          await send({ id: `due:${c.id}`, title: c.title, why: text, sender: "", due: null, link: emailLink(c), reminder: true });
          sent++;
        } catch (e) {
          await env.DB.prepare("DELETE FROM due_alerts_sent WHERE user_id=? AND card_id=? AND due=?").bind(u.user_id, c.id, c.due).run();
          await logEvent(env, { run_id: "due", user_id: u.user_id, decision: "due reminder not sent; will try again",
            detail: String((e as Error)?.message ?? e).slice(0, 300), trace: `card ${c.id}` }).run();
        }
      }
    } catch (e) {
      console.warn(JSON.stringify({ event: "due_alerts_failed", error: String((e as Error)?.message ?? e).slice(0, 300) }));
    }
  }
  return sent;
}

/** Hourly: records of reminders sent more than 30 days ago are deleted. */
export async function purgeDueAlerts(env: Env): Promise<void> {
  const cutoff = new Date(Date.parse(nowISO()) - KEEP_DAYS * 86400_000).toISOString();
  await env.DB.prepare("DELETE FROM due_alerts_sent WHERE sent_at < ?").bind(cutoff).run();
}
