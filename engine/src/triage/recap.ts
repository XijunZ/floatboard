import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { Env } from "../env";
import { nowISO } from "../env";
import { logEvent } from "../lib/runlog";
import { decrypt } from "../lib/crypto";
import { askStructured, chosenModel, makeClient } from "../lib/llm";
import { recapKeys } from "../sources/fathom";
import type { Message } from "../sources/types";

export type FollowUp = { title: string; due: string | null; has_time: boolean; importance: 0 | 1 | 2; group?: string | null };
/** Who the notes are for, and their groups, so follow-ups are theirs and land in the right group. */
export type RecapContext = { name?: string; groups?: string[]; groupNotes?: Record<string, string>; myRules?: string };
export type Recap = { summary: string; actions: FollowUp[] };

const RecapSchema = z.object({
  decisions: z.array(z.string()),
  next_steps: z.array(z.string()),
  my_actions: z.array(z.object({ title: z.string(), due: z.string().nullable(), has_time: z.boolean(), importance: z.number().int(),
    group: z.string().nullable().optional() })),
});

const SYSTEM = `You condense meeting notes for the person who attended. Return:
decisions: what was agreed (short phrases, max 4);
next_steps: follow-ups by anyone (short, with owner names, max 5);
my_actions: only follow-ups the attendee must do personally, each as a short imperative task title (max 80 chars),
with due ("YYYY-MM-DD" or "YYYY-MM-DDTHH:mm") only if stated, has_time, importance 2/1/0, and group: the one of the
attendee's groups it belongs to (exact name), or null if none fits.
Follow-ups owned by other people are not my_actions, even when they are about the attendee or done for them
("send X the deck", "intro X to Y", "keep X's plans confidential"): put those in next_steps.`;

/** Summarise a recap (decisions / next steps + link) and extract the attendee's own follow-ups. */
export async function summariseRecap(m: Message, client: Anthropic, ctx: RecapContext = {}): Promise<{ ok: true; recap: Recap } | { ok: false; reason: "refusal" | "unparseable" }> {
  const groups = ctx.groups ?? [];
  const about = [
    ctx.name?.trim() && `The attendee is ${ctx.name.trim()}.`,
    groups.length && `The attendee's groups:\n${groups.map((g) => `- ${g}${ctx.groupNotes?.[g] ? `: ${ctx.groupNotes[g]}` : ""}`).join("\n")}`,
    ctx.myRules?.trim() && `The attendee's own rules:\n${ctx.myRules.trim()}`,
  ].filter(Boolean).join("\n");
  const res = await askStructured(client, { system: SYSTEM, user: `${about ? about + "\n\n" : ""}Subject: ${m.subject}\n\n${m.text}`, schema: RecapSchema });
  if (!res.ok) return res;
  const r = res.value;
  const line = (label: string, xs: string[]) => (xs.length ? `${label}: ${xs.join("; ")}` : "");
  let summary = [line("Decisions", r.decisions), line("Next steps", r.next_steps)].filter(Boolean).join("\n");
  if (summary.length > 600) summary = summary.slice(0, 597) + "…";
  if (m.link) summary += `\nFull notes: ${m.link}`;
  const actions = r.my_actions.filter((a) => a.title.trim()).map((a) => ({
    title: a.title.trim().slice(0, 80), due: a.due, has_time: a.has_time,
    importance: Math.min(2, Math.max(0, a.importance)) as 0 | 1 | 2,
    group: a.group && groups.includes(a.group) ? a.group : null,
  }));
  return { ok: true, recap: { summary: summary || "Meeting notes received.", actions } };
}

/** A claim older than this was left by a delivery that died mid-way: another may take the meeting over. */
const CLAIM_STALE_MS = 10 * 60e3;
const staleBefore = () => new Date(Date.now() - CLAIM_STALE_MS).toISOString();

/**
 * Claims every alias of one meeting at once, before its notes are judged (round 40): all of them or none, in one
 * transaction, so of two deliveries arriving together (the webhook and the recap email) only one judges and stores.
 * Returns the claim, or null when another delivery has the meeting (or already stored it).
 */
export async function claimRecap(env: Env, userId: string, keys: string[]): Promise<string | null> {
  const claim = crypto.randomUUID(), now = nowISO(), stale = staleBefore();
  const q = keys.map(() => "?").join(",");
  const stmts = keys.map((k) => env.DB.prepare(`INSERT INTO recap_keys(user_id,key,created,claim) VALUES(?,?,?,?)
      ON CONFLICT(user_id,key) DO UPDATE SET claim=excluded.claim, created=excluded.created
      WHERE recap_keys.claim IS NOT NULL AND recap_keys.created < ?`).bind(userId, k, now, claim, stale));
  // Not every alias could be taken: the ones that were are given back in the same transaction.
  stmts.push(env.DB.prepare(`DELETE FROM recap_keys WHERE user_id=? AND claim=?
      AND (SELECT count(*) FROM recap_keys WHERE user_id=? AND key IN (${q}) AND claim=?) < ?`).bind(userId, claim, userId, ...keys, claim, keys.length));
  stmts.push(env.DB.prepare(`SELECT count(*) AS n FROM recap_keys WHERE user_id=? AND claim=?`).bind(userId, claim));
  const out = await env.DB.batch(stmts);
  const n = (out[out.length - 1].results as { n: number }[])[0]?.n ?? 0;
  return n === keys.length ? claim : null;
}

/** Gives a meeting back (its notes couldn't be judged now; a later delivery may try). */
export function releaseRecap(env: Env, userId: string, claim: string) {
  return env.DB.prepare("DELETE FROM recap_keys WHERE user_id=? AND claim=?").bind(userId, claim).run();
}

/**
 * Save the summary and one action item per follow-up. With `claim` (round 40) every row is written only while that claim
 * still holds the meeting, and the claim is then marked done, all in one transaction.
 */
export async function storeRecap(env: Env, userId: string, m: Message, r: Recap, keys: string[] = [m.messageId], claim?: string): Promise<void> {
  const now = nowISO();
  const held = (sql: string) => claim ? sql.replace(/VALUES\(([\s\S]*)\)\s*$/, "SELECT $1 WHERE EXISTS (SELECT 1 FROM recap_keys WHERE user_id=? AND claim=?)") : sql;
  const extra = claim ? [userId, claim] : [];
  const stmts = [env.DB.prepare(held(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,sender,subject,link,summary,created)
      VALUES(?,?,?,?, 'summary', ?,?,?,?,?,?)`))
    .bind(crypto.randomUUID(), userId, m.sourceId, m.messageId, m.subject, m.from, m.subject, m.link, r.summary, now, ...extra)];
  // Follow-ups are tasks, so they need a source key: their own message id (<mid>#n) and when the recap was sent.
  const header = Date.parse(m.date);
  const sentAt = m.sentAt ?? (isNaN(header) ? now : new Date(header).toISOString());
  // Each follow-up carries the meeting's notes (decisions, next steps, link to the full notes).
  r.actions.forEach((a, i) => stmts.push(env.DB.prepare(held(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,why,sender,subject,link,due,has_time,importance,created,history_id,sent_at,summary,group_name)
      VALUES(?,?,?,?, 'action', ?,?,?,?,?,?,?,?,?,?,?,?,?)`))
    .bind(crypto.randomUUID(), userId, m.sourceId, `${m.messageId}#${i + 1}`, a.title, `Follow-up from "${m.subject}"`,
      m.from, m.subject, m.link, a.due, a.has_time ? 1 : 0, a.importance, now, m.historyId ?? null, sentAt, r.summary, a.group ?? null, ...extra)));
  for (const k of keys) stmts.push(env.DB.prepare("INSERT OR IGNORE INTO recap_keys(user_id,key,created) VALUES(?,?,?)").bind(userId, k, now));
  if (claim) stmts.push(env.DB.prepare("UPDATE recap_keys SET claim=NULL WHERE user_id=? AND claim=?").bind(userId, claim));
  await env.DB.batch(stmts);
}

/**
 * True when any of these meeting keys was already stored (by this or an earlier version, which kept only the summary row),
 * or archived. A meeting another delivery is still working on (an active claim) is not stored yet: see `recapBusy`.
 */
export async function recapKnown(env: Env, userId: string, keys: string[]): Promise<boolean> {
  const q = keys.map(() => "?").join(",");
  const hit = await env.DB.prepare(`SELECT 1 FROM recap_keys WHERE user_id=? AND key IN (${q}) AND claim IS NULL
      UNION ALL SELECT 1 FROM items WHERE user_id=? AND kind='summary' AND message_id IN (${q})
      UNION ALL SELECT 1 FROM archived_items WHERE user_id=? AND message_id IN (${q}) LIMIT 1`)
    .bind(userId, ...keys, userId, ...keys, userId, ...keys).first();
  return !!hit;
}

/** True while another delivery holds a fresh claim on this meeting (round 41): not done yet, so try again later. */
export async function recapBusy(env: Env, userId: string, keys: string[]): Promise<boolean> {
  const q = keys.map(() => "?").join(",");
  return !!(await env.DB.prepare(`SELECT 1 FROM recap_keys WHERE user_id=? AND key IN (${q}) AND claim IS NOT NULL AND created >= ? LIMIT 1`)
    .bind(userId, ...keys, staleBefore()).first());
}

/** `busy`: another delivery is saving this meeting right now; nothing was stored, so the caller must try again later. */
export type RecapOutcome = { status: "stored" | "duplicate" | "busy" } | { status: "unusable"; reason: string };

/**
 * Full recap path for one message: dedupe per meeting, summarise with Haiku, store.
 * - Claude's answer unreadable: nothing is stored and `{status:"unusable"}` is returned, so the caller can retry,
 *   unless `opts.rawOnUnusable` is set (webhooks can't retry), in which case the raw notes are kept and the problem is logged.
 * - No Claude key, or `opts.useClaude === false` (the caller gave up on Claude): the raw notes are kept.
 */
export async function processRecap(env: Env, userId: string, raw: Message, fetchFn?: typeof fetch,
    opts: { useClaude?: boolean; rawOnUnusable?: boolean } = {}): Promise<RecapOutcome> {
  const keys = recapKeys(raw);
  const m = { ...raw, messageId: keys[0] };
  if (await recapKnown(env, userId, keys)) return { status: "duplicate" };
  // Round 40: the meeting is claimed (all its aliases at once) before it is judged; another delivery has it: a duplicate.
  const claim = await claimRecap(env, userId, keys);
  if (!claim) return (await recapBusy(env, userId, keys)) ? { status: "busy" } : { status: "duplicate" };
  try {
    const out = await judgeAndStore(env, userId, m, keys, claim, fetchFn, opts);
    if (out.status !== "stored") await releaseRecap(env, userId, claim);
    return out;
  } catch (e) {
    await releaseRecap(env, userId, claim);
    throw e;
  }
}

async function judgeAndStore(env: Env, userId: string, m: Message, keys: string[], claim: string, fetchFn: typeof fetch | undefined,
    opts: { useClaude?: boolean; rawOnUnusable?: boolean }): Promise<RecapOutcome> {
  const u = await env.DB.prepare("SELECT anthropic_key_enc, name FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null; name: string | null }>();
  let r: Recap | null = null;
  if (u?.anthropic_key_enc && opts.useClaude !== false) {
    const s = await env.DB.prepare("SELECT groups, group_notes, my_rules FROM settings WHERE user_id=?").bind(userId)
      .first<{ groups: string | null; group_notes: string | null; my_rules: string | null }>();
    const ctx: RecapContext = { name: u.name ?? undefined, groups: JSON.parse(s?.groups ?? "[]"), groupNotes: JSON.parse(s?.group_notes ?? "{}"), myRules: s?.my_rules ?? "" };
    const res = await summariseRecap(m, makeClient(await decrypt(env, u.anthropic_key_enc), fetchFn,
      { env, userId, job: "recap", model: await chosenModel(env, userId, "recap") }), ctx);
    if (res.ok) r = res.recap;
    else if (!opts.rawOnUnusable) return { status: "unusable", reason: res.reason };
    else {
      await logEvent(env, { run_id: "recap", user_id: userId, subject: m.subject, decision: "meeting notes kept unsummarised",
        detail: `Claude's answer could not be used (${res.reason})`, trace: m.messageId }).run();
    }
  }
  if (!r) {
    const text = m.text.length > 600 ? m.text.slice(0, 597) + "…" : m.text;
    r = { summary: m.link && !text.includes(m.link) ? `${text}\nFull notes: ${m.link}` : text, actions: [] };
  }
  await storeRecap(env, userId, m, r, keys, claim);
  return { status: "stored" };
}
