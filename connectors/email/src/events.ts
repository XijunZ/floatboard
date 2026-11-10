import type { Budget } from "./budget";
import { type Env, nowISO } from "./env";
import { logEvent } from "./runlog";
import { maybeConsolidateForUser } from "./learn";
import { gmailIdFromLink, gmailSource, type GmailSource } from "./sources/gmail";
import { answerUnreadable, DRAFT_CALLS, draftReplyEvent, readDraftRequest, superseded } from "./drafts";
import type { SourceRow } from "./sources/types";

const MAX_ATTEMPTS_SHOWN = 5;
const EXCERPT_CHARS = 1500;
/** Gmail calls an event needs, plus one for the access token the first time an inbox is used in this run:
 *  `done` = check the message's current state + mark read (learning = read the original email). When the message
 *  changed since we read it, `done` also reads the UNREAD-label history: each page is fetched only if it and the
 *  mark-read still fit, otherwise the event waits for the next run (so a done needs up to 3 calls + token). */
const DONE_CALLS = 2, READ_CALLS = 1;

type AppEvent = { uuid: string; kind: string; payload: string; attempts: number; last_error: string | null };
type ItemRow = { id: string; source_id: string | null; link: string | null; subject: string | null; sender: string | null; snippet: string | null; why: string | null; history_id: string | null };

/** One trace line about an event (run_events.trace = the event uuid). */
async function trace(env: Env, userId: string, runId: string, uuid: string, decision: string, detail?: string, item?: ItemRow | null) {
  await logEvent(env, { run_id: runId, user_id: userId, sender: item?.sender, subject: item?.subject, decision, detail, trace: uuid }).run();
}

async function findItem(env: Env, userId: string, p: Record<string, string>): Promise<ItemRow | null> {
  const cols = "id, source_id, link, subject, sender, snippet, why, history_id";
  if (p.item_id) {
    const r = await env.DB.prepare(`SELECT ${cols} FROM items WHERE id=? AND user_id=? AND kind<>'draft'`).bind(p.item_id, userId).first<ItemRow>();
    if (r) return r;
  }
  if (p.source_mid) return await env.DB.prepare(`SELECT ${cols} FROM items WHERE user_id=? AND message_id=? AND kind='action' LIMIT 1`).bind(userId, p.source_mid).first<ItemRow>();
  return null;
}

/**
 * Work through the events the app sent that are still waiting (oldest first). `only` limits the pass to one kind of
 * event (intake processes `draft_reply` right away this way) and skips learning. One bad event never stops the
 * others: a failure is recorded on the event (attempts, last_error) and in run_events, and retried next run.
 * Stops when the calls left can't cover the next event, or after `maxDrafts` draft requests were worked on (a request
 * replaced by a newer one doesn't count); the rest wait for the next run. Afterwards, if enough corrections
 * have piled up, learning runs (one Claude call) and produces a `learned` proposal for the app.
 */
export async function processEvents(env: Env, userId: string, calls: Budget, fetchFn?: typeof fetch, runId = "events", only?: string,
    maxDrafts = Infinity): Promise<{ processed: number; failed: number; learned: boolean }> {
  // `done` events already blocked on an inbox that is still disabled are left out entirely (they need no work until it is
  // reconnected; /v2/status still counts them), so however many there are they never crowd out other events.
  const { results } = await env.DB.prepare(`SELECT uuid, kind, payload, attempts, last_error FROM app_events e WHERE user_id=? AND processed=0
      AND (?2 IS NULL OR kind=?2) AND NOT (kind='done' AND COALESCE(last_error,'') LIKE 'inbox not connected%' AND EXISTS (
        SELECT 1 FROM items i JOIN sources s ON s.id=i.source_id AND s.user_id=i.user_id
        WHERE i.user_id=e.user_id AND s.enabled=0 AND i.kind<>'draft'
          AND (i.id=(CASE WHEN json_valid(e.payload) THEN json_extract(e.payload,'$.item_id') END)
            OR (i.kind='action' AND i.message_id=(CASE WHEN json_valid(e.payload) THEN json_extract(e.payload,'$.source_mid') END)))))
      ORDER BY (last_error LIKE 'inbox not connected%') ASC, attempts ASC, received ASC, rowid ASC LIMIT 200`).bind(userId, only ?? null).all<AppEvent>();
  let processed = 0, failed = 0, drafted = 0;
  const sources = new Map<string, { row: SourceRow; gmail: GmailSource } | null>();
  const gmailFor = async (id: string) => {
    if (!sources.has(id)) {
      const row = await env.DB.prepare("SELECT * FROM sources WHERE id=? AND user_id=? AND kind='gmail' AND enabled=1").bind(id, userId).first<SourceRow>();
      sources.set(id, row ? { row, gmail: gmailSource(env, row, calls.wrap(fetchFn)) } : null);
    }
    return sources.get(id) ?? null;
  };
  const finish = (uuid: string) => env.DB.prepare("UPDATE app_events SET processed=1, last_error=NULL WHERE uuid=?").bind(uuid);
  const reject = async (uuid: string, why: string) => {
    await env.DB.prepare("UPDATE app_events SET processed=2, last_error=? WHERE uuid=?").bind(why, uuid).run();
    await trace(env, userId, runId, uuid, "event rejected", why);
  };

  for (const e of results) {
    let p: Record<string, string>;
    try { p = JSON.parse(e.payload); if (!p || typeof p !== "object") throw new Error("not an object"); }
    catch { await reject(e.uuid, "payload unreadable"); continue; }
    let item: ItemRow | null = null;
    try {
      if (e.kind === "settings") { await finish(e.uuid).run(); processed++; continue; } // settings arrive via PUT /v2/settings

      // Draft reply (only ever from the Draft reply button): every request ends with a `draft` result for the app.
      if (e.kind === "draft_reply") {
        const r = readDraftRequest(p);
        if (!r.ok) {
          if (r.answer) await answerUnreadable(env, userId, r.answer);
          await reject(e.uuid, "draft request unreadable");
          continue;
        }
        // A request replaced by a newer one costs no calls, so it never waits for the budget (draftReplyEvent re-checks under the lock).
        const old = await superseded(env, userId, e.uuid, r.req.source_mid);
        if (!old && drafted >= maxDrafts) break; // this pass's share is done; the rest wait for the next pass (not worth a trace)
        if (!old && calls.remaining < DRAFT_CALLS) { await trace(env, userId, runId, e.uuid, "event waits for next run", "out of calls"); break; }
        if (!old) drafted++;
        const done = await draftReplyEvent({ env, userId, calls, fetchFn, gmailFor }, r.req, { runId, uuid: e.uuid, attempts: e.attempts });
        if (done === "busy") {
          if (!old) drafted--; // another pass is writing it: doesn't use up this pass's share
          await trace(env, userId, runId, e.uuid, "event waits for next run", "a draft for this email is being written");
          continue;
        }
        if (done === "done" || done === "superseded") processed++; // marked processed in the same batch as its result
        continue;
      }

      const verdict = e.kind === "changed" ? "changed" : (p.verdict ?? "");
      if (e.kind === "deleted" && !verdict) { await finish(e.uuid).run(); processed++; continue; } // plain delete: nothing to learn
      if (e.kind === "deleted" && verdict === "duplicate") {
        // The same task arrived twice: a matching problem, not a sorting one, so it is logged (to find the gap) and never
        // becomes a learning example (that would teach Claude the email wasn't an action).
        item = await findItem(env, userId, p);
        await finish(e.uuid).run(); processed++;
        await trace(env, userId, runId, e.uuid, "duplicate task reported", `source ${String(p.source_mid ?? p.item_id ?? "unknown").slice(0, 200)}`, item);
        continue;
      }
      if (e.kind === "correction" && !verdict) {
        await reject(e.uuid, "correction without a verdict");
        continue;
      }
      if (e.kind !== "done" && e.kind !== "changed" && !["not_action", "wrong_details"].includes(verdict)) {
        await reject(e.uuid, `unknown verdict "${String(verdict).slice(0, 40)}"`);
        continue;
      }
      if (e.kind !== "done" && !p.source_mid) { // recap/summary cards have no source email: nothing to learn from
        await finish(e.uuid).run(); processed++;
        await trace(env, userId, runId, e.uuid, "no source email \u2014 not used for learning");
        continue;
      }
      item = await findItem(env, userId, p);
      const gid = gmailIdFromLink(item?.link);
      const src = item?.source_id ? await gmailFor(item.source_id) : null;
      const outOfCalls = async (n: number) => {
        if (!src || calls.remaining >= n + (src.gmail.hasToken ? 0 : 1)) return false;
        await trace(env, userId, runId, e.uuid, "event waits for next run", "out of calls", item);
        return true;
      };

      if (e.kind === "done") {
        const s = await env.DB.prepare("SELECT mark_read_on_done FROM settings WHERE user_id=?").bind(userId).first<{ mark_read_on_done: number }>();
        if ((s?.mark_read_on_done ?? 1) && gid && item?.source_id && !src) {
          const row = await env.DB.prepare("SELECT address FROM sources WHERE id=? AND user_id=?").bind(item.source_id, userId).first<{ address: string }>();
          const msg = `inbox not connected (${row?.address ?? ""}) \u2014 email not marked read`;
          if (!row) { // inbox removed entirely: nothing to reconnect (status reports these for 7 days)
            await reject(e.uuid, "inbox removed \u2014 email not marked read");
          } else if (e.last_error !== msg) { // blocked: stays waiting (processed=0), logged once, retried when the inbox is enabled again
            await env.DB.prepare("UPDATE app_events SET last_error=? WHERE uuid=?").bind(msg, e.uuid).run();
            await trace(env, userId, runId, e.uuid, "done: waiting for inbox to be reconnected", msg, item);
          }
          continue;
        }
        if (!(s?.mark_read_on_done ?? 1) || !gid || !src) {
          await finish(e.uuid).run(); processed++;
          await trace(env, userId, runId, e.uuid, "done: nothing to mark read",
            !gid ? (item?.link?.startsWith("https://outlook.office.com/") ? "Outlook email: FloatBoard never changes anything in Outlook"
              : "no Gmail message for this task") : !src ? "inbox not connected" : "mark-read is off", item);
          continue;
        }
        if (await outOfCalls(DONE_CALLS)) break;
        // Never undo a deliberate change made elsewhere: only mark read if the message is unchanged since we read it.
        const outcome = await src.gmail.markReadIfUnchanged(gid, item?.history_id ?? null, (n) => calls.remaining >= n);
        if (outcome === "wait") { await trace(env, userId, runId, e.uuid, "event waits for next run", "out of calls", item); break; }
        await finish(e.uuid).run(); processed++;
        await trace(env, userId, runId, e.uuid, {
          gone: "done: email no longer exists",
          already_read: "done: already read",
          marked: "marked read",
          marked_unread_again: "left unread \u2014 marked unread again on another device",
          unconfirmed: "left unread \u2014 couldn't confirm it wasn't marked unread again",
        }[outcome], undefined, item);
        continue;
      }

      // changed / correction / deleted with a verdict: a learning example with an excerpt of the original email
      if (await env.DB.prepare("SELECT 1 FROM feedback WHERE event_uuid=?").bind(e.uuid).first()) {
        await finish(e.uuid).run(); processed++; continue; // already stored: never read the email twice
      }
      let excerpt = "", note = "";
      if (gid && src && await outOfCalls(READ_CALLS)) break;
      if (gid && src) {
        try { excerpt = (await src.gmail.readText(gid)).text.trim().slice(0, EXCERPT_CHARS); }
        catch (err) { note = `original email not readable (${(err as Error).message}); used the saved snippet`; }
      } else note = item ? "no Gmail message for this task; used the saved snippet" : "task not found; no excerpt";
      if (!excerpt && item) excerpt = [item.snippet, item.why ? `Why it was a task: ${item.why}` : ""].filter(Boolean).join("\n").slice(0, EXCERPT_CHARS);
      await env.DB.batch([
        env.DB.prepare(`INSERT OR IGNORE INTO feedback(user_id,item_id,verdict,created,subject,sender,detail,excerpt,event_uuid) VALUES(?,?,?,?,?,?,?,?,?)`)
          .bind(userId, item?.id ?? p.item_id ?? "", verdict, nowISO(), item?.subject ?? null, item?.sender ?? null, p.detail || null, excerpt || null, e.uuid),
        finish(e.uuid),
      ]);
      processed++;
      await trace(env, userId, runId, e.uuid, note ? "correction stored (fallback)" : "correction stored", note || undefined, item);
    } catch (err) {
      failed++;
      const msg = (err as Error).message.slice(0, 300);
      const n = e.attempts + 1;
      await env.DB.prepare("UPDATE app_events SET attempts=attempts+1, last_error=? WHERE uuid=?").bind(msg, e.uuid).run();
      await trace(env, userId, runId, e.uuid, "event failed; will retry", `${msg} (attempt ${n}${n >= MAX_ATTEMPTS_SHOWN ? ", shown in needs attention" : ""})`, item);
    }
  }

  const learned = only ? false : await maybeConsolidateForUser(env, userId, fetchFn, calls);
  if (learned) await trace(env, userId, runId, "learning", "learned from your corrections");
  return { processed, failed, learned };
}
