/**
 * Keys from the Mac (docs/architecture.md, Edition 2, C9): the Mac keeps every key in its Keychain and sends this
 * engine the ones it needs. Sent over HTTPS with the user key; stored encrypted (ENC_KEY), as the setup page did.
 * The engine never sends a key back: the Mac only learns whether each one is set.
 * Also the shared rulebooks, read-only, for Settings › Rules & learning.
 */
import { type Env, json, nowISO } from "../env";
import { encrypt } from "../lib/crypto";
import { readJSON } from "../lib/http";
import { route } from "../lib/router";
import { logEvent } from "../lib/runlog";
import { CHAT_SKILL, SKILL } from "../triage/classify";
import { ensureFathomHook, upsertGmail } from "./sources";
import DECISIONS_SKILL from "../skills/decisions.md";

const MAX = 500;

/** Which keys this engine holds for the user (never the keys themselves). */
export async function keyStatus(env: Env, userId: string) {
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  const g = await env.DB.prepare("SELECT client_id FROM google_clients WHERE user_id=?").bind(userId).first<{ client_id: string }>();
  const f = await env.DB.prepare("SELECT 1 AS x FROM sources WHERE user_id=? AND kind='fathom' AND fathom_key_enc IS NOT NULL").bind(userId).first();
  return { claude: !!u?.anthropic_key_enc, google_client_id: g?.client_id ?? null, fathom: !!f };
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : undefined);

/**
 * Body: any of `claude_key` (string; "" removes it), `google_client` ({client_id, client_secret}; null removes it),
 * `fathom_key` (string; "" removes it: the hourly catch-up that also works without the webhook, e.g. on a Mac).
 * Keys not given are left as they are. Returns the key status.
 */
route("PUT", "/v2/keys", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const body = b.body as Record<string, unknown>;
  const changed: string[] = [];
  const stmts: D1PreparedStatement[] = [];
  if ("claude_key" in body) {
    const k = str(body.claude_key);
    if (k === undefined || k.length > MAX) return json({ error: "claude_key must be text (at most 500 characters)" }, 400);
    stmts.push(env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(k ? await encrypt(env, k) : null, user.id));
    changed.push(k ? "Claude key saved" : "Claude key removed");
  }
  if ("google_client" in body) {
    const g = body.google_client;
    if (g === null) {
      stmts.push(env.DB.prepare("DELETE FROM google_clients WHERE user_id=?").bind(user.id));
      changed.push("Google client removed");
    } else {
      const id = str((g as any)?.client_id), secret = str((g as any)?.client_secret);
      if (!id || !secret || id.length > 300 || secret.length > 300) {
        return json({ error: "google_client needs client_id and client_secret (each at most 300 characters)" }, 400);
      }
      stmts.push(env.DB.prepare(`INSERT INTO google_clients(user_id,client_id,client_secret_enc,updated) VALUES(?,?,?,?)
          ON CONFLICT(user_id) DO UPDATE SET client_id=excluded.client_id, client_secret_enc=excluded.client_secret_enc, updated=excluded.updated`)
        .bind(user.id, id, await encrypt(env, secret), nowISO()));
      changed.push("Google client saved");
    }
  }
  if ("fathom_key" in body) {
    const k = str(body.fathom_key);
    if (k === undefined || k.length > 300 || /\s/.test(k) || (k && k.length < 10)) return json({ error: "fathom_key must be the key Fathom gave you" }, 400);
    if (k) await ensureFathomHook(env, req, user.id);
    stmts.push(env.DB.prepare("UPDATE sources SET fathom_key_enc=?, last_error=NULL WHERE user_id=? AND kind='fathom'").bind(k ? await encrypt(env, k) : null, user.id));
    changed.push(k ? "Fathom key saved" : "Fathom key removed");
  }
  if (!stmts.length) return json({ error: "nothing to change: send claude_key, google_client and/or fathom_key" }, 400);
  stmts.push(logEvent(env, { run_id: "keys", user_id: user.id, decision: "keys", detail: changed.join("; ") }));
  await env.DB.batch(stmts);
  return json({ ok: true, keys: await keyStatus(env, user.id) });
});

/**
 * A Gmail inbox signed in on the Mac (Settings › Inputs › Gmail): the Mac does Google's sign-in with your Google
 * client and sends the result here, so no redirect address or second client is needed. Body: {address, refresh_token,
 * client_id, client_secret}. The engine checks the sign-in works (one token refresh) before keeping it.
 */
route("POST", "/v2/gmail", async (req, env, user) => {
  const b = await readJSON(req);
  if (!b.ok) return b.res;
  const o = b.body as Record<string, unknown>;
  const address = str(o.address)?.toLowerCase(), refresh = str(o.refresh_token), id = str(o.client_id), secret = str(o.client_secret);
  if (!address || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address) || address.length > 200) return json({ error: "address must be an email address" }, 400);
  if (!refresh || !id || !secret || refresh.length > 1000 || id.length > 300 || secret.length > 300) {
    return json({ error: "refresh_token, client_id and client_secret are required" }, 400);
  }
  const check = await gmailFetch("https://oauth2.googleapis.com/token", { method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: id, client_secret: secret, refresh_token: refresh, grant_type: "refresh_token" }) });
  if (!check.ok) return json({ error: `Google didn't accept this sign-in (${check.status}); sign in again` }, 400);
  const sid = await upsertGmail(env, user.id, { address, refresh_token: refresh, client_id: id, client_secret: secret });
  await logEvent(env, { run_id: "keys", user_id: user.id, decision: "gmail", detail: `Gmail connected from the Mac: ${address}` }).run();
  return json({ ok: true, id: sid });
});

let gmailFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace Google's token endpoint. */
export function setKeysGoogleFetch(f: typeof fetch) { gmailFetch = f; }

/** The shared rulebooks every engine uses (read-only in the app). */
route("GET", "/v2/rulebook", async () => json({
  rulebooks: [
    { key: "email", name: "Email", text: SKILL },
    { key: "chat", name: "WhatsApp and chats", text: CHAT_SKILL },
    { key: "decisions", name: "Decisions", text: DECISIONS_SKILL },
  ],
}));
