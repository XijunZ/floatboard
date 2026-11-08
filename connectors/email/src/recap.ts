import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { Env } from "./env";
import { nowISO } from "./env";
import { logEvent } from "./runlog";
import { decrypt } from "./crypto";
import { askStructured, makeClient } from "./llm";
import { recapKey } from "./sources/fathom";
import type { Message } from "./sources/types";

export type FollowUp = { title: string; due: string | null; has_time: boolean; importance: 0 | 1 | 2 };
export type Recap = { summary: string; actions: FollowUp[] };

const RecapSchema = z.object({
  decisions: z.array(z.string()),
  next_steps: z.array(z.string()),
  my_actions: z.array(z.object({ title: z.string(), due: z.string().nullable(), has_time: z.boolean(), importance: z.number().int() })),
});

const SYSTEM = `You condense meeting notes for the person who attended. Return:
decisions: what was agreed (short phrases, max 4);
next_steps: follow-ups by anyone (short, with owner names, max 5);
my_actions: only follow-ups the attendee must do personally, each as a short imperative task title (max 80 chars),
with due ("YYYY-MM-DD" or "YYYY-MM-DDTHH:mm") only if stated, has_time, importance 2/1/0.`;

/** Summarise a recap (decisions / next steps + link) and extract the attendee's own follow-ups. */
export async function summariseRecap(m: Message, client: Anthropic): Promise<{ ok: true; recap: Recap } | { ok: false; reason: "refusal" | "unparseable" }> {
  const res = await askStructured(client, { system: SYSTEM, user: `Subject: ${m.subject}\n\n${m.text}`, schema: RecapSchema });
  if (!res.ok) return res;
  const r = res.value;
  const line = (label: string, xs: string[]) => (xs.length ? `${label}: ${xs.join("; ")}` : "");
  let summary = [line("Decisions", r.decisions), line("Next steps", r.next_steps)].filter(Boolean).join("\n");
  if (summary.length > 600) summary = summary.slice(0, 597) + "…";
  if (m.link) summary += `\nFull notes: ${m.link}`;
  const actions = r.my_actions.filter((a) => a.title.trim()).map((a) => ({
    title: a.title.trim().slice(0, 80), due: a.due, has_time: a.has_time,
    importance: Math.min(2, Math.max(0, a.importance)) as 0 | 1 | 2,
  }));
  return { ok: true, recap: { summary: summary || "Meeting notes received.", actions } };
}

/** Save the summary and one action item per follow-up. */
export async function storeRecap(env: Env, userId: string, m: Message, r: Recap): Promise<void> {
  const now = nowISO();
  const stmts = [env.DB.prepare(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,sender,subject,link,summary,created)
      VALUES(?,?,?,?, 'summary', ?,?,?,?,?,?)`)
    .bind(crypto.randomUUID(), userId, m.sourceId, m.messageId, m.subject, m.from, m.subject, m.link, r.summary, now)];
  // Follow-ups are tasks, so they need a source key: their own message id (<mid>#n) and when the recap was sent.
  const header = Date.parse(m.date);
  const sentAt = m.sentAt ?? (isNaN(header) ? now : new Date(header).toISOString());
  r.actions.forEach((a, i) => stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO items(id,user_id,source_id,message_id,kind,title,why,sender,subject,link,due,has_time,importance,created,history_id,sent_at)
      VALUES(?,?,?,?, 'action', ?,?,?,?,?,?,?,?,?,?,?)`)
    .bind(crypto.randomUUID(), userId, m.sourceId, `${m.messageId}#${i + 1}`, a.title, `Follow-up from "${m.subject}"`,
      m.from, m.subject, m.link, a.due, a.has_time ? 1 : 0, a.importance, now, m.historyId ?? null, sentAt)));
  await env.DB.batch(stmts);
}

export type RecapOutcome = { status: "stored" | "duplicate" } | { status: "unusable"; reason: string };

/**
 * Full recap path for one message: dedupe per meeting, summarise with Haiku, store.
 * - Claude's answer unreadable: nothing is stored and `{status:"unusable"}` is returned, so the caller can retry,
 *   unless `opts.rawOnUnusable` is set (webhooks can't retry), in which case the raw notes are kept and the problem is logged.
 * - No Claude key, or `opts.useClaude === false` (the caller gave up on Claude): the raw notes are kept.
 */
export async function processRecap(env: Env, userId: string, raw: Message, fetchFn?: typeof fetch,
    opts: { useClaude?: boolean; rawOnUnusable?: boolean } = {}): Promise<RecapOutcome> {
  const m = { ...raw, messageId: recapKey(raw) };
  const dup = await env.DB.prepare("SELECT 1 FROM items WHERE user_id=? AND message_id=? AND kind='summary'").bind(userId, m.messageId).first();
  if (dup) return { status: "duplicate" };
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  let r: Recap | null = null;
  if (u?.anthropic_key_enc && opts.useClaude !== false) {
    const res = await summariseRecap(m, makeClient(await decrypt(env, u.anthropic_key_enc), fetchFn));
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
  await storeRecap(env, userId, m, r);
  return { status: "stored" };
}
