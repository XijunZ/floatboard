/**
 * "Link an email": search the user's own connected Gmail inboxes so a task can be linked to an email.
 * `GET /v2/emails/search?q=` (user key, the Mac) and `GET /app/api/emails/search?q=` (session, the phone).
 * The text goes to Gmail as its own `q` search (cleaned, at most 100 characters); each enabled Gmail inbox of this user
 * answers with its newest 10 matches, merged newest first. Only the account, ids, subject, sender and date come back:
 * never the email's text. An inbox that fails is reported in `errors` and never stops the others.
 */
import { type Env, json } from "./env";
import { route } from "./router";
import { gmailSource, SourceAuthError } from "./sources/gmail";
import type { SourceRow } from "./sources/types";
import { appJSON, requireAppSession } from "./app/auth";

export const MAX_QUERY = 100;
export const PER_ACCOUNT = 10;

let gmailFetch: typeof fetch = (i, init) => fetch(i, init);
/** Tests replace Gmail. */
export function setEmailSearchFetch(f: typeof fetch) { gmailFetch = f; }

export type EmailHit = { account: string; gmail_id: string; message_id: string; subject: string; from: string; date: string; sent_at: string | null };
export type EmailSearch = { results: EmailHit[]; errors: { account: string; error: string }[] };

/** The search text with control characters and runs of spaces taken out, at most 100 characters; null when empty. */
export function cleanQuery(q: string | null | undefined): string | null {
  if (typeof q !== "string") return null;
  const s = q.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, MAX_QUERY).trim();
  return s || null;
}

/** Gmail's own message id: letters and digits only. */
export const GMAIL_ID = /^[A-Za-z0-9]{1,64}$/;

export async function searchEmails(env: Env, userId: string, q: string): Promise<EmailSearch> {
  const rows = (await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail' AND enabled=1 ORDER BY created")
    .bind(userId).all<SourceRow>()).results;
  const out: EmailSearch = { results: [], errors: [] };
  const answers = await Promise.allSettled(rows.map((row) => gmailSource(env, row, gmailFetch).search(q, PER_ACCOUNT)));
  answers.forEach((a, i) => {
    const account = rows[i].address;
    if (a.status === "rejected") {
      // Gmail's own error text can carry the search address: only a reconnect message is passed on as it is.
      out.errors.push({ account, error: a.reason instanceof SourceAuthError ? a.reason.message : "Gmail couldn't be searched just now" });
      return;
    }
    for (const m of a.value) {
      if (!m.gmailId || !GMAIL_ID.test(m.gmailId)) continue;
      out.results.push({ account, gmail_id: m.gmailId, message_id: m.messageId, subject: m.subject, from: m.from, date: m.date,
        sent_at: m.sentAt ?? null });
    }
  });
  out.results.sort((x, y) => (y.sent_at ?? "").localeCompare(x.sent_at ?? ""));
  return out;
}

route("GET", "/v2/emails/search", async (req, env, user) => {
  const q = cleanQuery(new URL(req.url).searchParams.get("q"));
  if (!q) return json({ error: "q is required" }, 400);
  return json(await searchEmails(env, user.id, q));
});

/** `GET /app/api/emails/search`; null for any other path. */
export async function handleEmailSearch(req: Request, env: Env): Promise<Response | null> {
  if (new URL(req.url).pathname !== "/app/api/emails/search" || req.method !== "GET") return null;
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "not signed in" }, 401);
  const q = cleanQuery(new URL(req.url).searchParams.get("q"));
  if (!q) return appJSON({ error: "Type something to search for." }, 400, s.setCookie);
  return appJSON(await searchEmails(env, s.userId, q), 200, s.setCookie);
}

/** The user's own Gmail address `account`, exactly as stored (any state), or null when it is not theirs. */
export async function ownGmail(env: Env, userId: string, account: string): Promise<string | null> {
  const r = await env.DB.prepare("SELECT address FROM sources WHERE user_id=? AND kind='gmail' AND address=?").bind(userId, account).first<{ address: string }>();
  return r?.address ?? null;
}
