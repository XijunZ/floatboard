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

const MAX = 500;

/** Which keys this engine holds for the user (never the keys themselves). */
export async function keyStatus(env: Env, userId: string) {
  const u = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(userId).first<{ anthropic_key_enc: string | null }>();
  const g = await env.DB.prepare("SELECT client_id FROM google_clients WHERE user_id=?").bind(userId).first<{ client_id: string }>();
  return { claude: !!u?.anthropic_key_enc, google_client_id: g?.client_id ?? null };
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : undefined);

/**
 * Body: any of `claude_key` (string; "" removes it), `google_client` ({client_id, client_secret}; null removes it).
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
  if (!stmts.length) return json({ error: "nothing to change: send claude_key and/or google_client" }, 400);
  stmts.push(logEvent(env, { run_id: "keys", user_id: user.id, decision: "keys", detail: changed.join("; ") }));
  await env.DB.batch(stmts);
  return json({ ok: true, keys: await keyStatus(env, user.id) });
});

/** The shared rulebooks every engine uses (read-only in the app). */
route("GET", "/v2/rulebook", async () => json({
  rulebooks: [
    { key: "email", name: "Email", text: SKILL },
    { key: "chat", name: "WhatsApp and chats", text: CHAT_SKILL },
  ],
}));
