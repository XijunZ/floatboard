/**
 * Reply drafts: a `draft_reply` event from the app (the user pressed Draft reply on an email card with Notes) becomes a
 * Gmail draft in that email's thread, and a `draft` item (the result the app applies to the card) on every outcome.
 * This is the only place FloatBoard creates or updates a Gmail draft, and nothing here ever sends.
 * Activity and run_events never get the Notes, the reply text or the email subject.
 */
import type { Budget } from "./budget";
import { decrypt } from "./crypto";
import { type Env, nowISO } from "./env";
import { makeClient } from "./llm";
import { draftLink, draftText, replyMime, replySubject } from "./mime";
import { firstName, pickReplyTarget, replyPrompt, writeReply } from "./reply";
import { logEvent } from "./runlog";
import { type DraftSnapshot, gmailSource, type GmailSource, SourceAuthError } from "./sources/gmail";
import type { SourceRow } from "./sources/types";

/** Calls one draft can need: token, sendAs, search, thread, read our earlier draft, Claude, create/update. */
export const DRAFT_CALLS = 7;
/** Tries for a draft that hits a passing problem (Gmail or network error) before it is answered as failed. */
export const DRAFT_ATTEMPTS = 3;
/** A card lock older than this belongs to a run that died. */
const LOCK_MS = 3 * 60e3;

export const DRAFT_ERRORS = {
  noInbox: "The inbox isn't connected",
  gone: "The email is no longer in Gmail",
  claude: "Claude couldn't write it",
  unreadable: "The request couldn't be read",
  unreachable: "Gmail couldn't be reached",
  gmailOnly: "Draft reply works for Gmail emails only for now",
} as const;

/** `account`: the Gmail inbox of an email the user linked to a task themselves (the sorting has no item for it). */
export type DraftRequest = { source_mid: string; source_sent: string | null; item_id: string | null; notes: string; request_id: string; account?: string | null };

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v : null);

/** The request, or what little can be read of it (to answer a malformed one: needs its request id and source email). */
export function readDraftRequest(p: Record<string, unknown>): { ok: true; req: DraftRequest } | { ok: false; answer: { request_id: string; source_mid: string } | null } {
  const request_id = str(p.request_id), source_mid = str(p.source_mid), notes = str(p.notes);
  const optional = (v: unknown) => v === undefined || v === null || typeof v === "string";
  if (request_id && source_mid && notes && optional(p.item_id) && optional(p.source_sent) && optional(p.account)) {
    return { ok: true, req: { request_id, source_mid, notes, item_id: str(p.item_id), source_sent: str(p.source_sent), account: str(p.account) } };
  }
  return { ok: false, answer: request_id && source_mid ? { request_id, source_mid } : null };
}

/** A passing problem (Gmail 5xx, network): worth another try; every other outcome is final. */
export class DraftRetry extends Error {}

type Outcome = { link: string; updated: boolean } | { error: string };
type Ctx = { env: Env; userId: string; calls: Budget; fetchFn?: typeof fetch; gmailFor?: (sourceId: string) => Promise<{ row: SourceRow; gmail: GmailSource } | null> };

const bracket = (id: string) => `<${id.trim().replace(/^<|>$/g, "")}>`;
const realId = (id: string) => !!id && !id.startsWith("gmail:");
const norm = (s: string) => s.replace(/\r\n?/g, "\n").trim();

/** What FloatBoard wrote into its draft (kept in the drafts table). */
type Written = { to: string; cc: string[]; subject: string; body: string };
/** The bare addresses of an address list, lower-case and sorted ("Anna <a@x>" -> "a@x"). */
const addrs = (list: string[]) => list.map((a) => (/<([^>]*)>\s*$/.exec(a)?.[1] ?? a).trim().toLowerCase()).filter(Boolean).sort();
const same = (a: string[], b: string[]) => JSON.stringify(addrs(a)) === JSON.stringify(addrs(b));

/** True when Gmail's copy of our draft is still exactly what FloatBoard wrote: same To, Cc, Subject and text (Gmail
 *  returns CRLF line ends, trimmed), and no attachments. Any difference means the user worked on it. */
const unchanged = (now: DraftSnapshot, ours: Written) => !now.attachments && norm(now.body) === ours.body
  && same(now.to, [ours.to]) && same(now.cc, ours.cc) && now.subject.trim() === ours.subject;

/** Lock the card (user + source email) so two presses or two runs never make two drafts; false = someone else has it. */
async function lock(env: Env, userId: string, mid: string): Promise<boolean> {
  const now = nowISO(), stale = new Date(Date.now() - LOCK_MS).toISOString();
  const r = await env.DB.prepare(`INSERT INTO drafts(user_id,source_mid,locked) VALUES(?,?,?)
      ON CONFLICT(user_id,source_mid) DO UPDATE SET locked=excluded.locked WHERE drafts.locked IS NULL OR drafts.locked < ?`)
    .bind(userId, mid, now, stale).run();
  return r.meta.changes > 0;
}
const unlock = (env: Env, userId: string, mid: string) =>
  env.DB.prepare("UPDATE drafts SET locked=NULL WHERE user_id=? AND source_mid=?").bind(userId, mid);

/** The draft result for the app: one `draft` item per card, replaced (new id, created = now) so /v2/proposals sends it again. */
function resultRow(env: Env, userId: string, a: { source_mid: string; source_sent?: string | null; request_id: string; source_id?: string | null },
    o: { link: string } | { error: string }) {
  return env.DB.prepare(`INSERT OR REPLACE INTO items(id,user_id,source_id,message_id,kind,title,why,link,task_ref,sent_at,created)
      VALUES(?,?,?,?,'draft','',?,?,?,?,?)`)
    .bind(crypto.randomUUID(), userId, a.source_id ?? null, a.source_mid, "error" in o ? o.error : null, "link" in o ? o.link : null,
      a.request_id, a.source_sent ?? null, nowISO());
}

/** A failed result for a request that could not be read (when its request id and source email can be read). */
export async function answerUnreadable(env: Env, userId: string, a: { request_id: string; source_mid: string }) {
  await resultRow(env, userId, a, { error: DRAFT_ERRORS.unreadable }).run();
}

/**
 * One try at the draft. Final outcomes (ready, or a failure with its reason) come back; a passing problem throws DraftRetry.
 * Gmail is only written to after Claude has answered.
 */
async function makeDraft(c: Ctx, req: DraftRequest): Promise<Outcome & { sourceId?: string }> {
  const { env, userId } = c;
  const cols = "source_id";
  const item = (req.item_id ? await env.DB.prepare(`SELECT ${cols} FROM items WHERE id=? AND user_id=? AND kind<>'draft'`).bind(req.item_id, userId).first<{ source_id: string | null }>() : null)
    ?? await env.DB.prepare(`SELECT ${cols} FROM items WHERE user_id=? AND message_id=? AND kind='action' LIMIT 1`).bind(userId, req.source_mid).first<{ source_id: string | null }>();
  // Outlook emails (read by the Chrome extension) can't be replied to from here: nothing is ever written to Outlook.
  if (req.source_mid.startsWith("owa:")) return { error: DRAFT_ERRORS.gmailOnly, sourceId: item?.source_id ?? undefined };
  let sourceId: string | null = item?.source_id ?? null;
  if (!item && req.account) {
    // An email the user linked to a task: its inbox is the one they picked it from, if it is one of theirs.
    const own = await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind='gmail' AND address=?").bind(userId, req.account).first<{ id: string }>();
    if (!own) return { error: DRAFT_ERRORS.noInbox };
    sourceId = own.id;
  } else if (!item) return { error: DRAFT_ERRORS.gone };
  if (!sourceId) return { error: DRAFT_ERRORS.noInbox };
  const src = c.gmailFor ? await c.gmailFor(sourceId) : await (async () => {
    const row = await env.DB.prepare("SELECT * FROM sources WHERE id=? AND user_id=? AND kind='gmail' AND enabled=1").bind(sourceId, userId).first<SourceRow>();
    return row ? { row, gmail: gmailSource(env, row, c.calls.wrap(c.fetchFn)) } : null;
  })();
  if (!src) return { error: DRAFT_ERRORS.noInbox, sourceId };
  const key = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  if (!key?.anthropic_key_enc) return { error: DRAFT_ERRORS.claude, sourceId };
  let apiKey: string;
  try { apiKey = await decrypt(env, key.anthropic_key_enc); }
  catch { return { error: DRAFT_ERRORS.claude, sourceId }; } // a key that can't be read won't work on a retry either

  try {
    const own = await src.gmail.ownAddresses();
    const inboxes = (await env.DB.prepare("SELECT address FROM sources WHERE user_id=? AND kind='gmail'").bind(userId).all<{ address: string }>()).results.map((r) => r.address);
    const thread = await src.gmail.findThread(req.source_mid);
    if (!thread || !thread.messages.length) return { error: DRAFT_ERRORS.gone, sourceId };
    const pick = pickReplyTarget(thread.messages, [...own.addresses, ...inboxes, src.row.address]);
    if ("error" in pick) return { error: pick.error, sourceId };

    const prev = await env.DB.prepare("SELECT gmail_draft_id, body, to_addr, cc_addrs, subject FROM drafts WHERE user_id=? AND source_mid=?")
      .bind(userId, req.source_mid)
      .first<{ gmail_draft_id: string | null; body: string | null; to_addr: string | null; cc_addrs: string | null; subject: string | null }>();
    // Never overwrite the user's work: update only while FloatBoard's draft still exists exactly as FloatBoard wrote it.
    // A record without the recipients and subject (written before they were kept) can't be checked: a new draft then.
    let reuse: string | null = null;
    if (prev?.gmail_draft_id && prev.body != null && prev.to_addr != null && prev.cc_addrs != null && prev.subject != null) {
      let cc: string[] | null = null;
      try { const v = JSON.parse(prev.cc_addrs); if (Array.isArray(v)) cc = v.map(String); } catch { cc = null; } // unreadable: can't check, new draft
      const now = cc ? await src.gmail.draftSnapshot(prev.gmail_draft_id) : null;
      if (cc && now !== null && unchanged(now, { to: prev.to_addr, cc, subject: prev.subject, body: prev.body })) reuse = prev.gmail_draft_id;
    }

    const me = own.displayName ? firstName(own.displayName) : undefined;
    const them = firstName(pick.target.from);
    const client = makeClient(apiKey, c.calls.wrap(c.fetchFn));
    const reply = await writeReply(client, replyPrompt(thread.messages, pick.target, req.notes, { me, them }));
    if (!reply.ok) return { error: reply.reason, sourceId };

    const aiLine = !!(await env.DB.prepare("SELECT ai_footer FROM settings WHERE user_id=?").bind(userId).first<{ ai_footer: number }>())?.ai_footer;
    const upTo = thread.messages.slice(0, thread.messages.indexOf(pick.target) + 1).map((m) => m.messageId).filter(realId);
    const raw = replyMime({
      from: own.displayName ? `${own.displayName} <${src.row.address}>` : src.row.address,
      to: pick.to, cc: pick.cc, subject: pick.target.subject,
      inReplyTo: realId(pick.target.messageId) ? bracket(pick.target.messageId) : "",
      references: upTo.map(bracket).join(" "),
      body: reply.text, aiLine,
    });
    const saved = reuse ? await src.gmail.updateDraft(reuse, raw, thread.threadId) : await src.gmail.createDraft(raw, thread.threadId);
    // Recorded at once, in its own write: a run cut off after this point leaves the draft known (and checkable), so the
    // next try updates it instead of putting a second draft in the thread.
    await env.DB.prepare("UPDATE drafts SET gmail_draft_id=?, body=?, to_addr=?, cc_addrs=?, subject=?, updated=? WHERE user_id=? AND source_mid=?")
      .bind(saved.draftId, norm(draftText(reply.text, aiLine)), pick.to, JSON.stringify(pick.cc), replySubject(pick.target.subject), nowISO(), userId, req.source_mid).run();
    return { link: draftLink(src.row.address, saved.messageId), updated: !!reuse, sourceId };
  } catch (e) {
    if (e instanceof SourceAuthError) return { error: e.message, sourceId };
    const msg = (e as Error)?.message ?? String(e);
    if (/^Gmail 403\b/.test(msg)) return { error: `Reconnect ${src.row.address} to let FloatBoard create drafts.`, sourceId };
    throw new DraftRetry(msg.slice(0, 300));
  }
}

const trace = (env: Env, userId: string, runId: string, uuid: string, decision: string, detail?: string) =>
  logEvent(env, { run_id: runId, user_id: userId, decision, detail, trace: uuid });

/**
 * Process one draft request (the caller holds the card's lock). Writes the result row, the unlock and (for an app event,
 * `finishEvent`) the event's processed=1 in one batch, so a card is never unlocked while its event still looks pending.
 * FloatBoard's draft record was already written right after Gmail saved the draft. `lastTry` turns a passing problem into a failed result instead of DraftRetry.
 */
async function draftAndAnswer(c: Ctx, req: DraftRequest, o: { runId: string; uuid: string; lastTry: boolean; finishEvent?: boolean }): Promise<void> {
  const { env, userId } = c;
  let out: Awaited<ReturnType<typeof makeDraft>>;
  try {
    out = await makeDraft(c, req);
  } catch (e) {
    if (!o.lastTry) {
      await unlock(env, userId, req.source_mid).run();
      throw e;
    }
    out = { error: DRAFT_ERRORS.unreachable };
    await trace(env, userId, o.runId, o.uuid, "draft: giving up after an error", ((e as Error)?.message ?? String(e)).slice(0, 300)).run();
  }
  const stmts = [resultRow(env, userId, { ...req, source_id: out.sourceId }, out), unlock(env, userId, req.source_mid)];
  stmts.push("link" in out
    ? trace(env, userId, o.runId, o.uuid, "draft ready", out.updated ? "updated FloatBoard's earlier draft" : "new draft in the thread")
    : trace(env, userId, o.runId, o.uuid, "draft failed", out.error));
  if (o.finishEvent) stmts.push(env.DB.prepare("UPDATE app_events SET processed=1, last_error=NULL WHERE uuid=?").bind(o.uuid));
  await env.DB.batch(stmts);
}

export const SUPERSEDED = "draft skipped: a newer request replaced it";

/** True when a newer draft_reply (later `received`, or the same time and a later rowid) exists for the same email. */
export async function superseded(env: Env, userId: string, uuid: string, sourceMid: string): Promise<boolean> {
  const r = await env.DB.prepare(`SELECT 1 FROM app_events n, app_events o WHERE o.uuid=? AND n.user_id=? AND n.kind='draft_reply' AND n.uuid<>o.uuid
      AND json_valid(n.payload) AND json_extract(n.payload,'$.source_mid')=?
      AND (n.received > o.received OR (n.received = o.received AND n.rowid > o.rowid)) LIMIT 1`).bind(uuid, userId, sourceMid).first();
  return !!r;
}

/**
 * The draft_reply branch of processEvents. Returns "done" (answered, and the event marked processed), "superseded" (a newer request for the same email exists:
 * marked processed with nothing else done), "already" (another
 * pass finished this event after this pass listed it: nothing done), "busy" (another run is drafting this card: leave
 * the event for later), or throws a passing problem (the caller counts the attempt and retries next run).
 */
export async function draftReplyEvent(c: Ctx, req: DraftRequest, o: { runId: string; uuid: string; attempts: number }): Promise<"done" | "already" | "busy" | "superseded"> {
  if (!(await lock(c.env, c.userId, req.source_mid))) return "busy";
  const ev = await c.env.DB.prepare("SELECT processed FROM app_events WHERE uuid=?").bind(o.uuid).first<{ processed: number }>();
  if (ev && ev.processed !== 0) {
    await unlock(c.env, c.userId, req.source_mid).run();
    return "already";
  }
  // A newer press for the same email replaced this one (the app only waits for the newest request): finish it with no
  // Claude call, no Gmail call and no result, so it can never rewrite the newer draft from older Notes.
  if (await superseded(c.env, c.userId, o.uuid, req.source_mid)) {
    await c.env.DB.batch([
      c.env.DB.prepare("UPDATE app_events SET processed=1, last_error=NULL WHERE uuid=?").bind(o.uuid),
      unlock(c.env, c.userId, req.source_mid),
      trace(c.env, c.userId, o.runId, o.uuid, SUPERSEDED),
    ]);
    return "superseded";
  }
  await draftAndAnswer(c, req, { runId: o.runId, uuid: o.uuid, lastTry: o.attempts + 1 >= DRAFT_ATTEMPTS, finishEvent: true });
  return "done";
}

/**
 * One draft request, start to finish, in a single try: never throws. It leaves a result row for the app (ready, or
 * failed with the reason; a malformed request is answered when its request id and source email can be read), except
 * when another run is drafting this card right now: that run writes the card's result, so nothing is written here.
 */
export async function handleDraftReply(env: Env, userId: string, p: Record<string, string>, calls: Budget, fetchFn?: typeof fetch): Promise<void> {
  const uuid = `draft:${typeof p?.request_id === "string" ? p.request_id : ""}`;
  const r = readDraftRequest(p ?? {});
  let locked = false;
  try {
    if (!r.ok) { if (r.answer) await answerUnreadable(env, userId, r.answer); return; }
    if (!(await lock(env, userId, r.req.source_mid))) return;
    locked = true;
    await draftAndAnswer({ env, userId, calls, fetchFn }, r.req, { runId: "draft", uuid, lastTry: true });
  } catch (e) {
    console.warn("draft reply failed:", (e as Error)?.message);
    try {
      const a = r.ok ? r.req : r.answer;
      if (a) await resultRow(env, userId, a, { error: DRAFT_ERRORS.unreachable }).run();
      if (a && locked) await unlock(env, userId, a.source_mid).run(); // only a lock this call took
    } catch (e2) { console.warn("draft result not written:", (e2 as Error)?.message); }
  }
}
