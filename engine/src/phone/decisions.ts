/**
 * More › Decisions on the phone (features §10; docs/superpowers/specs/2026-11-17-decisions-design.md §8): a read-only copy
 * of the Mac's decisions plus two actions, answer a review and "Not a decision". The Mac stays the record.
 *
 * - `PUT /v2/decisions` (Mac, user key): the copy (at most 300), stored encrypted, replacing the previous one.
 * - `GET /app/api/decisions` (phone session): the copy, when it was sent, and how many phone actions wait for the Mac.
 * - `POST /app/api/decisions/action` (phone session, same origin): `{ account, actions: [{ id, decision: "D-n", action: "review" |
 *   "not_decision", happened?, sound?, made_at? }] }`, at most 50. `account` is the account the queue was made under; another account's queue is refused (409). The phone's own
 *   id makes a repeat harmless. The review's
 *   answers are stored encrypted.
 * - `GET /v2/decision-actions` and `POST /v2/decision-actions/ack` (Mac): what waits, oldest first; acked ones are kept a
 *   week, then deleted.
 */
import { type Env, json, nowISO } from "../env";
import { decrypt, encrypt } from "../lib/crypto";
import { readCappedJSON } from "../lib/http";
import { route } from "../lib/router";
import { accountMarker, appJSON, requireAppSession, sameOrigin } from "./auth";

export const MAX_COPY = 300;
const MAX_ACTIONS = 50;
const MAX_ANSWER = 4000;
const MAX_WAITING = 200;
const KEEP_DAYS = 7;
const DECISION_ID = /^D-\d{1,12}$/;
const ACTION_ID = /^[A-Za-z0-9-]{8,64}$/;
const ACTIONS = ["review", "not_decision"] as const;
const isIso = (v: unknown): v is string => typeof v === "string" && v.length <= 40 && !Number.isNaN(Date.parse(v));
const text = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : "");
const list = (v: unknown, n: number, max: number) => (Array.isArray(v) ? v.filter((x) => typeof x === "string").slice(0, n).map((x: string) => x.slice(0, max)) : []);

type PhoneDecision = Record<string, unknown> & { id: string };

/** The copy's entries, checked and cut to size; throws on a malformed list. */
export function parseCopy(v: unknown): PhoneDecision[] {
  if (!Array.isArray(v) || v.length > MAX_COPY) throw new Error(`decisions must be a list of at most ${MAX_COPY}`);
  return v.map((d: any, i: number) => {
    if (!d || typeof d !== "object" || typeof d.id !== "string" || !DECISION_ID.test(d.id)) throw new Error(`decisions[${i}].id must be D-n`);
    return {
      id: d.id, text: text(d.text, 300), quote: text(d.quote, 2000), source: text(d.source, 40), recorded: text(d.recorded, 10),
      decided: text(d.decided, 10), type: text(d.type, 20), status: text(d.status, 20), found_by: text(d.found_by, 10), why: text(d.why, 500),
      expected: text(d.expected, 500), expected_later: d.expected_later === true, confidence: text(d.confidence, 10),
      confidence_later: d.confidence_later === true, tags: list(d.tags, 20, 60), people: list(d.people, 20, 100),
      review_due: typeof d.review_due === "string" ? d.review_due.slice(0, 10) : null, review: text(d.review, 12), this_week: d.this_week === true,
    };
  });
}

// ---------------------------------------------------------------- Mac side

route("PUT", "/v2/decisions", async (req, env, user) => {
  const rb = await readCappedJSON(req, 1_500_000);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  let decisions: PhoneDecision[];
  try { decisions = parseCopy(rb.body?.decisions); } catch (e) { return json({ error: (e as Error).message }, 400); }
  const now = nowISO();
  await env.DB.prepare(`INSERT INTO decision_copies(user_id,data_enc,updated) VALUES(?,?,?)
      ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc, updated=excluded.updated`)
    .bind(user.id, await encrypt(env, JSON.stringify(decisions)), now).run();
  return json({ ok: true, count: decisions.length });
});

route("GET", "/v2/decision-actions", async (_req, env, user) => {
  const { results } = await env.DB.prepare(`SELECT client_id, decision, action, payload_enc, made_at FROM decision_actions
      WHERE user_id=? AND taken=0 ORDER BY made_at, rowid LIMIT ${MAX_WAITING}`).bind(user.id)
    .all<{ client_id: string; decision: string; action: string; payload_enc: string | null; made_at: string }>();
  const actions = [];
  for (const r of results) {
    const p = r.payload_enc ? JSON.parse(await decrypt(env, r.payload_enc)) : {};
    actions.push({ id: r.client_id, decision: r.decision, action: r.action, made_at: r.made_at,
      ...(r.action === "review" ? { happened: String(p.happened ?? ""), sound: String(p.sound ?? "") } : {}) });
  }
  return json({ server_time: nowISO(), actions });
});

route("POST", "/v2/decision-actions/ack", async (req, env, user) => {
  const rb = await readCappedJSON(req, 100_000);
  if (!rb.ok) return json({ error: "Invalid JSON" }, 400);
  const ids = rb.body?.ids;
  if (!Array.isArray(ids) || ids.length > MAX_WAITING || !ids.every((i) => typeof i === "string" && ACTION_ID.test(i))) {
    return json({ error: `ids must be a list of up to ${MAX_WAITING} action ids` }, 400);
  }
  const cutoff = new Date(Date.now() - KEEP_DAYS * 86400_000).toISOString();
  await env.DB.batch([
    ...ids.map((id: string) => env.DB.prepare("UPDATE decision_actions SET taken=1 WHERE user_id=? AND client_id=?").bind(user.id, id)),
    env.DB.prepare("DELETE FROM decision_actions WHERE user_id=? AND taken=1 AND created < ?").bind(user.id, cutoff),
  ]);
  return json({ ok: true });
});

// ---------------------------------------------------------------- phone side

async function waiting(env: Env, userId: string): Promise<number> {
  return (await env.DB.prepare("SELECT COUNT(*) n FROM decision_actions WHERE user_id=? AND taken=0").bind(userId).first<{ n: number }>())?.n ?? 0;
}

type Parsed = { clientId: string; decision: string; action: (typeof ACTIONS)[number]; happened: string; sound: string; madeAt: string | null };

function parseAction(a: any): Parsed | string {
  if (!a || typeof a !== "object" || typeof a.id !== "string" || !ACTION_ID.test(a.id)) return "id must be 8 to 64 letters, digits or dashes";
  if (typeof a.decision !== "string" || !DECISION_ID.test(a.decision)) return "decision must be D-n";
  if (!(ACTIONS as readonly unknown[]).includes(a.action)) return `action must be ${ACTIONS.join(" or ")}`;
  if (a.made_at !== undefined && a.made_at !== null && !isIso(a.made_at)) return "made_at must be an ISO date";
  const happened = text(a.happened, MAX_ANSWER), sound = text(a.sound, MAX_ANSWER);
  if (a.action === "review" && !(happened + sound).trim()) return "a review needs an answer";
  return { clientId: a.id, decision: a.decision, action: a.action, happened, sound, madeAt: a.made_at ?? null };
}

/** `GET /app/api/decisions` and `POST /app/api/decisions/action`; null for any other path. */
export async function handleDecisions(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path === "/app/api/decisions" && req.method === "GET") {
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const row = await env.DB.prepare("SELECT data_enc, updated FROM decision_copies WHERE user_id=?").bind(s.userId).first<{ data_enc: string; updated: string }>();
    // `account`: which account this session belongs to, so the phone caches and sends only under it.
    return appJSON({ account: await accountMarker(s.userId), decisions: row ? JSON.parse(await decrypt(env, row.data_enc)) : [],
      updated: row?.updated ?? null, waiting: await waiting(env, s.userId) }, 200, s.setCookie);
  }
  if (path === "/app/api/decisions/action" && req.method === "POST") {
    if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const rb = await readCappedJSON(req, 300_000);
    if (!rb.ok) return appJSON({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400, s.setCookie);
    // The account the phone's queue was made under, checked here at the moment of storing: a page holding a stale
    // confirmation (another account signed in since) is refused and keeps its queue.
    const mine = await accountMarker(s.userId);
    if (typeof rb.body?.account !== "string") return appJSON({ error: "account is required" }, 400, s.setCookie);
    if (rb.body.account !== mine) return appJSON({ error: "These changes belong to another account.", account: mine }, 409, s.setCookie);
    const raw = rb.body?.actions;
    if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_ACTIONS) return appJSON({ error: `actions must be a list of 1 to ${MAX_ACTIONS}` }, 400, s.setCookie);
    const parsed = raw.map(parseAction);
    const bad = parsed.find((p) => typeof p === "string");
    if (bad) return appJSON({ error: bad }, 400, s.setCookie);
    const list = parsed as Parsed[];
    if ((await waiting(env, s.userId)) + list.length > MAX_WAITING) {
      return appJSON({ error: "Too many changes are waiting for your Mac. Open FloatBoard on the Mac and try again." }, 429, s.setCookie);
    }
    const now = nowISO();
    const stmts: D1PreparedStatement[] = [];
    for (const a of list) {
      const payload = a.action === "review" ? await encrypt(env, JSON.stringify({ happened: a.happened, sound: a.sound })) : null;
      stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO decision_actions(id,user_id,client_id,device_id,decision,action,payload_enc,made_at,created)
          VALUES(?,?,?,?,?,?,?,?,?)`).bind(crypto.randomUUID(), s.userId, a.clientId, s.deviceId, a.decision, a.action, payload, a.madeAt ?? now, now));
    }
    await env.DB.batch(stmts);
    // Stored under the session's own user only: a phone can never queue an action for another account.
    return appJSON({ account: mine, accepted: list.map((a) => a.clientId), waiting: await waiting(env, s.userId) },
      200, s.setCookie);
  }
  return null;
}
