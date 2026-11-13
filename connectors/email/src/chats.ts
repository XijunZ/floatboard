/**
 * Chats screened for tasks. The Mac reads WhatsApp Desktop's own copy of the person's messages on the Mac (nothing
 * talks to WhatsApp), applies the free rules (archived, status, channels, already answered, no words; muted chats are
 * sent marked `muted` and judged more strictly) and sends
 * each chat's new unread messages here with the user key: POST /v2/chats. Rows are stored once by their key and judged
 * by the triage run (src/sources/chat.ts, rulebook src/skills/chat-triage.md); new rows are judged right away in the
 * background.
 *
 * Answers: 200 {stored, duplicates, skipped} = the whole batch is acknowledged (unusable chats are skipped, never
 * refused, so one bad chat can't block the Mac's queue); 400 = the body isn't a batch; 401 = wrong key.
 */
import { type Env, json, nowISO } from "./env";
import { readCappedJSON } from "./http";
import { route } from "./router";
import { logEvent } from "./runlog";
import { Budget, CALLS_PER_INVOCATION } from "./budget";
import { recordCrash, runUser } from "./run";
import { alertFor } from "./alerts";

export const CHAT_APPS = { whatsapp: "WhatsApp" } as const;
export type ChatApp = keyof typeof CHAT_APPS;
export const CHAT_KINDS: string[] = Object.keys(CHAT_APPS);
const MAX_CHATS = 100, MAX_BODY = 1_200_000, MAX_TRANSCRIPT = 8000;
/** Chats judged right after they arrive; the rest by the hourly run. */
export const JUDGE_CHATS_NOW = 10;
const KEEP_PROCESSED_MS = 30 * 86400e3;

export type ChatRow = { key: string; name: string; group: boolean; muted: boolean; senders: string; transcript: string; link: string; received: string };

const clean = (v: unknown, max: number): string | null =>
  typeof v === "string" ? v.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ").trim().slice(0, max) : null;

/** Only links that open the chat app (never a web page the Mac didn't make). */
export function chatLink(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  return /^whatsapp:\/\/(send\?phone=\d{5,20})?$/.test(s) || /^https:\/\/wa\.me\/\d{5,20}$/.test(s) ? s : "";
}

/** One chat from the Mac, checked and trimmed, or null when it can't be used. */
export function readChat(x: unknown): ChatRow | null {
  if (!x || typeof x !== "object") return null;
  const r = x as Record<string, unknown>;
  const key = clean(r.key, 300), name = clean(r.name, 200), transcript = clean(r.transcript, MAX_TRANSCRIPT);
  if (!key || !/^wa:/.test(key) || name === null || !transcript) return null;
  const t = typeof r.received === "string" ? Date.parse(r.received) : NaN;
  if (!Number.isFinite(t)) return null;
  const senders = Array.isArray(r.senders) ? r.senders.map((s) => clean(s, 100)).filter(Boolean).slice(0, 20).join(", ") : "";
  return { key, name: name || "(no name)", group: r.group === true, muted: r.muted === true, senders, transcript, link: chatLink(r.link), received: new Date(t).toISOString() };
}

async function chatSource(env: Env, userId: string, app: ChatApp): Promise<string> {
  const found = await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind=?").bind(userId, app).first<{ id: string }>();
  if (found) return found.id;
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT OR IGNORE INTO sources(id,user_id,kind,address,enabled,created) VALUES(?,?,?,?,1,?)")
    .bind(id, userId, app, CHAT_APPS[app], nowISO()).run();
  return (await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind=?").bind(userId, app).first<{ id: string }>())!.id;
}

export function pruneChatRows(env: Env, userId: string) {
  return env.DB.prepare("DELETE FROM chat_rows WHERE user_id=? AND processed=1 AND processed_at < ?")
    .bind(userId, new Date(Date.now() - KEEP_PROCESSED_MS).toISOString());
}

route("POST", "/v2/chats", async (req, env, user, _p, ctx) => {
  const rb = await readCappedJSON(req, MAX_BODY);
  if (!rb.ok) return json({ error: rb.tooLarge ? "too large" : "body must be JSON" }, rb.tooLarge ? 413 : 400);
  const body = rb.body as Record<string, unknown>;
  const app = body.app;
  if (typeof app !== "string" || !(app in CHAT_APPS)) return json({ error: `app must be one of ${CHAT_KINDS.join(", ")}` }, 400);
  const chats = body.chats ?? [];
  if (!Array.isArray(chats) || chats.length > MAX_CHATS) return json({ error: `chats must be a list of at most ${MAX_CHATS}` }, 400);
  const sourceId = await chatSource(env, user.id, app as ChatApp);
  const now = nowISO();
  const rows = chats.map(readChat);
  const good = rows.filter((r): r is ChatRow => r !== null);
  const results = good.length ? await env.DB.batch(good.map((r) => env.DB.prepare(`INSERT OR IGNORE INTO chat_rows
      (user_id,source_id,row_key,app,chat_name,is_group,muted,senders,transcript,link,received,created) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`)
    .bind(user.id, sourceId, r.key, app, r.name, r.group ? 1 : 0, r.muted ? 1 : 0, r.senders, r.transcript, r.link, r.received, now))) : [];
  const stored = results.filter((r) => r.meta.changes > 0).length;
  const skipped = rows.length - good.length;
  const stmts = [env.DB.prepare("UPDATE sources SET last_run=?, last_error=NULL WHERE id=?").bind(now, sourceId), pruneChatRows(env, user.id)];
  if (skipped) stmts.push(logEvent(env, { run_id: "chats", user_id: user.id, source: CHAT_APPS[app as ChatApp],
    decision: "chats skipped: unreadable", detail: `${skipped} of ${rows.length}` }));
  await env.DB.batch(stmts);
  if (stored) ctx.waitUntil(judgeChatsNow(env, user.id));
  return json({ ok: true, stored, duplicates: good.length - stored, skipped });
});

/** Judge up to JUDGE_CHATS_NOW waiting chats now. Never throws: a crash is recorded as a run like any other. */
export async function judgeChatsNow(env: Env, userId: string, fetchFn?: typeof fetch): Promise<void> {
  const started = nowISO();
  const calls = new Budget(Math.min(CALLS_PER_INVOCATION, 2 * JUDGE_CHATS_NOW + 4));
  try {
    const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
    if (!u?.anthropic_key_enc) return;
    await runUser(env, userId, { kinds: CHAT_KINDS, budget: JUDGE_CHATS_NOW, calls, fetchFn, alert: alertFor(env, userId) });
  } catch (e) {
    await recordCrash(env, userId, started, e, calls.used);
  }
}
