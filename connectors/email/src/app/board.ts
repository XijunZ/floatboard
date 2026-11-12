/**
 * Board copy for the phone and the changes the phone queues for the Mac.
 *
 * - The Mac pushes its open tasks (plus tasks done today) with `PUT /v2/board` (user key); the engine stores them
 *   encrypted, replacing the previous copy.
 * - The phone reads `GET /app/api/board` (session cookie) and acts with `POST /app/api/action`. An action is queued in
 *   `phone_actions` and, for a status change, also applied to the stored copy so the phone shows it at once. A new task
 *   is not stored in the copy: it comes back as a pending card (negative id) until the Mac applies and acks it.
 * - The Mac polls `GET /v2/phone-actions`, applies them, and acks with `POST /v2/phone-actions/ack`.
 */
import { type Env, json, nowISO } from "../env";
import { decrypt, encrypt } from "../crypto";
import { readJSON } from "../http";
import { route } from "../router";
import { appJSON, requireAppSession, sameOrigin } from "./auth";

export const MAX_CARDS = 500;
export const MAX_UNTAKEN_ACTIONS = 200;
const MAX_TITLE = 200;
const MAX_LINK = 2000;
const MAX_BOARD_BYTES = 1_500_000;
const TAKEN_KEEP_DAYS = 7;
const STATUSES = ["todo", "doing", "watch", "done"] as const;
const DEFAULT_COLOR = "#8e8e93";

export type Status = (typeof STATUSES)[number];
export type Card = {
  id: number; title: string; group: string; color: string; importance: 0 | 1 | 2; due: string | null; has_time: boolean;
  status: Status; link: string | null; done_at: string | null; pending?: true;
};
export type PhoneAction = { id: string; card_id: number | null; action: Status | "add"; title: string | null; group: string | null; created: string };
type ActionRow = { id: string; rid: number; card_id: number | null; action: string; title: string | null; group_name: string | null; created: string };

const isoOrNull = (v: unknown, name: string): string | null => {
  if (v === null) return null;
  if (typeof v === "string" && v.length <= 40 && !Number.isNaN(Date.parse(v))) return v;
  throw new Error(`${name} must be an ISO date or null`);
};

function httpLink(v: unknown): string | null {
  if (v === null) return null;
  if (typeof v !== "string" || v.length > MAX_LINK) throw new Error("link must be a web address or null");
  let u: URL;
  try { u = new URL(v); } catch { throw new Error("link must be a web address or null"); }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("link must be http or https");
  return v;
}

/** Strictly validate a pushed board; throws Error(message) on anything off. */
export function parseCards(body: any): Card[] {
  if (!body || !Array.isArray(body.cards)) throw new Error("cards must be a list");
  if (body.cards.length > MAX_CARDS) throw new Error(`at most ${MAX_CARDS} cards`);
  const seen = new Set<number>();
  return body.cards.map((c: any, i: number): Card => {
    const at = `cards[${i}]`;
    if (!c || typeof c !== "object" || Array.isArray(c)) throw new Error(`${at} must be an object`);
    if (!Number.isSafeInteger(c.id)) throw new Error(`${at}.id must be an integer`);
    if (seen.has(c.id)) throw new Error(`${at}.id repeats`);
    seen.add(c.id);
    if (typeof c.title !== "string" || c.title.length > MAX_TITLE) throw new Error(`${at}.title must be text up to ${MAX_TITLE} characters`);
    if (typeof c.group !== "string" || c.group.length > MAX_TITLE) throw new Error(`${at}.group must be text up to ${MAX_TITLE} characters`);
    if (typeof c.color !== "string" || !/^#[0-9a-fA-F]{6}$/.test(c.color)) throw new Error(`${at}.color must be a hex colour like #aabbcc`);
    if (c.importance !== 0 && c.importance !== 1 && c.importance !== 2) throw new Error(`${at}.importance must be 0, 1 or 2`);
    if (typeof c.has_time !== "boolean") throw new Error(`${at}.has_time must be true or false`);
    if (!STATUSES.includes(c.status)) throw new Error(`${at}.status must be todo, doing, watch or done`);
    try {
      return { id: c.id, title: c.title, group: c.group, color: c.color, importance: c.importance, due: isoOrNull(c.due, "due"),
        has_time: c.has_time, status: c.status, link: httpLink(c.link), done_at: isoOrNull(c.done_at, "done_at") };
    } catch (e) { throw new Error(`${at}.${(e as Error).message}`); }
  });
}

async function loadSnapshot(env: Env, userId: string): Promise<{ cards: Card[]; updated: string } | null> {
  const row = await env.DB.prepare("SELECT data_enc, updated FROM board_snapshots WHERE user_id=?").bind(userId).first<{ data_enc: string; updated: string }>();
  if (!row) return null;
  return { cards: JSON.parse(await decrypt(env, row.data_enc)).cards as Card[], updated: row.updated };
}

async function untaken(env: Env, userId: string): Promise<ActionRow[]> {
  return (await env.DB.prepare("SELECT id, rowid AS rid, card_id, action, title, group_name, created FROM phone_actions WHERE user_id=? AND taken=0 ORDER BY created, rowid")
    .bind(userId).all<ActionRow>()).results;
}

/** The board as the phone sees it: the stored copy with every untaken action applied; new tasks are pending cards with negative ids. */
export function overlay(cards: Card[], actions: ActionRow[]): Card[] {
  const out = cards.map((c) => ({ ...c }));
  for (const a of actions) {
    if (a.action === "add") {
      const group = a.group_name || "Inbox";
      out.push({ id: -a.rid, title: a.title ?? "", group, color: out.find((c) => c.group === group)?.color ?? DEFAULT_COLOR, importance: 0,
        due: null, has_time: false, status: "todo", link: null, done_at: null, pending: true });
    } else {
      const c = out.find((x) => x.id === a.card_id);
      if (c) applyMove(c, a.action as Status, a.created);
    }
  }
  return out;
}

function applyMove(c: Card, status: Status, at: string) {
  c.status = status;
  c.done_at = status === "done" ? (c.done_at ?? at) : null;
}

async function boardResponse(env: Env, userId: string, setCookie?: string): Promise<Response> {
  const [snap, actions] = await Promise.all([loadSnapshot(env, userId), untaken(env, userId)]);
  return appJSON({ updated: snap?.updated ?? null, cards: overlay(snap?.cards ?? [], actions), pending: actions.length }, 200, setCookie);
}

// ---------------------------------------------------------------- Mac side (user key)

route("PUT", "/v2/board", async (req, env, user) => {
  const text = await req.text();
  if (text.length > MAX_BOARD_BYTES) return json({ error: "too large" }, 413);
  const rb = await readJSON(new Request(req.url, { method: "POST", body: text }));
  if (!rb.ok) return rb.res;
  let cards: Card[];
  try { cards = parseCards(rb.body); } catch (e) { return json({ error: (e as Error).message }, 400); }
  await env.DB.prepare("INSERT INTO board_snapshots(user_id,data_enc,updated) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc, updated=excluded.updated")
    .bind(user.id, await encrypt(env, JSON.stringify({ cards })), nowISO()).run();
  return json({ ok: true, count: cards.length });
});

route("GET", "/v2/phone-actions", async (_req, env, user) => {
  const actions: PhoneAction[] = (await untaken(env, user.id)).map((a) => ({ id: a.id, card_id: a.card_id, action: a.action as PhoneAction["action"],
    title: a.title, group: a.group_name, created: a.created }));
  return json({ actions });
});

route("POST", "/v2/phone-actions/ack", async (req, env, user) => {
  const rb = await readJSON(req);
  if (!rb.ok) return rb.res;
  const ids = rb.body.ids;
  if (!Array.isArray(ids) || ids.length > MAX_UNTAKEN_ACTIONS || ids.some((i: unknown) => typeof i !== "string" || i.length === 0 || i.length > 100)) {
    return json({ error: `ids must be a list of up to ${MAX_UNTAKEN_ACTIONS} ids` }, 400);
  }
  if (ids.length) await env.DB.batch(ids.map((id: string) => env.DB.prepare("UPDATE phone_actions SET taken=1 WHERE id=? AND user_id=?").bind(id, user.id)));
  return json({ ok: true });
});

/** Hourly: acked phone actions older than 7 days are deleted. */
export async function purgePhoneActions(env: Env): Promise<void> {
  const cutoff = new Date(Date.now() - TAKEN_KEEP_DAYS * 86400_000).toISOString();
  await env.DB.prepare("DELETE FROM phone_actions WHERE taken=1 AND created < ?").bind(cutoff).run();
}

// ---------------------------------------------------------------- phone side (session cookie)

/** `GET /app/api/board` and `POST /app/api/action`; null for any other path. */
export async function handleBoard(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path === "/app/api/board" && req.method === "GET") {
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    return boardResponse(env, s.userId, s.setCookie);
  }
  if (path === "/app/api/action" && req.method === "POST") {
    if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const text = await req.text();
    if (text.length > 5_000) return appJSON({ error: "too large" }, 413, s.setCookie);
    const rb = await readJSON(new Request(req.url, { method: "POST", body: text }));
    if (!rb.ok) return appJSON({ error: "Invalid JSON" }, 400, s.setCookie);
    return doAction(env, s.userId, rb.body, s.setCookie);
  }
  return null;
}

async function doAction(env: Env, userId: string, body: any, setCookie?: string): Promise<Response> {
  const bad = (error: string, status = 400) => appJSON({ error }, status, setCookie);
  const action = body.action;
  let cardId: number | null = null, title: string | null = null, group: string | null = null;
  if (action === "add") {
    if (typeof body.title !== "string") return bad("title is required");
    const t: string = body.title.trim();
    if (t.length < 1 || t.length > MAX_TITLE) return bad(`title must be 1 to ${MAX_TITLE} characters`);
    title = t;
    if (body.group !== undefined && body.group !== null) {
      if (typeof body.group !== "string" || body.group.length > MAX_TITLE) return bad(`group must be text up to ${MAX_TITLE} characters`);
      group = body.group.trim() || null;
    }
  } else if (STATUSES.includes(action)) {
    if (!Number.isSafeInteger(body.card_id)) return bad("card_id must be an integer");
    cardId = body.card_id;
  } else {
    return bad("action must be todo, doing, watch, done or add");
  }
  const snap = await loadSnapshot(env, userId);
  if (cardId !== null && !snap?.cards.some((c) => c.id === cardId)) return bad("That task isn't on your board.", 404);
  const n = (await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=? AND taken=0").bind(userId).first<{ n: number }>())!.n;
  if (n >= MAX_UNTAKEN_ACTIONS) return bad("Too many changes are waiting for your Mac. Open FloatBoard on the Mac and try again.", 429);
  const now = nowISO();
  const stmts = [env.DB.prepare("INSERT INTO phone_actions(id,user_id,card_id,action,title,group_name,created,taken) VALUES(?,?,?,?,?,?,?,0)")
    .bind(crypto.randomUUID(), userId, cardId, action, title, group, now)];
  if (cardId !== null && snap) {
    const c = snap.cards.find((x) => x.id === cardId)!;
    applyMove(c, action, now);
    stmts.push(env.DB.prepare("UPDATE board_snapshots SET data_enc=? WHERE user_id=?").bind(await encrypt(env, JSON.stringify({ cards: snap.cards })), userId));
  }
  await env.DB.batch(stmts);
  return boardResponse(env, userId, setCookie);
}
