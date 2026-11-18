/**
 * The phone's Circle screen (features §10): `GET /app/api/circle` (the Mac's copy plus how many of this account's actions
 * wait for the Mac), `POST /app/api/circle/action` (I contacted them / We talked / Snooze, from the screen, Plan or a
 * notification button; each id once) and `POST /app/api/circle/draft` (a Haiku draft from the card's notes and, when the
 * person has an email address and a Gmail inbox is connected, the last few emails with them; nothing is kept).
 */
import type { Env } from "../env";
import { nowISO } from "../env";
import { readCappedJSON } from "../lib/http";
import { accountMarker, appJSON, requireAppSession, sameOrigin } from "./auth";
import { circleOn, unseal } from "../circle/common";
import { circleFetch } from "../circle/net";
import { draftInput } from "../circle/ai";
import { CIRCLE_ACTIONS, draftAnswer } from "../routes/circle";
import { GmailSource } from "../sources/gmail";
import type { SourceRow } from "../sources/types";

const ID = /^[A-Za-z0-9-]{8,64}$/;
const PERSON = /^P-\d{1,12}$/;
const MAX_BATCH = 50;

type CopyPerson = { id: string; name: string; email?: string | null; language?: string; notes?: string };

export async function handleCircleApp(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (path === "/app/api/circle" && req.method === "GET") {
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const row = await env.DB.prepare("SELECT data_enc, updated FROM circle_copy WHERE user_id=?").bind(s.userId).first<{ data_enc: string; updated: string }>();
    const pending = await env.DB.prepare("SELECT count(*) AS n FROM circle_actions WHERE user_id=? AND taken=0").bind(s.userId).first<{ n: number }>();
    // `account`: the phone drops an answer that arrives after it signed out or switched account.
    return appJSON({ account: await accountMarker(s.userId), copy: row ? await unseal(env, row.data_enc) : null, updated: row?.updated ?? null,
      pending: pending?.n ?? 0 }, 200, s.setCookie);
  }
  if (path === "/app/api/circle/action" && req.method === "POST") {
    if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    const b = await readCappedJSON(req, 32_000);
    if (!b.ok) return appJSON({ error: "Invalid JSON" }, 400, s.setCookie);
    // A notification button names the account its reminder came from: tapped after switching account, it is refused.
    const from = (b.body as any)?.account;
    if (from !== undefined && from !== await accountMarker(s.userId)) return appJSON({ error: "This alert belongs to another account" }, 409, s.setCookie);
    const list = (b.body as any)?.actions;
    if (!Array.isArray(list) || list.length > MAX_BATCH) return appJSON({ error: `actions must be a list of at most ${MAX_BATCH}` }, 400, s.setCookie);
    const accepted: string[] = [], dropped: { id: string | null; reason: string }[] = [];
    const stmts: D1PreparedStatement[] = [];
    const now = nowISO();
    for (const a of list) {
      const id = typeof a?.id === "string" && ID.test(a.id) ? a.id : null;
      const made = typeof a?.made_at === "string" && !Number.isNaN(Date.parse(a.made_at)) ? new Date(Math.min(Date.parse(a.made_at), Date.now())).toISOString() : null;
      if (!id || !made || typeof a.person !== "string" || !PERSON.test(a.person) || !(CIRCLE_ACTIONS as readonly string[]).includes(a.action)) {
        dropped.push({ id, reason: "not a Circle action" });
        continue;
      }
      stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO circle_actions(user_id,id,device_id,person,action,made_at,received_at) VALUES(?,?,?,?,?,?,?)`)
        .bind(s.userId, id, s.deviceId, a.person, a.action, made, now));
      accepted.push(id);
    }
    if (stmts.length) await env.DB.batch(stmts);
    return appJSON({ accepted, dropped }, 200, s.setCookie);
  }
  if (path === "/app/api/circle/draft" && req.method === "POST") {
    if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
    const s = await requireAppSession(req, env);
    if (!s) return appJSON({ error: "not signed in" }, 401);
    if (!(await circleOn(env, s.userId))) return appJSON({ error: "Circle is off" }, 409, s.setCookie);
    const b = await readCappedJSON(req, 4_000);
    const person = b.ok ? (b.body as any)?.person : null;
    if (typeof person !== "string" || !PERSON.test(person)) return appJSON({ error: "person must be a P-n id" }, 400, s.setCookie);
    const row = await env.DB.prepare("SELECT data_enc FROM circle_copy WHERE user_id=?").bind(s.userId).first<{ data_enc: string }>();
    const copy = row ? await unseal<{ people: CopyPerson[] }>(env, row.data_enc) : null;
    const p = copy?.people.find((x) => x.id === person);
    if (!p) return appJSON({ error: "That person isn't on this phone yet; open FloatBoard on the Mac" }, 404, s.setCookie);
    const owner = await env.DB.prepare("SELECT name FROM users WHERE id=?").bind(s.userId).first<{ name: string }>();
    const d = draftInput({ name: p.name, language: p.language, notes: p.notes, channel: p.email ? "email" : "whatsapp",
      messages: p.email ? await lastEmails(env, s.userId, p.email) : [] }, owner?.name ?? "");
    if (typeof d === "string") return appJSON({ error: d }, 400, s.setCookie);
    return draftAnswer(env, s.userId, d, s.setCookie);
  }
  return null;
}

/** The last 3 emails with this address in the first connected Gmail inbox (text for the draft only; nothing is kept). */
async function lastEmails(env: Env, userId: string, address: string): Promise<{ direction: string; at: string; text: string }[]> {
  const row = await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1 LIMIT 1").bind(userId).first<SourceRow>();
  if (!row || !/^[^@\s"]+@[^@\s"]+$/.test(address)) return [];
  try {
    const g = new GmailSource(env, row, circleFetch());
    const hits = await g.search(`from:${address} OR to:${address}`, 3);
    const out = [];
    for (const h of hits.reverse()) {
      if (!h.gmailId) continue;
      const t = await g.readText(h.gmailId);
      out.push({ direction: h.from.toLowerCase().includes(address.toLowerCase()) ? "in" : "out", at: h.sentAt ?? "", text: t.text.slice(0, 1000) });
    }
    return out;
  } catch { return []; }   // the draft still works from the notes alone
}
