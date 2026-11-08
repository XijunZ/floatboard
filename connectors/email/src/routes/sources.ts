import { encrypt } from "../crypto";
import { type Env, nowISO } from "../env";
import { randomToken } from "../auth";

const hookURL = (req: Request, hookId: string) => `${new URL(req.url).origin}/hooks/fathom/${hookId}`;

/** The user's private Fathom webhook address, created on first use (one per user). */
export async function ensureFathomHook(env: Env, req: Request, userId: string): Promise<{ id: string; hook_url: string }> {
  const existing = await env.DB.prepare("SELECT id, hook_id FROM sources WHERE user_id=? AND kind='fathom'").bind(userId)
    .first<{ id: string; hook_id: string }>();
  if (existing) return { id: existing.id, hook_url: hookURL(req, existing.hook_id) };
  const id = crypto.randomUUID(), hookId = randomToken(32);
  await env.DB.prepare("INSERT INTO sources(id,user_id,kind,address,hook_id,enabled,created) VALUES(?,?, 'fathom', 'Fathom', ?, 1, ?)")
    .bind(id, userId, hookId, nowISO()).run();
  return { id, hook_url: hookURL(req, hookId) };
}

/** The existing Fathom address, or null (never creates one). */
export async function fathomHookURL(env: Env, req: Request, userId: string): Promise<string | null> {
  const r = await env.DB.prepare("SELECT hook_id FROM sources WHERE user_id=? AND kind='fathom'").bind(userId).first<{ hook_id: string }>();
  return r?.hook_id ? hookURL(req, r.hook_id) : null;
}

/** Save (or reconnect) a Gmail inbox: refresh token and client secret encrypted; clears the last error. */
export async function upsertGmail(env: Env, userId: string, g: { address: string; refresh_token: string; client_id: string; client_secret: string }): Promise<string> {
  const existing = await env.DB.prepare("SELECT id FROM sources WHERE user_id=? AND kind='gmail' AND address=?")
    .bind(userId, g.address).first<{ id: string }>();
  const id = existing?.id ?? crypto.randomUUID();
  const refresh = await encrypt(env, g.refresh_token);
  const secret = await encrypt(env, g.client_secret);
  if (existing) {
    await env.DB.prepare("UPDATE sources SET refresh_enc=?, client_id=?, client_secret_enc=?, enabled=1, last_error=NULL WHERE id=?")
      .bind(refresh, g.client_id, secret, id).run();
  } else {
    await env.DB.prepare(`INSERT INTO sources(id,user_id,kind,address,refresh_enc,client_id,client_secret_enc,enabled,created)
                          VALUES(?,?,'gmail',?,?,?,?,1,?)`)
      .bind(id, userId, g.address, refresh, g.client_id, secret, nowISO()).run();
  }
  return id;
}

// ---- Gmail OAuth web flow (used by /setup) with the user's own Google Cloud *Web application* client ----

export const GOOGLE_SCOPES = "https://www.googleapis.com/auth/gmail.modify openid email";
export const googleRedirectURI = (origin: string) => `${origin}/setup/google/callback`;

let googleFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace Google's token endpoint. */
export function setGoogleFetch(f: typeof fetch) { googleFetch = f; }

export function googleAuthURL(origin: string, clientId: string, state: string, loginHint?: string | null): string {
  const q = new URLSearchParams({
    client_id: clientId, redirect_uri: googleRedirectURI(origin), response_type: "code", scope: GOOGLE_SCOPES,
    access_type: "offline", prompt: "consent", include_granted_scopes: "true", state,
  });
  if (loginHint) q.set("login_hint", loginHint);
  return `https://accounts.google.com/o/oauth2/v2/auth?${q}`;
}

/**
 * Exchange an authorization code (one outgoing call). The address comes from the id_token in Google's own token response
 * (received directly from Google over TLS, so its signature needn't be checked). Errors carry no secrets.
 */
export async function exchangeGoogleCode(origin: string, clientId: string, clientSecret: string, code: string):
  Promise<{ ok: true; address: string; refresh_token: string } | { ok: false; error: string }> {
  let r: Response;
  try {
    r = await googleFetch("https://oauth2.googleapis.com/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ code, client_id: clientId, client_secret: clientSecret, redirect_uri: googleRedirectURI(origin), grant_type: "authorization_code" }),
    });
  } catch (e) { return { ok: false, error: `Google could not be reached (${(e as Error)?.message ?? e})`.slice(0, 300) }; }
  const j = await r.json<{ refresh_token?: string; id_token?: string; error?: string; error_description?: string }>().catch(() => ({} as any));
  if (!r.ok) return { ok: false, error: `Google refused the sign-in (${r.status}${j.error ? `: ${String(j.error).slice(0, 80)}` : ""})` };
  if (!j.refresh_token) return { ok: false, error: "Google returned no refresh token. Remove FloatBoard's access in your Google account and connect again." };
  let address = "";
  try {
    const part = String(j.id_token ?? "").split(".")[1] ?? "";
    // base64url → bytes → UTF-8 (atob alone yields Latin-1 characters and garbles non-ASCII addresses).
    const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((part.length + 3) % 4));
    const claims = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0))));
    address = String(claims.email ?? "").trim().toLowerCase();
  } catch { /* handled below */ }
  if (!address || address.length > 320) return { ok: false, error: "Google didn't say which address was connected." };
  return { ok: true, address, refresh_token: j.refresh_token };
}
