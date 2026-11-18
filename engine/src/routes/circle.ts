/**
 * Circle's routes for the Mac (user key): the Gmail/Outlook metadata the readers found, the people to follow for What's
 * new and what was found, the phone's copy and actions, and the on-request Haiku jobs (fill the add-contact form, draft a
 * message). See docs/superpowers/specs/2026-11-17-circle-design.md §4–§8.
 */
import { type Env, json, nowISO } from "../env";
import { readCappedJSON, readJSON } from "../lib/http";
import { route } from "../lib/router";
import { circleFetch } from "../circle/net";
import { publicHttpUrl } from "../circle/safe-url";
import { circleOn, haikuFor, seal, unseal } from "../circle/common";
import { draftInput, draftMessage, fillContact, headerBits } from "../circle/ai";
import type { Who } from "../circle/gmail";
import type { Update, WatchPerson } from "../circle/updates";

const PAGE = 500;
const PERSON = /^P-\d{1,12}$/;
const MAX_WATCH = 500;
const MAX_COPY_BYTES = 1_500_000;
export const CIRCLE_ACTIONS = ["contacted", "talked", "snooze"] as const;
const KEEP_EXCHANGES_MS = 30 * 86400_000;
const KEEP_TAKEN_MS = 7 * 86400_000;

const afterOf = (req: Request) => {
  const n = Number(new URL(req.url).searchParams.get("after") ?? "0");
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0;
};

/** Gmail and Outlook metadata after `seq`, oldest first, and each reader's state ("data as of"). */
route("GET", "/v2/circle/exchanges", async (req, env, user) => {
  const after = afterOf(req);
  const rows = (await env.DB.prepare(`SELECT seq, key, channel, direction, at, account, who_enc FROM circle_exchanges WHERE user_id=? AND seq>?
      ORDER BY seq LIMIT ${PAGE}`).bind(user.id, after).all<{ seq: number; key: string; channel: string; direction: string; at: string; account: string; who_enc: string }>()).results;
  const exchanges = [];
  for (const r of rows) {
    const w = await unseal<Who>(env, r.who_enc);
    exchanges.push({ seq: r.seq, key: r.key, channel: r.channel, direction: r.direction, at: r.at, account: r.account, handle: w.h, name: w.n });
  }
  const readers = (await env.DB.prepare(`SELECT reader, as_of, complete_from, note FROM circle_readers WHERE user_id=? AND (reader LIKE 'gmail:%' OR reader='outlook')
      ORDER BY reader`).bind(user.id).all()).results;
  return json({ exchanges, readers, next: rows.length ? rows[rows.length - 1].seq : after, more: rows.length === PAGE });
});

function watchPerson(x: any): WatchPerson | null {
  const s = (v: unknown, max: number) => (typeof v === "string" && v.length <= max ? v.trim() : null);
  if (!x || typeof x !== "object" || typeof x.person !== "string" || !PERSON.test(x.person)) return null;
  const name = s(x.name, 200), firm = s(x.firm ?? "", 200), company = s(x.company ?? "", 200), officer = s(x.officer_id ?? "", 64),
    born = s(x.born ?? "", 7), feed = s(x.feed_url ?? "", 2000);
  if (!name || firm === null || company === null || officer === null || born === null || feed === null) return null;
  if (born && !/^\d{4}-\d{2}$/.test(born)) return null;
  if (feed && !publicHttpUrl(feed)) return null;   // public web addresses only (no loopback, private or link-local hosts)
  return { person: x.person, name, firm, company, officer_id: officer, born, feed_url: feed, news: x.news !== false, ch: x.ch !== false };
}

/** The people to follow for What's new (the Mac sends only eligible ones), replacing the last list. */
route("PUT", "/v2/circle/watch", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const list = (b.body as any)?.people;
  if (!Array.isArray(list) || list.length > MAX_WATCH) return json({ error: `people must be a list of at most ${MAX_WATCH}` }, 400);
  const people: WatchPerson[] = [];
  for (const [i, x] of list.entries()) {
    const p = watchPerson(x);
    if (!p) return json({ error: `people[${i}] must have person (P-n), name, and optional firm, company, officer_id, born (YYYY-MM), feed_url, news, ch` }, 400);
    people.push(p);
  }
  await env.DB.prepare(`INSERT INTO circle_watch(user_id,data_enc,updated) VALUES(?,?,?)
      ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc, updated=excluded.updated`).bind(user.id, await seal(env, people), nowISO()).run();
  return json({ ok: true, people: people.length });
});

/** What was found after `seq` (officer candidates, directorships, appointments, resignations, news, posts). */
route("GET", "/v2/circle/updates", async (req, env, user) => {
  const after = afterOf(req);
  const rows = (await env.DB.prepare(`SELECT seq, key, person, data_enc FROM circle_updates WHERE user_id=? AND seq>? ORDER BY seq LIMIT ${PAGE}`)
    .bind(user.id, after).all<{ seq: number; key: string; person: string; data_enc: string }>()).results;
  const updates = [];
  for (const r of rows) updates.push({ seq: r.seq, key: r.key, person: r.person, ...(await unseal<Update>(env, r.data_enc)) });
  return json({ updates, next: rows.length ? rows[rows.length - 1].seq : after, more: rows.length === PAGE });
});

/** The phone's Circle screen as the Mac made it (stored encrypted, replacing the last one). */
route("PUT", "/v2/circle", async (req, env, user) => {
  const b = await readCappedJSON(req, MAX_COPY_BYTES);
  if (!b.ok) return json({ error: b.tooLarge ? "too large" : "Invalid JSON" }, b.tooLarge ? 413 : 400);
  const copy = (b.body as any)?.copy;
  if (!copy || typeof copy !== "object" || !Array.isArray(copy.people) || !Array.isArray(copy.due)
      || !copy.due.every((d: unknown) => typeof d === "string" && PERSON.test(d))
      || !copy.people.every((p: any) => p && typeof p.id === "string" && PERSON.test(p.id) && typeof p.name === "string")) {
    return json({ error: "copy must have due (P-n ids) and people (each with id and name)" }, 400);
  }
  await env.DB.prepare(`INSERT INTO circle_copy(user_id,data_enc,updated) VALUES(?,?,?)
      ON CONFLICT(user_id) DO UPDATE SET data_enc=excluded.data_enc, updated=excluded.updated`).bind(user.id, await seal(env, copy), nowISO()).run();
  return json({ ok: true });
});

/** The phone's Circle actions the Mac has not taken yet, oldest first. */
route("GET", "/v2/circle/actions", async (_req, env, user) => {
  const rows = (await env.DB.prepare("SELECT id, person, action, made_at FROM circle_actions WHERE user_id=? AND taken=0 ORDER BY received_at, id LIMIT 200")
    .bind(user.id).all()).results;
  return json({ actions: rows });
});

route("POST", "/v2/circle/actions/ack", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const ids = (b.body as any)?.ids;
  if (!Array.isArray(ids) || ids.length > 200 || !ids.every((x) => typeof x === "string" && x.length <= 64)) return json({ error: "ids must be a list of up to 200 ids" }, 400);
  if (ids.length) await env.DB.batch(ids.map((id: string) => env.DB.prepare("UPDATE circle_actions SET taken=1 WHERE user_id=? AND id=?").bind(user.id, id)));
  return json({ ok: true });
});

/** contact_form: fills the add-contact form from header names, addresses and phone numbers (nothing else is read). */
route("POST", "/v2/circle/fill", async (req, env, user) => {
  if (!(await circleOn(env, user.id))) return json({ error: "Circle is off" }, 409);
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const headers = headerBits((b.body as any)?.headers);
  if (!headers.length) return json({ error: "headers must list names, addresses or phone numbers" }, 400);
  const client = await haikuFor(env, user.id, "contact_form", circleFetch());
  if (!client) return json({ error: "Add your Claude key in Settings › Keys to fill the form" }, 409);
  const f = await fillContact(client, headers);
  return f ? json(f) : json({ error: "Claude's answer couldn't be read; fill the form by hand" }, 502);
});

/** draft_message: a short draft in the owner's voice; returned, never sent and never kept. */
route("POST", "/v2/circle/draft", async (req, env, user) => {
  if (!(await circleOn(env, user.id))) return json({ error: "Circle is off" }, 409);
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const d = draftInput(b.body, user.name);
  if (typeof d === "string") return json({ error: d }, 400);
  return draftAnswer(env, user.id, d);
});

export async function draftAnswer(env: Env, userId: string, d: Exclude<ReturnType<typeof draftInput>, string>, setCookie?: string): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json", "Cache-Control": "no-store" };
  if (setCookie) headers["Set-Cookie"] = setCookie;
  const client = await haikuFor(env, userId, "draft_message", circleFetch());
  if (!client) return new Response(JSON.stringify({ error: "Add your Claude key in Settings › Keys to draft messages" }), { status: 409, headers });
  const text = await draftMessage(client, d);
  return text ? new Response(JSON.stringify({ draft: text }), { status: 200, headers })
    : new Response(JSON.stringify({ error: "Claude's answer couldn't be read; try again" }), { status: 502, headers });
}

/** Hourly: metadata the Mac has had for 30 days and actions taken a week ago go. */
export async function purgeCircle(env: Env): Promise<void> {
  const now = Date.parse(nowISO());
  await env.DB.batch([
    env.DB.prepare("DELETE FROM circle_exchanges WHERE received_at < ?").bind(new Date(now - KEEP_EXCHANGES_MS).toISOString()),
    env.DB.prepare("DELETE FROM circle_actions WHERE taken=1 AND received_at < ?").bind(new Date(now - KEEP_TAKEN_MS).toISOString()),
  ]);
}
