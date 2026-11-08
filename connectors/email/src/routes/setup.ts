/**
 * The engine's setup page (/setup): secrets and connections only — the user's Google Cloud Web client, Gmail accounts
 * (OAuth web flow), Claude key (write-only), Telegram link, Fathom webhook address, Outlook extension token — and the "Connect to FloatBoard"
 * link. /setup/admin creates invites. Rules, groups and lists are authored in the FloatBoard app, not here.
 *
 * Security: sign-in with the user key (or ADMIN_KEY) → random session id in an HttpOnly, Secure, SameSite=Strict cookie
 * scoped to /setup for one hour, stored only hashed. Every POST needs the session's CSRF token and is refused when the
 * browser says it came from another site. Sign-in is rate-limited per IP. Every outcome is written to setup_log; secrets
 * are never logged or shown again.
 */
import { insertUser, randomToken, sameSecret, sha256Hex, userByKey } from "../auth";
import { decrypt, encrypt } from "../crypto";
import { type Env, nowISO } from "../env";
import {
  adminPage, dashboardPage, htmlResponse, messagePage, notFoundPage, redirect, signInPage, type Dashboard, type GmailRow, type OutlookStatus,
} from "../setup/page";
import { isWebhookSecret } from "../sources/fathom";
import { fathomKeyWorks } from "../sources/fathomCatchup";
import { ensureFathomHook, exchangeGoogleCode, fathomHookURL, googleAuthURL, upsertGmail } from "./sources";
import { newTelegramLink } from "../telegram";
import { issueOutlookToken } from "../outlook";

const COOKIE = "fb_setup";
const NONCE_COOKIE = "fb_oauth";
const SESSION_SECONDS = 3600;
const STATE_SECONDS = 600;
const RATE_WINDOW_MS = 15 * 60_000;
const RATE_MAX_FAILURES = 10;

type Session = { kind: "user" | "admin"; user_id: string | null; csrf: string; key_enc: string | null; idHash: string };

const ipOf = (req: Request) => req.headers.get("CF-Connecting-IP") ?? "unknown";
const inSeconds = (s: number) => new Date(Date.now() + s * 1000).toISOString();
const sessionCookie = (sid: string) => `${COOKIE}=${sid}; HttpOnly; Secure; SameSite=Strict; Path=/setup; Max-Age=${SESSION_SECONDS}`;
const clearCookie = `${COOKIE}=; HttpOnly; Secure; SameSite=Strict; Path=/setup; Max-Age=0`;
/** Browser binding for the OAuth state. Lax (not Strict) so it is sent on the top-level redirect back from Google. */
const nonceCookie = (nonce: string) => `${NONCE_COOKIE}=${nonce}; HttpOnly; Secure; SameSite=Lax; Path=/setup/google/callback; Max-Age=${STATE_SECONDS}`;
const clearNonceCookie = `${NONCE_COOKIE}=; HttpOnly; Secure; SameSite=Lax; Path=/setup/google/callback; Max-Age=0`;

/** Record a setup outcome. Never pass secrets in `detail`. A failure to record is itself reported, not swallowed. */
async function record(env: Env, req: Request, action: string, ok: boolean, userId: string | null, detail?: string) {
  try {
    await env.DB.prepare("INSERT INTO setup_log(at,user_id,ip,action,ok,detail) VALUES(?,?,?,?,?,?)")
      .bind(nowISO(), userId, ipOf(req), action, ok ? 1 : 0, detail ? detail.slice(0, 500) : null).run();
  } catch (e) {
    console.warn(JSON.stringify({ event: "setup_log_failed", action, ok, error: (e as Error)?.message }));
  }
}

function cookieValue(req: Request, name = COOKIE): string | null {
  for (const part of (req.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=") || null;
  }
  return null;
}

/**
 * Delete expired setup sessions (with their encrypted user keys), OAuth states and day-old sign-in attempts.
 * Runs whenever a presented session cookie turns out invalid or expired, at sign-in, and from the hourly cron.
 */
export async function purgeExpiredSetup(env: Env): Promise<void> {
  const now = nowISO();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM setup_sessions WHERE expires <= ?").bind(now),
    env.DB.prepare("DELETE FROM oauth_states WHERE expires <= ?").bind(now),
    env.DB.prepare("DELETE FROM setup_attempts WHERE at < ?").bind(new Date(Date.now() - 24 * 3600_000).toISOString()),
  ]);
}

async function loadSession(req: Request, env: Env): Promise<Session | null> {
  const sid = cookieValue(req);
  if (!sid) return null;
  if (sid.length > 200) { await purgeExpiredSetup(env); return null; }
  const idHash = await sha256Hex(sid);
  const row = await env.DB.prepare("SELECT kind, user_id, csrf, key_enc FROM setup_sessions WHERE id_hash=? AND expires > ?")
    .bind(idHash, nowISO()).first<Omit<Session, "idHash">>();
  if (!row) await purgeExpiredSetup(env);
  return row ? { ...row, idHash } : null;
}

async function createSession(env: Env, kind: "user" | "admin", userId: string | null, key: string | null): Promise<string> {
  const sid = randomToken(32);
  const now = nowISO();
  await purgeExpiredSetup(env);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO setup_sessions(id_hash,kind,user_id,csrf,key_enc,expires,created) VALUES(?,?,?,?,?,?,?)")
      .bind(await sha256Hex(sid), kind, userId, randomToken(32), key ? await encrypt(env, key) : null, inSeconds(SESSION_SECONDS), now),
  ]);
  return sid;
}

/** A POST the browser marks as coming from another site (Sec-Fetch-Site / Origin) is refused outright. */
function crossSite(req: Request): boolean {
  const site = req.headers.get("Sec-Fetch-Site");
  if (site && site !== "same-origin" && site !== "none") return true;
  const origin = req.headers.get("Origin");
  // With Referrer-Policy no-referrer, browsers send "Origin: null" on same-origin form posts; that is allowed (the
  // CSRF token still has to match).
  return !!origin && origin !== "null" && origin !== new URL(req.url).origin;
}

async function readForm(req: Request): Promise<Record<string, string>> {
  const type = req.headers.get("Content-Type") ?? "";
  if (!type.startsWith("application/x-www-form-urlencoded")) return {};
  const text = await req.text();
  if (text.length > 20_000) return {};
  return Object.fromEntries(new URLSearchParams(text));
}

async function tooManyFailures(env: Env, ip: string): Promise<boolean> {
  const since = new Date(Date.now() - RATE_WINDOW_MS).toISOString();
  const r = await env.DB.prepare("SELECT COUNT(*) n FROM setup_attempts WHERE ip=? AND ok=0 AND at > ?").bind(ip, since).first<{ n: number }>();
  return (r?.n ?? 0) >= RATE_MAX_FAILURES;
}

const attempt = (env: Env, ip: string, ok: boolean, kind: string) =>
  env.DB.prepare("INSERT INTO setup_attempts(ip,at,ok,kind) VALUES(?,?,?,?)").bind(ip, nowISO(), ok ? 1 : 0, kind).run();

// ---------------------------------------------------------------- user pages

async function dashboard(req: Request, env: Env, s: Session, extra: Partial<Dashboard> = {}, status = 200): Promise<Response> {
  const userId = s.user_id!;
  const origin = new URL(req.url).origin;
  const [u, client, gmail] = await Promise.all([
    env.DB.prepare("SELECT name, anthropic_key_enc, telegram_chat_id FROM users WHERE id=?").bind(userId)
      .first<{ name: string; anthropic_key_enc: string | null; telegram_chat_id: string | null }>(),
    env.DB.prepare("SELECT client_id FROM google_clients WHERE user_id=?").bind(userId).first<{ client_id: string }>(),
    env.DB.prepare("SELECT id, address, enabled, last_error, last_run FROM sources WHERE user_id=? AND kind='gmail' ORDER BY created").bind(userId).all<GmailRow>(),
  ]);
  let connectLink: string | null = null;
  if (s.key_enc) {
    try {
      const key = await decrypt(env, s.key_enc);
      connectLink = `floatboard://connect?url=${encodeURIComponent(origin)}&key=${encodeURIComponent(key)}&name=Email`;
    } catch {
      await record(env, req, "connect_link", false, userId, "session key could not be decrypted");
    }
  }
  return htmlResponse(dashboardPage({
    name: u?.name ?? "", csrf: s.csrf, origin, connectLink, googleClientId: client?.client_id ?? null, gmail: gmail.results,
    hasClaudeKey: !!u?.anthropic_key_enc, telegramLinked: !!u?.telegram_chat_id, fathomURL: await fathomHookURL(env, req, userId),
    fathomSecretSaved: !!(await env.DB.prepare("SELECT 1 FROM sources WHERE user_id=? AND kind='fathom' AND hook_secret_enc IS NOT NULL")
      .bind(userId).first()),
    fathomKeySaved: !!(await env.DB.prepare("SELECT 1 FROM sources WHERE user_id=? AND kind='fathom' AND fathom_key_enc IS NOT NULL")
      .bind(userId).first()),
    outlook: await env.DB.prepare("SELECT address, enabled, last_error, last_run FROM sources WHERE user_id=? AND kind='outlook_web'")
      .bind(userId).first<OutlookStatus>(),
    ...extra,
  }), status);
}

async function signIn(req: Request, env: Env, admin: boolean): Promise<Response> {
  const ip = ipOf(req);
  const action = admin ? "admin_signin" : "signin";
  if (crossSite(req)) {
    await record(env, req, action, false, null, "cross-site sign-in refused");
    return htmlResponse(signInPage({ admin, error: "That sign-in didn't come from this page." }), 403);
  }
  if (await tooManyFailures(env, ip)) {
    await record(env, req, action, false, null, "rate limited");
    return htmlResponse(signInPage({ admin, error: "Too many failed sign-ins from this network. Try again in 15 minutes." }), 429);
  }
  const key = ((await readForm(req)).key ?? "").trim();
  if (admin) {
    if (!sameSecret(key, env.ADMIN_KEY)) {
      await attempt(env, ip, false, "admin");
      await record(env, req, action, false, null, "wrong admin key");
      return htmlResponse(signInPage({ admin, error: "That admin key isn't right." }), 401);
    }
    await attempt(env, ip, true, "admin");
    const sid = await createSession(env, "admin", null, null);
    await record(env, req, action, true, null);
    return redirect("/setup/admin", { "Set-Cookie": sessionCookie(sid) });
  }
  const user = key.length <= 200 ? await userByKey(env, key) : null;
  if (!user) {
    await attempt(env, ip, false, "user");
    await record(env, req, action, false, null, "unknown key");
    return htmlResponse(signInPage({ error: "That key isn't right." }), 401);
  }
  await attempt(env, ip, true, "user");
  const sid = await createSession(env, "user", user.id, key);
  await record(env, req, action, true, user.id);
  return redirect("/setup", { "Set-Cookie": sessionCookie(sid) });
}

/** Session + CSRF gate for a POST. Returns the session and the form, or the refusal to send. */
async function guardPost(req: Request, env: Env, kind: "user" | "admin"):
  Promise<{ ok: true; s: Session; f: Record<string, string> } | { ok: false; res: Response }> {
  const s = await loadSession(req, env);
  if (!s || s.kind !== kind) {
    await record(env, req, "unauthenticated", false, null, new URL(req.url).pathname);
    return { ok: false, res: htmlResponse(kind === "admin" ? signInPage({ admin: true, error: "Sign in first." }) : signInPage({ error: "Your session ended. Sign in again." }), 401) };
  }
  const f = await readForm(req);
  if (crossSite(req) || !sameSecret(f.csrf ?? "", s.csrf)) {
    await record(env, req, "csrf", false, s.user_id, `refused ${new URL(req.url).pathname}`);
    return { ok: false, res: htmlResponse(messagePage("Refused", "That request didn't come from this page. Reload the setup page and try again.", { back: kind === "admin" ? "/setup/admin" : "/setup" }), 403) };
  }
  return { ok: true, s, f };
}

async function googleStart(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const s = await loadSession(req, env);
  if (!s || s.kind !== "user") {
    await record(env, req, "google_start", false, null, "no session");
    return htmlResponse(signInPage({ error: "Your session ended. Sign in again." }), 401);
  }
  if (crossSite(req) || !sameSecret(url.searchParams.get("csrf") ?? "", s.csrf)) {
    await record(env, req, "csrf", false, s.user_id, "refused /setup/google/start");
    return htmlResponse(messagePage("Refused", "That link didn't come from this page. Reload the setup page and try again."), 403);
  }
  const client = await env.DB.prepare("SELECT client_id FROM google_clients WHERE user_id=?").bind(s.user_id).first<{ client_id: string }>();
  if (!client) {
    await record(env, req, "google_start", false, s.user_id, "no Google Cloud client saved");
    return dashboard(req, env, s, { error: "Save your Google Cloud client first." }, 400);
  }
  const state = randomToken(32), nonce = randomToken(32);
  await env.DB.prepare("INSERT INTO oauth_states(state_hash,user_id,nonce_hash,expires,created) VALUES(?,?,?,?,?)")
    .bind(await sha256Hex(state), s.user_id, await sha256Hex(nonce), inSeconds(STATE_SECONDS), nowISO()).run();
  const hint = (url.searchParams.get("hint") ?? "").slice(0, 320) || null;
  await record(env, req, "google_start", true, s.user_id, hint ? `reconnect ${hint}` : undefined);
  return redirect(googleAuthURL(url.origin, client.client_id, state, hint), { "Set-Cookie": nonceCookie(nonce) });
}

/**
 * Google → engine. The SameSite=Strict session cookie isn't sent on this cross-site arrival, so the user comes from the
 * state: random, single-use (deleted as it's read), bound to the user who started the flow, valid for 10 minutes, and
 * bound to the browser that started it (the SameSite=Lax nonce cookie must hash to the stored nonce_hash).
 */
async function googleCallback(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const state = url.searchParams.get("state") ?? "";
  const fail = async (status: number, userId: string | null, why: string, shown: string) => {
    await record(env, req, "google_callback", false, userId, why);
    return htmlResponse(messagePage("Gmail not connected", shown), status, { "Set-Cookie": clearNonceCookie });
  };
  if (!state || state.length > 200) return fail(400, null, "missing state", "This sign-in link isn't valid. Start again from the setup page.");
  const row = await env.DB.prepare("DELETE FROM oauth_states WHERE state_hash=? RETURNING user_id, nonce_hash, expires")
    .bind(await sha256Hex(state)).first<{ user_id: string; nonce_hash: string | null; expires: string }>();
  if (!row) return fail(400, null, "unknown or already used state", "This sign-in link isn't valid or was already used. Start again from the setup page.");
  if (row.expires <= nowISO()) return fail(400, row.user_id, "state expired", "This sign-in took longer than 10 minutes. Start again from the setup page.");
  const nonce = cookieValue(req, NONCE_COOKIE) ?? "";
  if (!row.nonce_hash || !nonce || nonce.length > 200 || !sameSecret(await sha256Hex(nonce), row.nonce_hash)) {
    return fail(400, row.user_id, "state not started in this browser (nonce missing or mismatched)",
      "This sign-in was started in a different browser or window. Start again from the setup page in this browser.");
  }
  const gErr = url.searchParams.get("error");
  if (gErr) return fail(400, row.user_id, `Google returned ${gErr.slice(0, 80)}`, "Google sign-in was cancelled or refused. Nothing was changed.");
  const code = url.searchParams.get("code");
  if (!code) return fail(400, row.user_id, "no code", "Google didn't return a sign-in code. Start again from the setup page.");
  const client = await env.DB.prepare("SELECT client_id, client_secret_enc FROM google_clients WHERE user_id=?").bind(row.user_id)
    .first<{ client_id: string; client_secret_enc: string }>();
  if (!client) return fail(400, row.user_id, "no Google Cloud client saved", "Save your Google Cloud client first.");
  const secret = await decrypt(env, client.client_secret_enc);
  const ex = await exchangeGoogleCode(url.origin, client.client_id, secret, code);
  if (!ex.ok) return fail(502, row.user_id, ex.error, ex.error);
  await upsertGmail(env, row.user_id, { address: ex.address, refresh_token: ex.refresh_token, client_id: client.client_id, client_secret: secret });
  await record(env, req, "google_callback", true, row.user_id, `connected ${ex.address}`);
  return htmlResponse(messagePage("Gmail connected", `${ex.address} is connected. FloatBoard will start reading it within the hour.`, { ok: true }),
    200, { "Set-Cookie": clearNonceCookie });
}

async function userPost(req: Request, env: Env, path: string): Promise<Response> {
  const g = await guardPost(req, env, "user");
  if (!g.ok) return g.res;
  const { s, f } = g;
  const userId = s.user_id!;
  switch (path) {
    case "/setup/signout": {
      await env.DB.prepare("DELETE FROM setup_sessions WHERE id_hash=?").bind(s.idHash).run();
      await record(env, req, "signout", true, userId);
      return redirect("/setup", { "Set-Cookie": clearCookie });
    }
    case "/setup/google/client": {
      const clientId = (f.client_id ?? "").trim(), secret = (f.client_secret ?? "").trim();
      if (!clientId || clientId.length > 300 || secret.length > 300) {
        await record(env, req, "google_client", false, userId, "invalid client id");
        return dashboard(req, env, s, { error: "Enter the client ID from Google Cloud." }, 400);
      }
      if (secret) {
        await env.DB.prepare(`INSERT INTO google_clients(user_id,client_id,client_secret_enc,updated) VALUES(?,?,?,?)
            ON CONFLICT(user_id) DO UPDATE SET client_id=excluded.client_id, client_secret_enc=excluded.client_secret_enc, updated=excluded.updated`)
          .bind(userId, clientId, await encrypt(env, secret), nowISO()).run();
      } else {
        const r = await env.DB.prepare("UPDATE google_clients SET client_id=?, updated=? WHERE user_id=?").bind(clientId, nowISO(), userId).run();
        if (!r.meta.changes) {
          await record(env, req, "google_client", false, userId, "no secret given");
          return dashboard(req, env, s, { error: "Enter the client secret too." }, 400);
        }
      }
      await record(env, req, "google_client", true, userId, secret ? "id and secret saved" : "id saved, secret kept");
      return dashboard(req, env, s, { notice: "Google Cloud client saved ✓" });
    }
    case "/setup/gmail/remove": {
      const r = await env.DB.prepare("DELETE FROM sources WHERE id=? AND user_id=? AND kind='gmail' RETURNING address")
        .bind(f.source_id ?? "", userId).first<{ address: string }>();
      if (!r) {
        await record(env, req, "gmail_remove", false, userId, "not found");
        return dashboard(req, env, s, { error: "That Gmail account isn't connected." }, 404);
      }
      await record(env, req, "gmail_remove", true, userId, `removed ${r.address}`);
      return dashboard(req, env, s, { notice: `${r.address} removed.` });
    }
    case "/setup/claude": {
      const key = (f.anthropic_key ?? "").trim();
      if (!key || key.length > 500) {
        await record(env, req, "claude_key", false, userId, "empty or too long");
        return dashboard(req, env, s, { error: "Paste your Claude API key." }, 400);
      }
      await env.DB.prepare("UPDATE users SET anthropic_key_enc=? WHERE id=?").bind(await encrypt(env, key), userId).run();
      await record(env, req, "claude_key", true, userId);
      return dashboard(req, env, s, { notice: "Claude key saved ✓" });
    }
    case "/setup/telegram/unlink": {
      await env.DB.prepare("UPDATE users SET telegram_chat_id=NULL, link_code=NULL WHERE id=?").bind(userId).run();
      await record(env, req, "telegram_unlink", true, userId);
      return dashboard(req, env, s, { notice: "Telegram unlinked. Alerts and missed: messages stop until you link a chat again." });
    }
    case "/setup/telegram": {
      const link = await newTelegramLink(env, userId);
      if (!link) {
        await record(env, req, "telegram_link", false, userId, "engine has no Telegram bot");
        return dashboard(req, env, s, { error: "This engine has no Telegram bot set up." }, 400);
      }
      await record(env, req, "telegram_link", true, userId);
      return dashboard(req, env, s, { telegramURL: link });
    }
    case "/setup/fathom/key": {
      const key = (f.fathom_key ?? "").trim();
      if (key.length < 10 || key.length > 300 || /\s/.test(key)) {
        await record(env, req, "fathom_key", false, userId, "empty or malformed");
        return dashboard(req, env, s, { error: "Paste the API key Fathom gave you." }, 400);
      }
      let works = false;
      try { works = await fathomKeyWorks(key); } catch (e) {
        await record(env, req, "fathom_key", false, userId, `check failed: ${(e as Error)?.message ?? e}`.slice(0, 200));
        return dashboard(req, env, s, { error: "Couldn't reach Fathom to check the key. Try again in a minute." }, 502);
      }
      if (!works) {
        await record(env, req, "fathom_key", false, userId, "rejected by Fathom");
        return dashboard(req, env, s, { error: "Fathom didn't accept that API key." }, 400);
      }
      const r = await env.DB.prepare("UPDATE sources SET fathom_key_enc=?, last_error=NULL WHERE user_id=? AND kind='fathom' RETURNING id")
        .bind(await encrypt(env, key), userId).first();
      if (!r) {
        await record(env, req, "fathom_key", false, userId, "no Fathom address yet");
        return dashboard(req, env, s, { error: "Create the Fathom webhook address first." }, 400);
      }
      await record(env, req, "fathom_key", true, userId);
      return dashboard(req, env, s, { notice: "Fathom API key saved ✓ The engine checks Fathom every hour for meetings the webhook missed." });
    }
    case "/setup/fathom/secret": {
      const secret = (f.fathom_secret ?? "").trim();
      if (!isWebhookSecret(secret)) {
        await record(env, req, "fathom_secret", false, userId, "not a whsec_ secret");
        return dashboard(req, env, s, { error: "Paste the webhook secret Fathom showed you. It starts with whsec_." }, 400);
      }
      const r = await env.DB.prepare("UPDATE sources SET hook_secret_enc=? WHERE user_id=? AND kind='fathom' RETURNING id")
        .bind(await encrypt(env, secret), userId).first();
      if (!r) {
        await record(env, req, "fathom_secret", false, userId, "no Fathom address yet");
        return dashboard(req, env, s, { error: "Create the Fathom webhook address first." }, 400);
      }
      await record(env, req, "fathom_secret", true, userId);
      return dashboard(req, env, s, { notice: "Fathom signing secret saved ✓ Only signed deliveries are accepted now." });
    }
    case "/setup/outlook":
    case "/setup/outlook/rotate": {
      const rotate = path === "/setup/outlook/rotate";
      const exists = await env.DB.prepare("SELECT 1 FROM sources WHERE user_id=? AND kind='outlook_web'").bind(userId).first();
      if (!rotate && exists) {
        await record(env, req, "outlook_create", false, userId, "already exists");
        return dashboard(req, env, s, { notice: "Outlook is already set up. Use New token if you need the token again." });
      }
      if (rotate && !exists) {
        await record(env, req, "outlook_rotate", false, userId, "no Outlook source");
        return dashboard(req, env, s, { error: "Set up Outlook first." }, 400);
      }
      const { token } = await issueOutlookToken(env, userId);
      await record(env, req, rotate ? "outlook_rotate" : "outlook_create", true, userId);
      return dashboard(req, env, s, { outlookToken: token,
        notice: rotate ? "New Outlook token made. The old one no longer works: paste this one in the extension's options." : "Outlook connection created." });
    }
    case "/setup/fathom": {
      await ensureFathomHook(env, req, userId);
      await record(env, req, "fathom_hook", true, userId);
      return dashboard(req, env, s, { notice: "Fathom webhook address ready ✓" });
    }
  }
  return htmlResponse(notFoundPage(), 404);
}

// ---------------------------------------------------------------- admin

async function adminPost(req: Request, env: Env, path: string): Promise<Response> {
  const g = await guardPost(req, env, "admin");
  if (!g.ok) return g.res;
  const { s, f } = g;
  if (path === "/setup/admin/signout") {
    await env.DB.prepare("DELETE FROM setup_sessions WHERE id_hash=?").bind(s.idHash).run();
    await record(env, req, "admin_signout", true, null);
    return redirect("/setup/admin", { "Set-Cookie": clearCookie });
  }
  if (path === "/setup/admin/users") {
    const name = (f.name ?? "").trim();
    if (!name || name.length > 100) {
      await record(env, req, "admin_create_user", false, null, "name missing or too long");
      return htmlResponse(adminPage({ csrf: s.csrf, error: "Enter a name (up to 100 characters)." }), 400);
    }
    const { id, key } = await insertUser(env, name);
    await record(env, req, "admin_create_user", true, id, `invite created for ${name}`);
    const link = `floatboard://connect?url=${encodeURIComponent(new URL(req.url).origin)}&key=${encodeURIComponent(key)}&name=Email`;
    return htmlResponse(adminPage({ csrf: s.csrf, invite: { name, link } }));
  }
  return htmlResponse(notFoundPage(), 404);
}

// ---------------------------------------------------------------- entry

export async function handleSetup(req: Request, env: Env): Promise<Response> {
  const path = new URL(req.url).pathname.replace(/\/+$/, "") || "/setup";
  try {
    if (req.method === "GET") {
      if (path === "/setup") {
        const s = await loadSession(req, env);
        return s?.kind === "user" ? dashboard(req, env, s) : htmlResponse(signInPage());
      }
      if (path === "/setup/admin") {
        const s = await loadSession(req, env);
        return s?.kind === "admin" ? htmlResponse(adminPage({ csrf: s.csrf })) : htmlResponse(signInPage({ admin: true }));
      }
      if (path === "/setup/google/start") return googleStart(req, env);
      if (path === "/setup/google/callback") return googleCallback(req, env);
    } else if (req.method === "POST") {
      if (path === "/setup/signin") return signIn(req, env, false);
      if (path === "/setup/admin/signin") return signIn(req, env, true);
      if (path.startsWith("/setup/admin/")) return adminPost(req, env, path);
      return userPost(req, env, path);
    }
    return htmlResponse(notFoundPage(), 404);
  } catch (e) {
    const msg = `${(e as Error)?.message ?? e}`.slice(0, 300);
    console.warn(JSON.stringify({ event: "setup_crashed", path, error: msg }));
    await record(env, req, "error", false, null, `${path}: ${msg}`);
    return htmlResponse(messagePage("Something went wrong", "The setup page hit an error and nothing may have been saved. Try again."), 500);
  }
}
