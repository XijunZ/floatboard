/**
 * Board copy for the phone, the changes the phone queues for the Mac, and the record of every change (sync v2).
 *
 * - The Mac pushes its open tasks (plus tasks done today) with `PUT /v2/board` (user key); the engine stores them
 *   encrypted, replacing the previous copy. Each card carries `status_at` (when its step last changed on the Mac) and the
 *   push carries `sent_at` (the Mac's clock), so the engine can correct the Mac's clock. The engine compares each push
 *   with the previous copy and logs the Mac's changes to `board_log` (step changes, cards that appeared, cards gone).
 * - The phone reads `GET /app/api/board` (session cookie) and sends its queued actions with `POST /app/api/action` (a
 *   batch, or the older single action). Each action has the phone's own id (a repeat is applied once) and `made_at`; the
 *   batch has `sent_at`, and the engine stores `made_at + (received_at - sent_at)`. Actions are queued in `phone_actions`
 *   and logged in `board_log`. The stored copy is never changed by the phone: it is always the Mac's own copy.
 * - Newest change wins: the board the phone sees is the stored copy with each phone move applied only when it was made
 *   at or after the card's `status_at`. An older move is superseded (marked taken, logged, reported to the phone that
 *   made it). A Mac push supersedes waiting moves older than the card's new `status_at` (or marks them taken when the
 *   Mac already shows that step). A new task is not stored in the copy: it comes back as a pending card (negative id)
 *   until the Mac applies and acks it.
 * - The Mac polls `GET /v2/phone-actions` (with corrected `made_at`), applies them unless its own step change for the card
 *   is newer, and acks with `POST /v2/phone-actions/ack` (`skipped` ones with a reason, logged).
 */
import { type Env, json, nowISO } from "../env";
import { decrypt, encrypt } from "../crypto";
import { readCappedJSON } from "../http";
import { route } from "../router";
import { accountMarker, appJSON, requireAppSession, sameOrigin } from "./auth";

export const MAX_CARDS = 500;
export const MAX_UNTAKEN_ACTIONS = 200;
export const MAX_BATCH = 100;
const MAX_TITLE = 200;
const MAX_LINK = 2000;
const MAX_REASON = 200;
const MAX_BOARD_BYTES = 1_500_000;
const MAX_ACTION_BYTES = 64_000;
const TAKEN_KEEP_DAYS = 7;
const LOG_KEEP_DAYS = 365;
const MAX_SKEW_MS = 7 * 86400_000;
const MAX_SUPERSEDED_LISTED = 200;
const ACTION_ID = /^[A-Za-z0-9-]{8,64}$/;
const STATUSES = ["todo", "doing", "watch", "done"] as const;
const DEFAULT_COLOR = "#8e8e93";

export type Status = (typeof STATUSES)[number];
export type Card = {
  id: number; title: string; group: string; color: string; importance: 0 | 1 | 2; due: string | null; has_time: boolean;
  status: Status; link: string | null; done_at: string | null; status_at?: string | null; pending?: true; action_id?: string | null;
};
export type PhoneAction = {
  id: string; client_id: string | null; card_id: number | null; action: Status | "add"; title: string | null; group: string | null;
  created: string; made_at: string;
};
type ActionRow = {
  id: string; rid: number; client_id: string | null; card_id: number | null; action: string; title: string | null; group_name: string | null;
  created: string; made_at: string; taken: number;
};

const iso = (ms: number) => new Date(ms).toISOString();
const isIso = (v: unknown): v is string => typeof v === "string" && v.length <= 40 && !Number.isNaN(Date.parse(v));

const isoOrNull = (v: unknown, name: string): string | null => {
  if (v === null) return null;
  if (isIso(v)) return v;
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

/** Strictly validate a pushed board; throws Error(message) on anything off. `status_at` is optional (as the Mac sent it). */
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
        has_time: c.has_time, status: c.status, link: httpLink(c.link), done_at: isoOrNull(c.done_at, "done_at"),
        status_at: c.status_at === undefined ? null : isoOrNull(c.status_at, "status_at") };
    } catch (e) { throw new Error(`${at}.${(e as Error).message}`); }
  });
}

/**
 * Clock skew of a sending device: `received - sent_at` in ms. 0 when `sent_at` is missing (times are taken as sent);
 * null when it is more than 7 days off (the device's times are ignored and the received time is used).
 */
export function skewOf(sentAt: string | null, receivedMs: number): number | null {
  if (sentAt === null) return 0;
  const s = receivedMs - Date.parse(sentAt);
  return Math.abs(s) > MAX_SKEW_MS ? null : s;
}

/** A device time moved onto the engine's clock, never later than when it arrived; null when it can't be used. */
export function corrected(at: string | null | undefined, skew: number | null, receivedMs: number): string | null {
  if (!at || skew === null) return null;
  return iso(Math.min(Date.parse(at) + skew, receivedMs));
}

async function loadSnapshot(env: Env, userId: string): Promise<{ cards: Card[]; updated: string } | null> {
  const row = await env.DB.prepare("SELECT data_enc, updated FROM board_snapshots WHERE user_id=?").bind(userId).first<{ data_enc: string; updated: string }>();
  if (!row) return null;
  return { cards: JSON.parse(await decrypt(env, row.data_enc)).cards as Card[], updated: row.updated };
}

const ACTION_COLS = "id, rowid AS rid, client_id, card_id, action, title, group_name, created, COALESCE(made_at, created) AS made_at, taken";

/** Actions the Mac has not acked yet (oldest first). */
async function untaken(env: Env, userId: string): Promise<ActionRow[]> {
  return (await env.DB.prepare(`SELECT ${ACTION_COLS} FROM phone_actions WHERE user_id=? AND taken=0 ORDER BY COALESCE(made_at, created), rowid`)
    .bind(userId).all<ActionRow>()).results;
}

/** What the phone's board is built from: waiting adds, and every move not superseded or skipped (acked ones too, until the Mac pushes a newer step). */
async function overlayActions(env: Env, userId: string): Promise<ActionRow[]> {
  return (await env.DB.prepare(`SELECT ${ACTION_COLS} FROM phone_actions WHERE user_id=? AND outcome IS NULL AND (taken=0 OR action<>'add')
      ORDER BY COALESCE(made_at, created), rowid`).bind(userId).all<ActionRow>()).results;
}

/** When the card's step last changed, on the engine's clock (older copies have no status_at: the push time). */
const statusAt = (c: Card, snapUpdated: string | null) => c.status_at ?? snapUpdated ?? "";

/**
 * The board as the phone sees it: the stored copy with each phone move applied when it was made at or after the card's
 * `status_at` (newest change wins), oldest first; new tasks waiting for the Mac are pending cards with negative ids.
 */
export function overlay(cards: Card[], actions: ActionRow[], snapUpdated: string | null = null): Card[] {
  const out = cards.map((c) => ({ ...c }));
  const base = new Map(cards.map((c) => [c.id, statusAt(c, snapUpdated)]));
  for (const a of actions) {
    if (a.action === "add") {
      if (a.taken) continue;
      const group = a.group_name || "Inbox";
      out.push({ id: -a.rid, title: a.title ?? "", group, color: out.find((c) => c.group === group)?.color ?? DEFAULT_COLOR, importance: 0,
        due: null, has_time: false, status: "todo", link: null, done_at: null, status_at: a.made_at, pending: true, action_id: a.client_id });
    } else {
      const c = out.find((x) => x.id === a.card_id);
      if (c && a.made_at >= base.get(c.id)!) applyMove(c, a.action as Status, a.made_at);
    }
  }
  return out;
}

function applyMove(c: Card, status: Status, at: string) {
  c.status = status;
  c.done_at = status === "done" ? (c.done_at ?? at) : null;
}

/** Ids (the phone's own) of this device's actions that were not applied: a newer change won, or the Mac skipped them. */
async function notApplied(env: Env, userId: string, deviceId: string): Promise<string[]> {
  return (await env.DB.prepare(`SELECT client_id FROM phone_actions WHERE user_id=? AND device_id=? AND outcome IS NOT NULL AND client_id IS NOT NULL
      ORDER BY rowid DESC LIMIT ${MAX_SUPERSEDED_LISTED}`).bind(userId, deviceId).all<{ client_id: string }>()).results.map((r) => r.client_id).reverse();
}

async function boardBody(env: Env, userId: string, deviceId: string) {
  const [snap, actions, waiting, superseded, account] = await Promise.all([loadSnapshot(env, userId), overlayActions(env, userId),
    env.DB.prepare("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=? AND taken=0").bind(userId).first<{ n: number }>(),
    notApplied(env, userId, deviceId), accountMarker(userId)]);
  return { updated: snap?.updated ?? null, server_time: nowISO(), account, cards: overlay(snap?.cards ?? [], actions, snap?.updated ?? null),
    pending: waiting?.n ?? 0, superseded };
}

const logStmt = (env: Env, r: { id: string; userId: string; device: string; cardId: number | null; kind: string; value: string | null; madeAt: string; receivedAt: string }) =>
  env.DB.prepare("INSERT OR IGNORE INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at) VALUES(?,?,?,?,?,?,?,?)")
    .bind(r.id, r.userId, r.device, r.cardId, r.kind, r.value, r.madeAt, r.receivedAt);

/** Mark a waiting action superseded and log it (the log row id is derived from the action, so it is written once). */
function supersedeStmts(env: Env, userId: string, a: { id: string; client_id: string | null; card_id: number | null }, device: string, at: string) {
  return [
    env.DB.prepare("UPDATE phone_actions SET taken=1, outcome='superseded' WHERE id=? AND user_id=?").bind(a.id, userId),
    logStmt(env, { id: `sup:${a.id}`, userId, device, cardId: a.card_id, kind: "superseded",
      value: JSON.stringify({ action: a.client_id ?? a.id, reason: "superseded" }), madeAt: at, receivedAt: at }),
  ];
}

// ---------------------------------------------------------------- Mac side (user key)

route("PUT", "/v2/board", async (req, env, user) => {
  const receivedMs = Date.now();
  const now = iso(receivedMs);
  const rb = await readCappedJSON(req, MAX_BOARD_BYTES);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  let cards: Card[];
  try { cards = parseCards(rb.body); } catch (e) { return json({ error: (e as Error).message }, 400); }
  const sentAt = rb.body.sent_at ?? null;
  if (sentAt !== null && !isIso(sentAt)) return json({ error: "sent_at must be an ISO date" }, 400);
  const skew = skewOf(sentAt, receivedMs);
  const prev = await loadSnapshot(env, user.id);
  const prevById = new Map((prev?.cards ?? []).map((c) => [c.id, c]));
  const stmts: D1PreparedStatement[] = [];
  const log = (cardId: number, kind: string, value: string | null, madeAt: string) =>
    stmts.push(logStmt(env, { id: crypto.randomUUID(), userId: user.id, device: "mac", cardId, kind, value, madeAt, receivedAt: now }));
  for (const c of cards) {
    const p = prevById.get(c.id);
    // No usable status_at: an unchanged step keeps its time; a changed or new one changed at this push.
    c.status_at = corrected(c.status_at, skew, receivedMs) ?? (p && p.status === c.status ? statusAt(p, prev!.updated) : now);
    if (!prev) continue; // the first copy is the baseline, not a change
    if (!p) log(c.id, "add", await encrypt(env, c.title), c.status_at);
    else if (p.status !== c.status) log(c.id, "status", c.status, c.status_at);
  }
  const ids = new Set(cards.map((c) => c.id));
  for (const p of prev?.cards ?? []) if (!ids.has(p.id)) log(p.id, "gone", null, now);
  // Waiting phone moves older than the Mac's step change: already applied if the Mac shows that step, else superseded.
  const byId = new Map(cards.map((c) => [c.id, c]));
  const older = new Map<number, ActionRow[]>();
  for (const a of await untaken(env, user.id)) {
    const c = a.card_id === null ? undefined : byId.get(a.card_id);
    if (a.action === "add" || !c || a.made_at >= c.status_at!) continue;
    older.set(c.id, [...(older.get(c.id) ?? []), a]);
  }
  for (const [cardId, list] of older) {
    if (list[list.length - 1].action === byId.get(cardId)!.status) {
      for (const a of list) stmts.push(env.DB.prepare("UPDATE phone_actions SET taken=1 WHERE id=? AND user_id=?").bind(a.id, user.id));
    } else {
      for (const a of list) stmts.push(...supersedeStmts(env, user.id, a, "mac", now));
    }
  }
  stmts.unshift(env.DB.prepare("INSERT INTO board_snapshots(user_id,data_enc,updated) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc, updated=excluded.updated")
    .bind(user.id, await encrypt(env, JSON.stringify({ cards })), now));
  await env.DB.batch(stmts);
  return json({ ok: true, count: cards.length });
});

route("GET", "/v2/phone-actions", async (_req, env, user) => {
  const actions: PhoneAction[] = (await untaken(env, user.id)).map((a) => ({ id: a.id, client_id: a.client_id, card_id: a.card_id,
    action: a.action as PhoneAction["action"], title: a.title, group: a.group_name, created: a.created, made_at: a.made_at }));
  return json({ server_time: nowISO(), actions });
});

const idOk = (i: unknown) => typeof i === "string" && i.length > 0 && i.length <= 100;

route("POST", "/v2/phone-actions/ack", async (req, env, user) => {
  const rb = await readCappedJSON(req, 100_000);
  if (!rb.ok) return rb.tooLarge ? json({ error: "too large" }, 413) : json({ error: "Invalid JSON" }, 400);
  const ids = rb.body.ids ?? [];
  const skipped = rb.body.skipped ?? [];
  if (!Array.isArray(ids) || ids.length > MAX_UNTAKEN_ACTIONS || !ids.every(idOk)) {
    return json({ error: `ids must be a list of up to ${MAX_UNTAKEN_ACTIONS} ids` }, 400);
  }
  if (!Array.isArray(skipped) || skipped.length > MAX_UNTAKEN_ACTIONS
    || !skipped.every((s: any) => s && typeof s === "object" && idOk(s.id) && (s.reason === undefined || s.reason === null || typeof s.reason === "string"))) {
    return json({ error: `skipped must be a list of up to ${MAX_UNTAKEN_ACTIONS} { id, reason }` }, 400);
  }
  const now = nowISO();
  const stmts: D1PreparedStatement[] = [];
  for (const s of skipped as { id: string; reason?: string | null }[]) {
    const reason = (s.reason ?? "").trim().slice(0, MAX_REASON) || "skipped";
    // Logged first (from the action row, so only the owner's actions), then marked; the log id makes a repeat ack harmless.
    stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at)
        SELECT 'skip:' || id, user_id, 'mac', card_id, 'skipped', json_object('action', COALESCE(client_id, id), 'reason', ?), ?, ?
        FROM phone_actions WHERE id=? AND user_id=? AND outcome IS NULL`).bind(reason, now, now, s.id, user.id));
    stmts.push(env.DB.prepare("UPDATE phone_actions SET taken=1, outcome=? WHERE id=? AND user_id=? AND outcome IS NULL").bind(reason, s.id, user.id));
  }
  for (const id of ids as string[]) stmts.push(env.DB.prepare("UPDATE phone_actions SET taken=1 WHERE id=? AND user_id=?").bind(id, user.id));
  if (stmts.length) await env.DB.batch(stmts);
  return json({ ok: true });
});

/** Hourly: acked phone actions older than 7 days are deleted. */
export async function purgePhoneActions(env: Env): Promise<void> {
  const cutoff = new Date(Date.now() - TAKEN_KEEP_DAYS * 86400_000).toISOString();
  await env.DB.prepare("DELETE FROM phone_actions WHERE taken=1 AND created < ?").bind(cutoff).run();
}

/** Hourly: board log rows older than a year are deleted. */
export async function purgeBoardLog(env: Env): Promise<void> {
  const cutoff = new Date(Date.now() - LOG_KEEP_DAYS * 86400_000).toISOString();
  await env.DB.prepare("DELETE FROM board_log WHERE received_at < ?").bind(cutoff).run();
}

// ---------------------------------------------------------------- phone side (session cookie)

/** `GET /app/api/board` and `POST /app/api/action`; null for any other path. */
export async function handleBoard(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path === "/app/api/board" && req.method === "GET") {
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    return appJSON(await boardBody(env, s.userId, s.deviceId), 200, s.setCookie);
  }
  if (path === "/app/api/action" && req.method === "POST") {
    if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const receivedMs = Date.now();
    const rb = await readCappedJSON(req, MAX_ACTION_BYTES);
    if (!rb.ok) return appJSON({ error: rb.tooLarge ? "too large" : "Invalid JSON" }, rb.tooLarge ? 413 : 400, s.setCookie);
    const bad = (error: string, status = 400) => appJSON({ error }, status, s.setCookie);
    const r = "actions" in rb.body ? await doBatch(env, s.userId, s.deviceId, rb.body, receivedMs) : await doSingle(env, s.userId, s.deviceId, rb.body, receivedMs);
    if ("error" in r) return bad(r.error, r.status);
    return appJSON({ ...(await boardBody(env, s.userId, s.deviceId)), accepted: r.accepted, dropped: r.dropped }, 200, s.setCookie);
  }
  return null;
}

type Parsed = { card_id: number | null; action: Status | "add"; title: string | null; group: string | null };
type Outcome = { accepted: string[]; dropped: { id: string | null; reason: string }[] } | { error: string; status: number };

/** Validate one action's content (not its id or times); a message on anything off. */
function parseAction(body: any): Parsed | string {
  const action = body?.action;
  if (action === "add") {
    if (typeof body.title !== "string") return "title is required";
    const t: string = body.title.trim();
    if (t.length < 1 || t.length > MAX_TITLE) return `title must be 1 to ${MAX_TITLE} characters`;
    let group: string | null = null;
    if (body.group !== undefined && body.group !== null) {
      if (typeof body.group !== "string" || body.group.length > MAX_TITLE) return `group must be text up to ${MAX_TITLE} characters`;
      group = body.group.trim() || null;
    }
    return { card_id: null, action, title: t, group };
  }
  if (STATUSES.includes(action)) {
    if (!Number.isSafeInteger(body.card_id)) return "card_id must be an integer";
    return { card_id: body.card_id, action, title: null, group: null };
  }
  return "action must be todo, doing, watch, done or add";
}

type NewAction = Parsed & { clientId: string; madeAt: string; superseded: boolean };

/** Store accepted actions and their log rows in one batch; refused whole (429) when the waiting queue would pass 200. */
async function store(env: Env, userId: string, deviceId: string, list: NewAction[], sentAt: string | null, receivedMs: number): Promise<string | null> {
  const waiting = list.filter((a) => !a.superseded).length;
  const n = (await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=? AND taken=0").bind(userId).first<{ n: number }>())!.n;
  if (waiting && n + waiting > MAX_UNTAKEN_ACTIONS) return "Too many changes are waiting for your Mac. Open FloatBoard on the Mac and try again.";
  const now = iso(receivedMs);
  const stmts: D1PreparedStatement[] = [];
  for (const a of list) {
    const id = crypto.randomUUID();
    stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO phone_actions(id,user_id,card_id,action,title,group_name,created,taken,client_id,device_id,made_at,sent_at)
        VALUES(?,?,?,?,?,?,?,0,?,?,?,?)`).bind(id, userId, a.card_id, a.action, a.title, a.group, now, a.clientId, deviceId, a.madeAt, sentAt));
    stmts.push(logStmt(env, { id, userId, device: deviceId, cardId: a.card_id, kind: a.action === "add" ? "add" : "status",
      value: a.action === "add" ? await encrypt(env, a.title!) : a.action, madeAt: a.madeAt, receivedAt: now }));
    if (a.superseded) stmts.push(...supersedeStmts(env, userId, { id, client_id: a.clientId, card_id: a.card_id }, deviceId, now));
  }
  if (stmts.length) await env.DB.batch(stmts);
  return null;
}

/** Card ids this user's board has had at some point (so a missing card is "card gone" rather than "unknown card"). */
async function everSeen(env: Env, userId: string, cardIds: number[]): Promise<Set<number>> {
  const seen = new Set<number>();
  for (let i = 0; i < cardIds.length; i += 50) {
    const part = cardIds.slice(i, i + 50);
    const rows = await env.DB.prepare(`SELECT DISTINCT card_id FROM board_log WHERE user_id=? AND card_id IN (${part.map(() => "?").join(",")})`)
      .bind(userId, ...part).all<{ card_id: number }>();
    for (const r of rows.results) seen.add(r.card_id);
  }
  return seen;
}

/** Action ids (the phone's own) this user has already sent. */
async function known(env: Env, userId: string, clientIds: string[]): Promise<Set<string>> {
  const seen = new Set<string>();
  for (let i = 0; i < clientIds.length; i += 50) {
    const part = clientIds.slice(i, i + 50);
    const rows = await env.DB.prepare(`SELECT client_id FROM phone_actions WHERE user_id=? AND client_id IN (${part.map(() => "?").join(",")})`)
      .bind(userId, ...part).all<{ client_id: string }>();
    for (const r of rows.results) seen.add(r.client_id);
  }
  return seen;
}

/** The older single-action shape `{ card_id?, action, title?, group? }`: made now, errors as before (400, 404, 429). */
async function doSingle(env: Env, userId: string, deviceId: string, body: any, receivedMs: number): Promise<Outcome> {
  const p = parseAction(body);
  if (typeof p === "string") return { error: p, status: 400 };
  const snap = await loadSnapshot(env, userId);
  const c = p.card_id === null ? undefined : snap?.cards.find((x) => x.id === p.card_id);
  if (p.card_id !== null && !c) return { error: "That task isn't on your board.", status: 404 };
  const clientId = crypto.randomUUID();
  const madeAt = iso(receivedMs);
  const err = await store(env, userId, deviceId, [{ ...p, clientId, madeAt, superseded: !!c && madeAt < statusAt(c, snap!.updated) }], null, receivedMs);
  return err ? { error: err, status: 429 } : { accepted: [clientId], dropped: [] };
}

/** `{ sent_at?, actions: [{ id, made_at?, card_id?, action, title?, group? }] }`: the phone's offline queue, at most 100 at once. */
async function doBatch(env: Env, userId: string, deviceId: string, body: any, receivedMs: number): Promise<Outcome> {
  const list = body.actions;
  if (!Array.isArray(list) || list.length < 1 || list.length > MAX_BATCH) return { error: `actions must be a list of 1 to ${MAX_BATCH} actions`, status: 400 };
  const sentAt = body.sent_at ?? null;
  if (sentAt !== null && !isIso(sentAt)) return { error: "sent_at must be an ISO date", status: 400 };
  const skew = skewOf(sentAt, receivedMs);
  const snap = await loadSnapshot(env, userId);
  const cards = new Map((snap?.cards ?? []).map((c) => [c.id, c]));
  const valid = list.map((a: any) => (a && typeof a === "object" && typeof a.id === "string" && ACTION_ID.test(a.id)
    && (a.made_at === undefined || a.made_at === null || isIso(a.made_at)) ? parseAction(a) : "invalid"));
  const ids = list.map((a: any, i: number) => (typeof valid[i] === "string" ? null : a.id as string)).filter((x: string | null): x is string => x !== null);
  const already = await known(env, userId, [...new Set(ids)]);
  const missing = [...new Set(valid.flatMap((p: Parsed | string) => (typeof p !== "string" && p.card_id !== null && !cards.has(p.card_id) ? [p.card_id] : [])))] as number[];
  const gone = await everSeen(env, userId, missing);
  const accepted: string[] = [];
  const dropped: { id: string | null; reason: string }[] = [];
  const fresh: NewAction[] = [];
  const inBatch = new Set<string>();
  list.forEach((a: any, i: number) => {
    const p = valid[i];
    if (typeof p === "string") { dropped.push({ id: typeof a?.id === "string" ? a.id.slice(0, 64) : null, reason: "invalid" }); return; }
    if (already.has(a.id) || inBatch.has(a.id)) { accepted.push(a.id); return; }
    const c = p.card_id === null ? undefined : cards.get(p.card_id);
    if (p.card_id !== null && !c) { dropped.push({ id: a.id, reason: gone.has(p.card_id) ? "card gone" : "unknown card" }); return; }
    const madeAt = corrected(a.made_at, skew, receivedMs) ?? iso(receivedMs);
    inBatch.add(a.id);
    accepted.push(a.id);
    fresh.push({ ...p, clientId: a.id, madeAt, superseded: !!c && madeAt < statusAt(c, snap!.updated) });
  });
  const err = await store(env, userId, deviceId, fresh, sentAt, receivedMs);
  return err ? { error: err, status: 429 } : { accepted, dropped };
}
