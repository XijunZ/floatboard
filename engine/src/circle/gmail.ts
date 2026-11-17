/**
 * Circle's Gmail reader (features §9 "Circle has its own readers"): who, when and which way, from the inbox and the
 * **Sent** folder, read with `format=metadata` (From, To, Cc, Date, List-Unsubscribe) so no body or subject is ever
 * fetched or stored. Separate from the task screening (src/triage), with its own cursor.
 *
 * - Incoming: the sender of a personal message (Gmail's bulk categories, mailing lists and no-reply senders are skipped).
 * - Outgoing: each recipient of a message you sent to at most 5 people (mass mail is skipped).
 * - Backfill: the last 12 months, newest first, a page per run within the call budget; then new mail since the last pass.
 *   `circle_readers` keeps "data as of" and how far back it is complete.
 * - Rows are encrypted (address and display name) and taken in by the Mac by seq (`GET /v2/circle/exchanges`).
 */
import type { Env } from "../env";
import { nowISO } from "../env";
import type { Budget } from "../lib/budget";
import { GmailSource, splitAddresses } from "../sources/gmail";
import type { SourceRow } from "../sources/types";
import { circleFetch } from "./net";
import { circleOn, seal } from "./common";

const DAY = 86400_000;
const HEADERS = ["From", "To", "Cc", "Date", "List-Unsubscribe", "Precedence"];
const BASE_QUERY = "-in:chats -in:drafts -in:spam -in:trash -category:promotions -category:social -category:forums -category:updates";
const MAX_RECIPIENTS = 5;
const PAGE = 20;
const NO_REPLY = /^(no-?reply|do-?not-?reply|notifications?|mailer-daemon|postmaster|bounce)[^@]*@/i;

type Cursor = { floor?: number; live_after?: number; live_token?: string; live_start?: number; back_before?: number; back_token?: string; back_done?: boolean };
export type Who = { h: string; n: string };

/** "Name <a@b>, c@d" → [{h: "a@b", n: "Name"}, {h: "c@d", n: ""}] (addresses in lower case). */
export function splitWho(v: string | undefined): Who[] {
  return splitAddresses(v).map((one) => {
    const m = /^(.*)<([^>]+)>\s*$/.exec(one);
    const addr = (m ? m[2] : one).trim().toLowerCase();
    const name = m ? m[1].trim().replace(/^"(.*)"$/, "$1").trim() : "";
    return { h: addr, n: name };
  }).filter((w) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(w.h));
}

/** Who a message was with and which way, or null when Circle leaves it out (bulk, lists, no-reply, mass mail). */
export function exchangesOf(headers: Record<string, string>, labels: string[], own: string): { direction: "in" | "out"; who: Who[] } | null {
  if (labels.includes("SENT")) {
    const to = [...splitWho(headers["to"]), ...splitWho(headers["cc"])].filter((w) => w.h !== own);
    if (!to.length || to.length > MAX_RECIPIENTS) return null;
    return { direction: "out", who: to };
  }
  if (headers["list-unsubscribe"] || /bulk|list|junk/i.test(headers["precedence"] ?? "")) return null;
  const from = splitWho(headers["from"])[0];
  if (!from || from.h === own || NO_REPLY.test(from.h)) return null;
  return { direction: "in", who: [from] };
}

/** One pass for one Gmail inbox. Never throws for Gmail's answers: a problem is kept as the reader's note. */
export async function readGmailMeta(env: Env, userId: string, row: SourceRow, budget: Budget,
                                    opts: { now?: number; backfillMonths?: number; fetchFn?: typeof fetch } = {}): Promise<{ stored: number; done: boolean }> {
  if (!(await circleOn(env, userId))) return { stored: 0, done: true };
  const now = opts.now ?? Date.now();
  const reader = `gmail:${row.address}`;
  const st = await env.DB.prepare("SELECT cursor, complete_from FROM circle_readers WHERE user_id=? AND reader=?").bind(userId, reader)
    .first<{ cursor: string; complete_from: string | null }>();
  let c: Cursor = {};
  try { c = JSON.parse(st?.cursor ?? "{}"); } catch { c = {}; }
  const first = c.live_after === undefined;
  const nowS = Math.floor(now / 1000);
  c.floor ??= Math.floor((now - (opts.backfillMonths ?? 12) * 30.44 * DAY) / 1000);
  if (first) { c.back_before = nowS; c.live_after = nowS - 60; }
  let completeFrom = st?.complete_from ?? null;
  const own = row.address.toLowerCase();
  const src = new GmailSource(env, row, budget.wrap(opts.fetchFn ?? circleFetch()));
  let stored = 0, note = "";
  const room = () => budget.remaining - (src.hasToken ? 1 : 2);

  async function page(q: string, token: string | undefined): Promise<{ next?: string; oldest?: number } | null> {
    const max = Math.min(PAGE, room());
    if (max < 1) return null;
    const list = await src.listIds(q, max, token);
    let oldest: number | undefined;
    for (const id of list.ids) {
      if (budget.remaining < 1) return { next: token, oldest };   // the rest of this page next time (repeats are ignored)
      const m = await src.headersOf(id, HEADERS);
      const ex = exchangesOf(m.headers, m.labels, own);
      const sent = Date.parse(m.headers["date"] ?? "");
      const atMs = Number.isFinite(sent) ? sent : Number(m.internalDate ?? now);
      oldest = Math.min(oldest ?? atMs, atMs);
      if (!ex) continue;
      const stmts: D1PreparedStatement[] = [];
      for (const [i, w] of ex.who.entries()) {
        stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO circle_exchanges(user_id,key,channel,direction,at,account,who_enc,received_at)
            VALUES(?,?,'gmail',?,?,?,?,?)`).bind(userId, `gmail:${own}:${id}:${i}`, ex.direction, new Date(atMs).toISOString(), own, await seal(env, w), nowISO()));
      }
      const res = await env.DB.batch(stmts);
      stored += res.filter((r) => r.meta.changes > 0).length;
    }
    return { next: list.next, oldest };
  }

  try {
    // New mail since the last pass.
    if (!first && room() >= 2) {
      const start = c.live_start ?? nowS;
      const p = await page(`after:${c.live_after} ${BASE_QUERY}`, c.live_token);
      if (p) {
        if (p.next) { c.live_token = p.next; c.live_start = start; }
        else { c.live_after = start - 60; delete c.live_token; delete c.live_start; }
      }
    }
    // The backfill, newest first, one page at a time.
    while (!c.back_done && room() >= 2) {
      const p = await page(`after:${c.floor} before:${c.back_before} ${BASE_QUERY}`, c.back_token);
      if (!p) break;
      if (p.oldest !== undefined) {
        const o = new Date(p.oldest).toISOString();
        if (!completeFrom || o < completeFrom) completeFrom = o;
      }
      if (p.next) c.back_token = p.next;
      else { c.back_done = true; delete c.back_token; completeFrom = new Date(c.floor * 1000).toISOString(); }
    }
  } catch (e) {
    note = String((e as Error)?.message ?? e).slice(0, 300);
  }
  await env.DB.prepare(`INSERT INTO circle_readers(user_id,reader,as_of,complete_from,cursor,note) VALUES(?,?,?,?,?,?)
      ON CONFLICT(user_id,reader) DO UPDATE SET as_of=CASE WHEN excluded.note='' THEN excluded.as_of ELSE as_of END,
      complete_from=excluded.complete_from, cursor=excluded.cursor, note=excluded.note`)
    .bind(userId, reader, new Date(now).toISOString(), completeFrom, JSON.stringify(c), note).run();
  return { stored, done: !!c.back_done && !c.live_token };
}

/** Every enabled Gmail inbox of the user, within the shared budget. Never throws. */
export async function runCircleGmail(env: Env, userId: string, budget: Budget): Promise<void> {
  try {
    if (!(await circleOn(env, userId))) return;
    const rows = (await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1").bind(userId).all<SourceRow>()).results;
    for (const row of rows) {
      if (budget.remaining < 4) return;
      await readGmailMeta(env, userId, row, budget);
    }
  } catch (e) {
    console.warn(JSON.stringify({ event: "circle_gmail_failed", error: String((e as Error)?.message ?? e).slice(0, 300) }));
  }
}

/** Outlook rows as "heard from" (the extension sees incoming mail only): sender and time. Only while Circle is on. */
export async function recordOutlookExchanges(env: Env, userId: string, rows: { key: string; fromName: string; fromAddr: string | null; received: string }[]) {
  if (!rows.length || !(await circleOn(env, userId))) return;
  const stmts: D1PreparedStatement[] = [];
  for (const r of rows) {
    if (!r.fromAddr) continue;
    stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO circle_exchanges(user_id,key,channel,direction,at,account,who_enc,received_at)
        VALUES(?,?,'outlook','in',?,'',?,?)`).bind(userId, r.key, r.received, await seal(env, { h: r.fromAddr.toLowerCase(), n: r.fromName }), nowISO()));
  }
  stmts.push(env.DB.prepare(`INSERT INTO circle_readers(user_id,reader,as_of,cursor,note) VALUES(?,'outlook',?,'{}','incoming only')
      ON CONFLICT(user_id,reader) DO UPDATE SET as_of=excluded.as_of, note=excluded.note`).bind(userId, nowISO()));
  await env.DB.batch(stmts);
}
