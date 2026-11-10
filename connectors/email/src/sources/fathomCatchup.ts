import { type Env, nowISO } from "../env";
import { logEvent } from "../runlog";
import { decrypt } from "../crypto";
import { processRecap, recapKnown } from "../recap";
import { Budget, BudgetExhausted } from "../budget";
import { fathomToMessage, recapKeys } from "./fathom";
import { log } from "../run";

/**
 * Second layer behind the Fathom webhook: every hour, ask Fathom's API for meetings created since the last check and
 * record any the webhook didn't deliver. Webhook and catch-up share the meeting keys (recapKeys), so a meeting that
 * arrives both ways is stored once. Never throws: problems go to the Fathom source's last_error (shown in the app's
 * needs-attention list) and run_events.
 */
const API = "https://api.fathom.ai/external/v1/meetings";
const FIRST_LOOKBACK_MS = 2 * 86400e3; // first check after the key is saved: the last 2 days
const OVERLAP_MS = 2 * 3600e3;        // re-ask a little behind the cursor: Fathom can finish a meeting late
const STILL_PROCESSING_MS = 6 * 3600e3; // a meeting with no notes yet is waited for up to this long, then skipped
const MAX_PAGES = 3;

let fathomFetch: typeof fetch = (i, init) => fetch(i, init);
export function setFathomFetch(f: typeof fetch) { fathomFetch = f; }

/** One call to Fathom with the key: true when Fathom accepts it (used to check a key before saving it). */
export async function fathomKeyWorks(apiKey: string): Promise<boolean> {
  const r = await fathomFetch(`${API}?created_after=${encodeURIComponent(new Date().toISOString())}`, { headers: { "X-Api-Key": apiKey } });
  return r.ok;
}

export async function catchUpFathom(env: Env, userId: string, calls: Budget, fetchFn: typeof fetch = fathomFetch): Promise<void> {
  const src = await env.DB.prepare("SELECT id, fathom_key_enc, cursor FROM sources WHERE user_id=? AND kind='fathom' AND enabled=1")
    .bind(userId).first<{ id: string; fathom_key_enc: string | null; cursor: string | null }>();
  if (!src?.fathom_key_enc) return;
  const fail = async (msg: string) => {
    await env.DB.batch([
      env.DB.prepare("UPDATE sources SET last_error=? WHERE id=?").bind(msg, src.id),
      logEvent(env, { run_id: "fathom", user_id: userId, decision: "Fathom catch-up failed", detail: msg, trace: "catch-up" }),
    ]);
    log("fathom_catchup_failed", { userId, error: msg });
  };
  try {
    const key = await decrypt(env, src.fathom_key_enc);
    const since = src.cursor ? Date.parse(src.cursor) - OVERLAP_MS : Date.now() - FIRST_LOOKBACK_MS;
    const meetings: any[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < MAX_PAGES; page++) {
      const q = new URLSearchParams({ created_after: new Date(since).toISOString(), include_summary: "true", include_action_items: "true" });
      if (cursor) q.set("cursor", cursor);
      calls.take(1);
      const r = await fetchFn(`${API}?${q}`, { headers: { "X-Api-Key": key } });
      if (r.status === 401 || r.status === 403) return await fail("Fathom API key was rejected. Replace it in the setup page.");
      if (!r.ok) return await fail(`Couldn't check Fathom for missed meetings (HTTP ${r.status}); will retry next hour.`);
      const body = await r.json<{ items?: any[]; next_cursor?: string | null }>();
      meetings.push(...(body.items ?? []));
      cursor = body.next_cursor ?? null;
      if (!cursor) break;
    }
    meetings.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
    let newCursor = src.cursor, added = 0, waiting = false;
    for (const m of meetings) {
      const created = Date.parse(m.created_at);
      const unfinished = !m.default_summary && !(m.action_items?.length);
      if (unfinished && Date.now() - created < STILL_PROCESSING_MS) { waiting = true; break; } // ask again next hour
      if (unfinished) { // Fathom never made notes (e.g. too short): nothing to record
        if (!isNaN(created)) newCursor = new Date(created).toISOString();
        continue;
      }
      const msg = fathomToMessage(m, src.id);
      const known = await recapKnown(env, userId, recapKeys(msg));
      if (!known) {
        calls.take(1); // the summary call to Claude
        const out = await processRecap(env, userId, msg, undefined, { rawOnUnusable: true });
        if (out.status === "stored") added++;
      }
      if (!isNaN(created)) newCursor = new Date(created).toISOString();
    }
    // With nothing left to wait for, move the bookmark up to the processing window so the look-back doesn't keep growing.
    let cursorOut = newCursor ?? new Date(since).toISOString();
    if (!waiting) cursorOut = new Date(Math.max(Date.parse(cursorOut), Date.now() - STILL_PROCESSING_MS)).toISOString();
    await env.DB.prepare("UPDATE sources SET cursor=?, last_run=?, last_error=NULL WHERE id=?").bind(cursorOut, nowISO(), src.id).run();
    if (added) {
      await logEvent(env, { run_id: "fathom", user_id: userId, decision: "Fathom catch-up added meetings", trace: "catch-up",
        detail: `${added} meeting${added === 1 ? "" : "s"} the webhook hadn't delivered` }).run();
    }
  } catch (e) {
    if (e instanceof BudgetExhausted) return; // the rest waits for next hour; the cursor wasn't moved past it
    await fail(`Couldn't check Fathom for missed meetings: ${(e as Error)?.message ?? e}`.slice(0, 300));
  }
}
