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
 * - `link_email` / `unlink_email` (from "Link an email" on the phone) never change a card's step: they are queued with the
 *   email to attach (`payload`; the account must be one of the user's own Gmail inboxes) and the Mac applies them to
 *   tasks the user made. A card's optional `email` says who linked its email ("sorting" or "user") so the phone knows
 *   which button to show.
 */
import { type Env, json, nowISO } from "../env";
import { decrypt, encrypt } from "../lib/crypto";
import { readCappedJSON } from "../lib/http";
import { route } from "../lib/router";
import { accountMarker, appJSON, requireAppSession, sameOrigin } from "./auth";
import { GMAIL_ID, ownGmail } from "../email/search";

export const MAX_CARDS = 500;
export const MAX_EVENTS = 200;   // two weeks of meetings (the planning summary: today through the end of next week)
const MAX_REPEAT = 80;
const MAX_EVENT_TASKS = 20;
export const MAX_UNTAKEN_ACTIONS = 200;
export const MAX_BATCH = 100;
const MAX_TITLE = 200;
const MAX_LINK = 2000;
const MAX_LINKS = 6;
const LINK_KINDS = ["email", "meeting", "link"] as const;
const LINK_LABELS = ["calendar"] as const;
const MAX_REASON = 200;
const MAX_BOARD_BYTES = 1_500_000;
const MAX_ACTION_BYTES = 64_000;
const TAKEN_KEEP_DAYS = 7;
const LOG_KEEP_DAYS = 365;
const MAX_SKEW_MS = 7 * 86400_000;
const MAX_SUPERSEDED_LISTED = 200;
const ACTION_ID = /^[A-Za-z0-9-]{8,64}$/;
const STATUSES = ["todo", "doing", "watch", "done"] as const;
/** Link a task to an email (or remove that link) from the phone: the Mac applies it; it never changes the task's step. */
const LINKS = ["link_email", "unlink_email"] as const;
/** The "teach" reasons a delete of an email-sorting task can carry, as the Mac offers them. */
const TEACH = ["not_action", "wrong_details", "duplicate"] as const;
const EMAIL_KINDS = ["sorting", "user"] as const;
const MAX_MESSAGE_ID = 998;
const MAX_ACCOUNT = 320;
const DEFAULT_COLOR = "#8e8e93";
/** Tags on a task (primary first: its group), the assistant's areas, and budget reminders (foundation design §4). */
const MAX_TAGS = 20;
const MAX_TAG = 60;
const MODULES = ["jots", "circle", "decisions", "resolutions"] as const;
const MAX_REMINDERS = 20;
/** The Mac shows a budget reminder in the first 10 minutes; after that it is the phone's (sent once, if still in the copy). */
export const REMINDER_GRACE_MS = 10 * 60_000;

export type Status = (typeof STATUSES)[number];
/** One link on a task: what it opens and where. `label` "calendar" marks the task's calendar event. */
export type CardLink = { kind: (typeof LINK_KINDS)[number]; url: string; label?: (typeof LINK_LABELS)[number] };
/** `email`: the task's linked email, made by the email sorting ("sorting") or linked by the user ("user"); absent when none. */
export type Card = {
  id: number; title: string; group: string; color: string; importance: 0 | 1 | 2; due: string | null; has_time: boolean;
  status: Status; link: string | null; links?: CardLink[]; email?: (typeof EMAIL_KINDS)[number]; done_at: string | null; status_at?: string | null;
  pending?: true; action_id?: string | null;
  /** True for a task the email sorting made: the phone's Delete offers the Mac's "teach" choices. */
  teach_on_delete?: true;
  /** Watch only: whom it waits on, how to recognise their reply ("email:<address>", "wa:<chat id>" or ""), and since when. */
  watch?: CardWatch;
  /** Every tag, primary (the group) first, and when they last changed on the Mac (newest change wins against set_tags). */
  tags?: string[]; tags_at?: string | null;
};
export type Modules = Record<(typeof MODULES)[number], boolean>;
/** A budget reminder waiting to be shown (the Mac sends the ones it has not shown). */
export type BoardReminder = { id: string; title: string; text: string; fire_at: string };
/**
 * A calendar event for the phone's planning summary: ISO UTC times, `tasks` = ids of the cards linked to it. A repeating
 * meeting's instances share `series` (an opaque "S-" key) and carry `repeat` (its rule in a few words, "weekdays 09:00"),
 * so the phone lists it once per block; both are absent for a one-off event.
 */
export type BoardEvent = { id: string; title: string; start: string; end: string; all_day: boolean; video: string | null; color: string; tasks: number[];
  series?: string; repeat?: string; original_start?: string };
export type CardWatch = { person: string; contact: string; since: string };
/** The email a `link_email` action attaches (sent_at as the search gave it). */
export type LinkedEmail = { message_id: string; gmail_id: string; account: string; sent_at: string | null };
export type PhoneAction = {
  id: string; client_id: string | null; card_id: number | null; action: Status | "add" | (typeof LINKS)[number] | "watch_reply" | "delete" | "restore" | "set_tags";
  title: string | null; group: string | null; created: string; made_at: string; email?: LinkedEmail;
  /** delete only: the "teach" reason chosen on the phone (not_action | wrong_details | duplicate). */
  teach?: string;
  /** watch_reply only: the watched person wrote again ("Anna replied by email"); the Mac moves the task back to To do. */
  reason?: string;
  /** set_tags only: the task's tags, primary (its group) first. */
  tags?: string[];
};
type ActionRow = {
  id: string; rid: number; client_id: string | null; card_id: number | null; action: string; title: string | null; group_name: string | null;
  created: string; made_at: string; taken: number; payload: string | null;
};
const isMove = (action: string): action is Status => (STATUSES as readonly string[]).includes(action);
/** Actions decided by "newest change wins" against the card's last step change on the Mac: moves and delete. */
const newestWins = (action: string) => isMove(action) || action === "delete";

/** A task's tags: 1 to 20 names, each 1 to 60 UTF-16 units once trimmed, no repeats (case ignored). Throws on anything
 *  else. The Mac sends only tags that pass (`TagRules.forPhone` in mac/Sources/FloatBoardCore/Items/Tags.swift): keep the two equal. */
function parseTags(v: unknown, at: string): string[] {
  if (!Array.isArray(v) || v.length < 1 || v.length > MAX_TAGS) throw new Error(`${at} must be a list of 1 to ${MAX_TAGS} tags`);
  const seen = new Set<string>();
  return v.map((t: unknown, i: number) => {
    if (typeof t !== "string" || !t.trim() || t.trim().length > MAX_TAG) throw new Error(`${at}[${i}] must be text of 1 to ${MAX_TAG} characters`);
    if (seen.has(t.trim().toLowerCase())) throw new Error(`${at}[${i}] repeats`);
    seen.add(t.trim().toLowerCase());
    return t.trim();
  });
}

/** The optional `modules` of a push: each area on or off. Absent: undefined (an older Mac). */
export function parseModules(v: unknown): Modules | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "object" || Array.isArray(v)) throw new Error("modules must be an object");
  const out = {} as Modules;
  for (const m of MODULES) {
    const x = (v as any)[m];
    if (x !== undefined && typeof x !== "boolean") throw new Error(`modules.${m} must be true or false`);
    out[m] = x === true;
  }
  return out;
}

/** One of this quarter's goals for More › Resolutions (the Mac sends them while Resolutions is on). */
export type BoardGoal = { id: string; title: string; period: string; parent: string | null; done: number; open: number; tasks: number[] };
const MAX_GOALS = 10;
const MAX_GOAL_TASKS = 50;
const isCount = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 100_000;

/** The optional `goals` of a push (Resolutions). Absent: undefined. Throws on anything malformed. */
export function parseGoals(v: unknown): BoardGoal[] | undefined {
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || v.length > MAX_GOALS) throw new Error(`goals must be a list of at most ${MAX_GOALS}`);
  return v.map((g: any, i: number) => {
    const at = `goals[${i}]`;
    if (!g || typeof g !== "object") throw new Error(`${at} must be an object`);
    if (typeof g.id !== "string" || !/^R-[1-9][0-9]{0,15}$/.test(g.id)) throw new Error(`${at}.id must be a goal id (R-n)`);
    if (typeof g.title !== "string" || !g.title.trim() || g.title.length > MAX_TITLE) throw new Error(`${at}.title must be text of 1 to ${MAX_TITLE} characters`);
    if (typeof g.period !== "string" || g.period.length > 20) throw new Error(`${at}.period must be short text`);
    if (g.parent !== undefined && g.parent !== null && (typeof g.parent !== "string" || g.parent.length > MAX_TITLE)) throw new Error(`${at}.parent must be text or null`);
    if (!isCount(g.done) || !isCount(g.open)) throw new Error(`${at}.done and .open must be whole numbers`);
    if (!Array.isArray(g.tasks) || g.tasks.length > MAX_GOAL_TASKS || !g.tasks.every((t: unknown) => typeof t === "number" && Number.isInteger(t))) {
      throw new Error(`${at}.tasks must be a list of at most ${MAX_GOAL_TASKS} task ids`);
    }
    return { id: g.id, title: g.title, period: g.period, parent: g.parent ?? null, done: g.done, open: g.open, tasks: g.tasks };
  });
}

/** The optional `reminders` of a push (budget reminders the Mac has not shown). */
export function parseReminders(v: unknown): BoardReminder[] | undefined {
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || v.length > MAX_REMINDERS) throw new Error(`reminders must be a list of at most ${MAX_REMINDERS}`);
  return v.map((r: any, i: number) => {
    const at = `reminders[${i}]`;
    if (!r || typeof r !== "object") throw new Error(`${at} must be an object`);
    if (typeof r.id !== "string" || !/^[A-Za-z0-9_:.-]{1,120}$/.test(r.id)) throw new Error(`${at}.id must be a reminder id`);
    if (typeof r.title !== "string" || r.title.length > MAX_TITLE) throw new Error(`${at}.title must be text up to ${MAX_TITLE} characters`);
    if (typeof r.text !== "string" || r.text.length > MAX_TITLE) throw new Error(`${at}.text must be text up to ${MAX_TITLE} characters`);
    if (!isIso(r.fire_at)) throw new Error(`${at}.fire_at must be an ISO date`);
    return { id: r.id, title: r.title, text: r.text, fire_at: r.fire_at };
  });
}

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

/** A card's `links`: optional; when sent, a list of at most 6 `{ kind, url, label? }` with nothing else, http(s) urls only. */
function cardLinks(v: unknown): CardLink[] | undefined {
  if (v === undefined) return undefined;
  if (!Array.isArray(v) || v.length > MAX_LINKS) throw new Error(`links must be a list of at most ${MAX_LINKS}`);
  return v.map((l: any, i: number): CardLink => {
    const at = `links[${i}]`;
    if (!l || typeof l !== "object" || Array.isArray(l)) throw new Error(`${at} must be an object`);
    if (Object.keys(l).some((k) => k !== "kind" && k !== "url" && k !== "label")) throw new Error(`${at} may only have kind, url and label`);
    if (!LINK_KINDS.includes(l.kind)) throw new Error(`${at}.kind must be email, meeting or link`);
    if (l.label !== undefined && !LINK_LABELS.includes(l.label)) throw new Error(`${at}.label must be calendar when given`);
    if (l.url === null) throw new Error(`${at}.url must be a web address`);
    try { httpLink(l.url); } catch (e) { throw new Error(`${at}.url: ${(e as Error).message}`); }
    return l.label === undefined ? { kind: l.kind, url: l.url } : { kind: l.kind, url: l.url, label: l.label };
  });
}

/** Strictly validate a pushed board; throws Error(message) on anything off. `status_at` is optional (as the Mac sent it). */
function cardWatch(w: any): CardWatch {
  if (!w || typeof w !== "object" || Array.isArray(w)) throw new Error("watch must be an object");
  if (typeof w.person !== "string" || w.person.length > 100) throw new Error("watch.person must be text up to 100 characters");
  if (typeof w.contact !== "string" || w.contact.length > 330 || !(w.contact === "" || /^email:[^\s@]+@[^\s@]+$/.test(w.contact) || /^wa:[\w.@-]+$/.test(w.contact))) {
    throw new Error("watch.contact must be email:<address>, wa:<chat id> or empty");
  }
  const since = isoOrNull(w.since, "watch.since");
  if (!since) throw new Error("watch.since must be a date");
  return { person: w.person, contact: w.contact, since };
}

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
      const out: Card = { id: c.id, title: c.title, group: c.group, color: c.color, importance: c.importance, due: isoOrNull(c.due, "due"),
        has_time: c.has_time, status: c.status, link: httpLink(c.link), done_at: isoOrNull(c.done_at, "done_at"),
        status_at: c.status_at === undefined ? null : isoOrNull(c.status_at, "status_at") };
      const links = cardLinks(c.links);
      if (links) out.links = links;
      if (c.watch !== undefined && c.watch !== null) out.watch = cardWatch(c.watch);
      if (c.teach_on_delete === true) out.teach_on_delete = true;   // anything else: a plain delete (never a refused push)
      // Tags never block the board: a card whose tags break the rule (the Mac's TagRules.forPhone is the same rule) just
      // goes without them, and is logged; the rest of the push is stored.
      if (c.tags !== undefined && c.tags !== null) {
        try {
          out.tags = parseTags(c.tags, "tags");
          if (c.tags_at !== undefined && c.tags_at !== null && isIso(c.tags_at)) out.tags_at = c.tags_at;
        } catch (e) { console.warn(JSON.stringify({ event: "board_tags_dropped", card: c.id, why: (e as Error).message })); }
      }
      if (c.email !== undefined && c.email !== null) {
        if (!EMAIL_KINDS.includes(c.email)) throw new Error("email must be sorting or user when given");
        out.email = c.email;
      }
      return out;
    } catch (e) { throw new Error(`${at}.${(e as Error).message}`); }
  });
}

/** The optional `events` of a push (absent from older Macs: none), strictly checked like cards; trimmed text, https-only video. */
export function parseEvents(body: any): BoardEvent[] | undefined {
  const v = body?.events;
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v)) throw new Error("events must be a list");
  if (v.length > MAX_EVENTS) throw new Error(`at most ${MAX_EVENTS} events`);
  return v.map((e: any, i: number): BoardEvent => {
    const at = `events[${i}]`;
    if (!e || typeof e !== "object" || Array.isArray(e)) throw new Error(`${at} must be an object`);
    if (typeof e.id !== "string" || !/^E-[1-9][0-9]*$/.test(e.id) || e.id.length > 20) throw new Error(`${at}.id must look like E-37`);
    if (typeof e.title !== "string") throw new Error(`${at}.title must be text`);
    const title = e.title.trim();
    if (title.length > MAX_TITLE) throw new Error(`${at}.title must be text up to ${MAX_TITLE} characters`);
    if (!isIso(e.start)) throw new Error(`${at}.start must be an ISO date`);
    if (!isIso(e.end)) throw new Error(`${at}.end must be an ISO date`);
    if (typeof e.all_day !== "boolean") throw new Error(`${at}.all_day must be true or false`);
    // A bad meeting link must not stop the push: anything but a clean https address becomes null.
    let video: string | null = null;
    if (typeof e.video === "string" && e.video.length <= MAX_LINK && !/\s/.test(e.video)) {
      try { const u = new URL(e.video); if (u.protocol === "https:" && u.hostname) video = e.video; } catch { /* not an address: no Join button */ }
    }
    if (typeof e.color !== "string" || !/^#[0-9a-fA-F]{6}$/.test(e.color)) throw new Error(`${at}.color must be a hex colour like #aabbcc`);
    if (!Array.isArray(e.tasks) || e.tasks.length > MAX_EVENT_TASKS || !e.tasks.every((t: unknown) => Number.isSafeInteger(t) && (t as number) > 0)) {
      throw new Error(`${at}.tasks must be a list of up to ${MAX_EVENT_TASKS} positive integers`);
    }
    // Like the link: a bad series key or label is left out (the meeting is then listed like a one-off), never a refused push.
    const series = typeof e.series === "string" && /^S-[0-9a-f]{1,32}$/.test(e.series) ? e.series : undefined;
    const rep = typeof e.repeat === "string" ? e.repeat.trim() : "";
    const repeat = rep && rep.length <= MAX_REPEAT && !/[\u0000-\u001f\u007f]/.test(rep) ? rep : undefined;
    // An instance's original start (Google's originalStartTime; differs from `start` when moved): an ISO date, else left out.
    const original = isIso(e.original_start) ? e.original_start as string : undefined;
    return { id: e.id, title, start: e.start, end: e.end, all_day: e.all_day, video, color: e.color, tasks: e.tasks,
      ...(series ? { series } : {}), ...(repeat ? { repeat } : {}), ...(original ? { original_start: original } : {}) };
  });
}

/** The zone the Mac shows times in (an IANA name, e.g. Europe/London), so the phone shows the same times; absent: the device's. */
function parseZone(v: unknown): string | undefined {
  if (typeof v !== "string" || v.length > 64) return undefined; // unknown or bad: ignored, the phone uses its own zone
  try { new Intl.DateTimeFormat("en", { timeZone: v }); } catch { return undefined; }
  return v;
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

type Snapshot = { cards: Card[]; events?: BoardEvent[]; time_zone?: string; modules?: Modules; reminders?: BoardReminder[]; goals?: BoardGoal[];
  updated: string };
async function loadSnapshot(env: Env, userId: string): Promise<Snapshot | null> {
  const row = await env.DB.prepare("SELECT data_enc, updated FROM board_snapshots WHERE user_id=?").bind(userId).first<{ data_enc: string; updated: string }>();
  if (!row) return null;
  const d = JSON.parse(await decrypt(env, row.data_enc));
  return { cards: d.cards as Card[], events: d.events as BoardEvent[] | undefined, time_zone: d.time_zone as string | undefined,
    modules: d.modules as Modules | undefined, reminders: d.reminders as BoardReminder[] | undefined, goals: d.goals as BoardGoal[] | undefined,
    updated: row.updated };
}

const ACTION_COLS = "id, rowid AS rid, client_id, card_id, action, title, group_name, created, COALESCE(made_at, created) AS made_at, taken, payload";

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
  const hidden = new Set<number>();
  for (const a of actions) {
    if (a.action === "add") {
      if (a.taken) continue;
      const group = a.group_name || "Inbox";
      out.push({ id: -a.rid, title: a.title ?? "", group, color: out.find((c) => c.group === group)?.color ?? DEFAULT_COLOR, importance: 0,
        due: null, has_time: false, status: "todo", link: null, done_at: null, status_at: a.made_at, pending: true, action_id: a.client_id });
    } else if (isMove(a.action)) {
      const c = out.find((x) => x.id === a.card_id);
      if (c && a.made_at >= base.get(c.id)!) applyMove(c, a.action, a.made_at);
    } else if (a.action === "delete" && a.card_id !== null && base.has(a.card_id) && a.made_at >= base.get(a.card_id)!) {
      hidden.add(a.card_id);
    } else if (a.action === "restore" && a.card_id !== null) {
      hidden.delete(a.card_id);
    } else if (a.action === "set_tags" && a.payload) {
      // Newest wins against the Mac's last tag change; the first tag is the group (colour from a card already in it).
      const c = out.find((x) => x.id === a.card_id);
      const tags = JSON.parse(a.payload).tags as string[] | undefined;
      if (c && tags?.length && a.made_at >= (c.tags_at ?? statusAt(c, snapUpdated))) {
        c.tags = tags;
        if (c.group !== tags[0]) { c.group = tags[0]; c.color = cards.find((x) => x.group === tags[0])?.color ?? DEFAULT_COLOR; }
      }
    }
  }
  return hidden.size ? out.filter((c) => !hidden.has(c.id)) : out;
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

/** The budget reminders in the Mac's latest copy (none without one). */
export async function boardReminders(env: Env, userId: string): Promise<BoardReminder[]> {
  return (await loadSnapshot(env, userId))?.reminders ?? [];
}

/** The board as the phone would see it now (the Mac's copy plus phone moves not yet applied); empty without a copy. */
export async function currentBoard(env: Env, userId: string): Promise<Card[]> {
  const [snap, actions] = await Promise.all([loadSnapshot(env, userId), overlayActions(env, userId)]);
  return snap ? overlay(snap.cards, actions, snap.updated) : [];
}

async function boardBody(env: Env, userId: string, deviceId: string) {
  const [snap, actions, waiting, superseded, account] = await Promise.all([loadSnapshot(env, userId), overlayActions(env, userId),
    env.DB.prepare("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=? AND taken=0").bind(userId).first<{ n: number }>(),
    notApplied(env, userId, deviceId), accountMarker(userId)]);
  return { updated: snap?.updated ?? null, server_time: nowISO(), account, cards: overlay(snap?.cards ?? [], actions, snap?.updated ?? null),
    ...(snap?.events ? { events: snap.events } : {}), ...(snap?.time_zone ? { time_zone: snap.time_zone } : {}),
    ...(snap?.modules ? { modules: snap.modules } : {}), ...(snap?.goals ? { goals: snap.goals } : {}), pending: waiting?.n ?? 0, superseded };
}

const logStmt = (env: Env, r: { id: string; userId: string; device: string; cardId: number | null; kind: string; value: string | null; madeAt: string;
    receivedAt: string; clientId?: string | null }) =>
  env.DB.prepare("INSERT OR IGNORE INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at,client_id) VALUES(?,?,?,?,?,?,?,?,?)")
    .bind(r.id, r.userId, r.device, r.cardId, r.kind, r.value, r.madeAt, r.receivedAt, r.clientId ?? null);

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
  let events: BoardEvent[] | undefined, timeZone: string | undefined, modules: Modules | undefined, reminders: BoardReminder[] | undefined;
  let goals: BoardGoal[] | undefined;
  try {
    events = parseEvents(rb.body); timeZone = parseZone(rb.body.time_zone);
    modules = parseModules(rb.body.modules); reminders = parseReminders(rb.body.reminders); goals = parseGoals(rb.body.goals);
  } catch (e) { return json({ error: (e as Error).message }, 400); }
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
    if (!isMove(a.action) || !c || a.made_at >= c.status_at!) continue;
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
    .bind(user.id, await encrypt(env, JSON.stringify({ cards, ...(events ? { events } : {}), ...(timeZone ? { time_zone: timeZone } : {}),
      ...(modules ? { modules } : {}), ...(reminders ? { reminders } : {}), ...(goals ? { goals } : {}) })), now));
  // Each area's background jobs read which areas are on from settings.
  if (modules) stmts.push(env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify(modules), user.id));
  await env.DB.batch(stmts);
  return json({ ok: true, count: cards.length });
});

route("GET", "/v2/phone-actions", async (_req, env, user) => {
  const actions: PhoneAction[] = (await untaken(env, user.id)).map((a) => ({ id: a.id, client_id: a.client_id, card_id: a.card_id,
    action: a.action as PhoneAction["action"], title: a.title, group: a.group_name, created: a.created, made_at: a.made_at,
    ...(a.action === "link_email" && a.payload ? { email: JSON.parse(a.payload) as LinkedEmail } : {}),
    ...(a.action === "watch_reply" && a.payload ? { reason: String(JSON.parse(a.payload).reason ?? "") } : {}),
    ...(a.action === "delete" && a.payload ? { teach: String(JSON.parse(a.payload).teach ?? "") } : {}),
    ...(a.action === "set_tags" && a.payload ? { tags: JSON.parse(a.payload).tags as string[] } : {}) }));
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

type Parsed = { card_id: number | null; action: PhoneAction["action"]; title: string | null; group: string | null; email?: LinkedEmail; teach?: string;
  tags?: string[] };
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
  if (STATUSES.includes(action) || LINKS.includes(action)) {
    if (!Number.isSafeInteger(body.card_id)) return "card_id must be an integer";
    if (action !== "link_email") return { card_id: body.card_id, action, title: null, group: null };
    const { message_id, gmail_id, account, sent_at } = body;
    if (typeof message_id !== "string" || !message_id.trim() || message_id.length > MAX_MESSAGE_ID || /[\u0000-\u001f\u007f]/.test(message_id)) {
      return "message_id must be an email's Message-ID";
    }
    if (typeof gmail_id !== "string" || !GMAIL_ID.test(gmail_id)) return "gmail_id must be a Gmail message id";
    if (typeof account !== "string" || !account.includes("@") || account.length > MAX_ACCOUNT) return "account must be a Gmail address";
    if (sent_at !== undefined && sent_at !== null && !isIso(sent_at)) return "sent_at must be an ISO date or null";
    return { card_id: body.card_id, action, title: null, group: null, email: { message_id, gmail_id, account, sent_at: sent_at ?? null } };
  }
  if (action === "delete" || action === "restore") {
    if (!Number.isSafeInteger(body.card_id)) return "card_id must be an integer";
    if (action === "restore" || body.teach === undefined || body.teach === null) return { card_id: body.card_id, action, title: null, group: null };
    if (!(TEACH as readonly unknown[]).includes(body.teach)) return `teach must be one of ${TEACH.join(", ")}`;
    return { card_id: body.card_id, action, title: null, group: null, teach: body.teach };
  }
  if (action === "set_tags") {
    if (!Number.isSafeInteger(body.card_id)) return "card_id must be an integer";
    try { return { card_id: body.card_id, action, title: null, group: null, tags: parseTags(body.tags, "tags") }; } catch (e) { return (e as Error).message; }
  }
  return "action must be todo, doing, watch, done, add, link_email, unlink_email, delete, restore or set_tags";
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
    stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO phone_actions(id,user_id,card_id,action,title,group_name,created,taken,client_id,device_id,made_at,sent_at,payload)
        VALUES(?,?,?,?,?,?,?,0,?,?,?,?,?)`).bind(id, userId, a.card_id, a.action, a.title, a.group, now, a.clientId, deviceId, a.madeAt, sentAt,
      a.email ? JSON.stringify(a.email) : a.teach ? JSON.stringify({ teach: a.teach }) : a.tags ? JSON.stringify({ tags: a.tags }) : null));
    // The log says a link was made or removed, never which email.
    stmts.push(logStmt(env, { id, userId, device: deviceId, cardId: a.card_id, kind: a.action === "add" ? "add" : isMove(a.action) ? "status"
      : a.action === "delete" || a.action === "restore" ? a.action : a.action === "set_tags" ? "tags" : "link",
      value: a.action === "add" ? await encrypt(env, a.title!) : a.action === "delete" ? (a.teach ?? null) : a.action, madeAt: a.madeAt, receivedAt: now, clientId: a.clientId }));
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

/** Action ids (the phone's own) this user has already sent: in the queue (acked rows are kept 7 days) or in the board log
 *  (kept a year), so a late resend after the queue row was purged is still ignored. */
async function known(env: Env, userId: string, clientIds: string[]): Promise<Set<string>> {
  const seen = new Set<string>();
  for (let i = 0; i < clientIds.length; i += 40) {
    const part = clientIds.slice(i, i + 40);
    const q = part.map(() => "?").join(",");
    const rows = await env.DB.prepare(`SELECT client_id FROM phone_actions WHERE user_id=? AND client_id IN (${q})
        UNION SELECT client_id FROM board_log WHERE user_id=? AND client_id IN (${q})`)
      .bind(userId, ...part, userId, ...part).all<{ client_id: string }>();
    for (const r of rows.results) seen.add(r.client_id);
  }
  return seen;
}

/** An action older than the Mac's own change to the same thing loses: a move or delete against the card's step change,
 *  set_tags against its last tag change. */
function olderThanMac(action: string, c: Card, madeAt: string, snapUpdated: string): boolean {
  if (action === "set_tags") return madeAt < (c.tags_at ?? statusAt(c, snapUpdated));
  return newestWins(action) && madeAt < statusAt(c, snapUpdated);
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
  if (p.email && !(await ownGmail(env, userId, p.email.account))) return { error: "account must be one of your Gmail inboxes", status: 400 };
  const err = await store(env, userId, deviceId, [{ ...p, clientId, madeAt, superseded: !!c && olderThanMac(p.action, c, madeAt, snap!.updated) }], null, receivedMs);
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
  // A link names one of this user's own Gmail inboxes, else it is invalid.
  const accounts = [...new Set(valid.flatMap((p: Parsed | string) => (typeof p !== "string" && p.email ? [p.email.account] : [])))] as string[];
  const mine = new Set<string>();
  for (const acc of accounts) if (await ownGmail(env, userId, acc)) mine.add(acc);
  const accepted: string[] = [];
  const dropped: { id: string | null; reason: string }[] = [];
  const fresh: NewAction[] = [];
  const inBatch = new Set<string>();
  list.forEach((a: any, i: number) => {
    const p = valid[i];
    if (typeof p === "string" || (p.email && !mine.has(p.email.account))) { dropped.push({ id: typeof a?.id === "string" ? a.id.slice(0, 64) : null, reason: "invalid" }); return; }
    if (already.has(a.id) || inBatch.has(a.id)) { accepted.push(a.id); return; }
    const c = p.card_id === null ? undefined : cards.get(p.card_id);
    // A restore is for a card the Mac already deleted (gone from its copy): accepted when the board ever had it.
    if (p.card_id !== null && !c && !(p.action === "restore" && gone.has(p.card_id))) {
      dropped.push({ id: a.id, reason: gone.has(p.card_id) ? "card gone" : "unknown card" }); return;
    }
    const madeAt = corrected(a.made_at, skew, receivedMs) ?? iso(receivedMs);
    inBatch.add(a.id);
    accepted.push(a.id);
    fresh.push({ ...p, clientId: a.id, madeAt, superseded: !!c && olderThanMac(p.action, c, madeAt, snap!.updated) });
  });
  const err = await store(env, userId, deviceId, fresh, sentAt, receivedMs);
  return err ? { error: err, status: 429 } : { accepted, dropped };
}
