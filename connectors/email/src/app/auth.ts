/**
 * Phone app sign-in: pairing codes, passkeys (WebAuthn) and device sessions.
 *
 * - The Mac asks `POST /v2/app/pair` (user key) for a one-time pairing link `<origin>/app/#pair=<code>` (32 random bytes,
 *   stored only as sha256, valid 10 minutes). Making a new code leaves older unexpired codes valid; each still works once.
 * - The phone opens the link and registers a passkey (`/app/api/pair/options|finish`): resident key, user verification
 *   required, attestation "none", ES256 or RS256. A failed verification leaves the code usable; a successful one burns it
 *   atomically, so one code can never make two devices.
 * - A phone without a session signs in with its passkey (`/app/api/login/options|finish`); login challenges live 5
 *   minutes and are used once.
 * - The session is the `fb_session` cookie (32 random bytes, stored as sha256; HttpOnly, Secure, SameSite=Strict,
 *   Path=/app, 90 days, renewed on use when the last renewal is more than a day old).
 *
 * `/app/api/*` never accepts the user key and `/v2/*` never accepts the cookie. Every state-changing `/app/api` POST must
 * carry an `Origin` equal to the engine's own origin (CSRF defence on top of SameSite=Strict).
 */
import {
  generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse,
  type AuthenticatorTransportFuture,
} from "@simplewebauthn/server";
import { randomToken, sha256Hex } from "../auth";
import { type Env, json, nowISO } from "../env";
import { readJSON } from "../http";
import { route } from "../router";

export const SESSION_COOKIE = "fb_session";
export const SESSION_SECONDS = 90 * 86400;
const RENEW_AFTER_MS = 86400_000;
const PAIR_SECONDS = 600;
const CHALLENGE_SECONDS = 300;
/** Unauthenticated login/options calls can't grow the challenge table past this many live rows. */
const MAX_LIVE_CHALLENGES = 2000;
const ALGS = [-7, -257]; // ES256, RS256

export type AppSession = { userId: string; deviceId: string; tokenHash: string; setCookie?: string };

const inSeconds = (s: number) => new Date(Date.now() + s * 1000).toISOString();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (s: string): Uint8Array<ArrayBuffer> => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const str = (v: unknown, max: number) => (typeof v === "string" && v.length > 0 && v.length <= max ? v : null);

export const sessionCookie = (token: string) =>
  `${SESSION_COOKIE}=${token}; HttpOnly; Secure; SameSite=Strict; Path=/app; Max-Age=${SESSION_SECONDS}`;
export const clearSessionCookie = `${SESSION_COOKIE}=; HttpOnly; Secure; SameSite=Strict; Path=/app; Max-Age=0`;

/** A JSON response for /app/api: never cached, optionally carrying a (renewed) session cookie. */
export function appJSON(data: unknown, status = 200, setCookie?: string): Response {
  const headers: Record<string, string> = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  if (setCookie) headers["Set-Cookie"] = setCookie;
  return new Response(JSON.stringify(data), { status, headers });
}

function cookieValue(req: Request, name: string): string | null {
  for (const part of (req.headers.get("Cookie") ?? "").split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=") || null;
  }
  return null;
}

/** True when the request's Origin header is exactly the engine's own origin. */
export function sameOrigin(req: Request): boolean {
  return req.headers.get("Origin") === new URL(req.url).origin;
}

/**
 * The phone's session from its `fb_session` cookie, or null (missing, unknown, expired, or the device was removed).
 * Renews the session (new expiry + `setCookie`) when its last renewal is more than a day old, and records the device as
 * seen. Callers pass `setCookie` on in their response (see `appJSON`).
 */
export async function requireAppSession(req: Request, env: Env): Promise<AppSession | null> {
  const token = cookieValue(req, SESSION_COOKIE);
  if (!token || token.length > 100) return null;
  const tokenHash = await sha256Hex(token);
  const now = nowISO();
  const row = await env.DB.prepare(`SELECT s.user_id, s.device_id, s.expires FROM app_sessions s JOIN app_devices d ON d.id = s.device_id
      WHERE s.token_hash=? AND s.expires > ? AND d.revoked = 0 AND d.user_id = s.user_id`)
    .bind(tokenHash, now).first<{ user_id: string; device_id: string; expires: string }>();
  if (!row) return null;
  // Last renewal = expires - 90 days.
  const renew = Date.parse(row.expires) - SESSION_SECONDS * 1000 < Date.now() - RENEW_AFTER_MS;
  const stmts = [
    env.DB.prepare("UPDATE app_devices SET last_seen=? WHERE id=?").bind(now, row.device_id),
    renew
      ? env.DB.prepare("UPDATE app_sessions SET last_used=?, expires=? WHERE token_hash=?").bind(now, inSeconds(SESSION_SECONDS), tokenHash)
      : env.DB.prepare("UPDATE app_sessions SET last_used=? WHERE token_hash=?").bind(now, tokenHash),
  ];
  await env.DB.batch(stmts);
  return { userId: row.user_id, deviceId: row.device_id, tokenHash, setCookie: renew ? sessionCookie(token) : undefined };
}

/** Create a session for a device; returns the cookie to set. */
async function newSession(env: Env, userId: string, deviceId: string): Promise<string> {
  const token = randomToken(32);
  const now = nowISO();
  await env.DB.prepare("INSERT INTO app_sessions(token_hash,device_id,user_id,created,expires,last_used) VALUES(?,?,?,?,?,?)")
    .bind(await sha256Hex(token), deviceId, userId, now, inSeconds(SESSION_SECONDS), now).run();
  return sessionCookie(token);
}

/**
 * Remove a phone: the device is marked revoked, and its sessions and passkeys are deleted. Returns its name, or null when
 * the user has no such (unrevoked) device. Later features that store per-device data delete it here too.
 */
export async function removeDevice(env: Env, userId: string, deviceId: string): Promise<string | null> {
  const dev = await env.DB.prepare("SELECT name FROM app_devices WHERE id=? AND user_id=? AND revoked=0").bind(deviceId, userId).first<{ name: string }>();
  if (!dev) return null;
  await env.DB.batch([
    env.DB.prepare("UPDATE app_devices SET revoked=1 WHERE id=? AND user_id=?").bind(deviceId, userId),
    env.DB.prepare("DELETE FROM app_sessions WHERE device_id=?").bind(deviceId),
    env.DB.prepare("DELETE FROM app_credentials WHERE device_id=?").bind(deviceId),
  ]);
  return dev.name;
}

export type DeviceRow = { id: string; name: string; created: string; last_seen: string | null };

/** The user's paired (not removed) phones, oldest first. */
export async function listDevices(env: Env, userId: string): Promise<DeviceRow[]> {
  return (await env.DB.prepare("SELECT id, name, created, last_seen FROM app_devices WHERE user_id=? AND revoked=0 ORDER BY created")
    .bind(userId).all<DeviceRow>()).results;
}

/** Delete expired pairing codes, login challenges and sessions (hourly cron, and opportunistically). */
export async function purgeExpiredApp(env: Env): Promise<void> {
  const now = nowISO();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM app_pairings WHERE expires <= ?").bind(now),
    env.DB.prepare("DELETE FROM app_challenges WHERE expires <= ?").bind(now),
    env.DB.prepare("DELETE FROM app_sessions WHERE expires <= ?").bind(now),
  ]);
}

// ---------------------------------------------------------------- pairing

route("POST", "/v2/app/pair", async (req, env, user) => {
  const code = randomToken(32);
  const expires = inSeconds(PAIR_SECONDS);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM app_pairings WHERE expires <= ?").bind(nowISO()),
    env.DB.prepare("INSERT INTO app_pairings(code_hash,user_id,expires,used) VALUES(?,?,?,0)").bind(await sha256Hex(code), user.id, expires),
  ]);
  return json({ url: `${new URL(req.url).origin}/app/#pair=${code}`, expires });
});

const badCode = () => appJSON({ error: "This pairing link isn't valid any more. Make a new one on your Mac." }, 400);

async function livePairing(env: Env, code: unknown) {
  const c = str(code, 100);
  if (!c) return null;
  const codeHash = await sha256Hex(c);
  const row = await env.DB.prepare("SELECT user_id, challenge FROM app_pairings WHERE code_hash=? AND used=0 AND expires > ?")
    .bind(codeHash, nowISO()).first<{ user_id: string; challenge: string | null }>();
  return row ? { ...row, codeHash } : null;
}

async function pairOptions(req: Request, env: Env, body: any): Promise<Response> {
  const p = await livePairing(env, body.code);
  if (!p) return badCode();
  const u = await env.DB.prepare("SELECT name FROM users WHERE id=?").bind(p.user_id).first<{ name: string }>();
  if (!u) return badCode();
  const creds = await env.DB.prepare("SELECT credential_id, transports FROM app_credentials WHERE user_id=?").bind(p.user_id)
    .all<{ credential_id: string; transports: string | null }>();
  const options = await generateRegistrationOptions({
    rpName: "FloatBoard",
    rpID: new URL(req.url).hostname,
    userID: new Uint8Array(new TextEncoder().encode(p.user_id)),
    userName: u.name,
    userDisplayName: u.name,
    attestationType: "none",
    authenticatorSelection: { residentKey: "required", requireResidentKey: true, userVerification: "required" },
    supportedAlgorithmIDs: ALGS,
    excludeCredentials: creds.results.map((c) => ({ id: c.credential_id, transports: parseTransports(c.transports) })),
  });
  await env.DB.prepare("UPDATE app_pairings SET challenge=? WHERE code_hash=? AND used=0").bind(options.challenge, p.codeHash).run();
  return appJSON(options);
}

function parseTransports(t: string | null): AuthenticatorTransportFuture[] | undefined {
  try {
    const a = t ? JSON.parse(t) : null;
    return Array.isArray(a) ? a.filter((x): x is AuthenticatorTransportFuture => typeof x === "string") : undefined;
  } catch { return undefined; }
}

async function pairFinish(req: Request, env: Env, body: any): Promise<Response> {
  const p = await livePairing(env, body.code);
  if (!p || !p.challenge) return badCode();
  const url = new URL(req.url);
  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response: body.response,
      expectedChallenge: p.challenge,
      expectedOrigin: url.origin,
      expectedRPID: url.hostname,
      requireUserVerification: true,
      supportedAlgorithmIDs: ALGS,
    });
  } catch {
    return appJSON({ error: "The passkey couldn't be checked. Try again." }, 400);
  }
  if (!verification.verified) return appJSON({ error: "The passkey couldn't be checked. Try again." }, 400);
  const { credential } = verification.registrationInfo;
  if (await env.DB.prepare("SELECT 1 FROM app_credentials WHERE credential_id=?").bind(credential.id).first()) {
    return appJSON({ error: "This passkey is already in use." }, 400);
  }
  // Burn the code atomically: only one finish per code can get past here.
  const burned = await env.DB.prepare("UPDATE app_pairings SET used=1, challenge=NULL WHERE code_hash=? AND used=0 AND expires > ? AND challenge=? RETURNING user_id")
    .bind(p.codeHash, nowISO(), p.challenge).first<{ user_id: string }>();
  if (!burned) return badCode();
  const deviceName = (typeof body.deviceName === "string" ? body.deviceName.trim().slice(0, 60) : "") || "Phone";
  const deviceId = crypto.randomUUID();
  const now = nowISO();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO app_devices(id,user_id,name,created,last_seen,revoked) VALUES(?,?,?,?,?,0)").bind(deviceId, burned.user_id, deviceName, now, now),
    env.DB.prepare("INSERT INTO app_credentials(credential_id,device_id,user_id,public_key,counter,transports,created) VALUES(?,?,?,?,?,?,?)")
      .bind(credential.id, deviceId, burned.user_id, b64url(credential.publicKey), credential.counter,
        credential.transports ? JSON.stringify(credential.transports) : null, now),
  ]);
  const cookie = await newSession(env, burned.user_id, deviceId);
  const u = await env.DB.prepare("SELECT name FROM users WHERE id=?").bind(burned.user_id).first<{ name: string }>();
  return appJSON({ ok: true, user: u?.name ?? "", device: deviceName }, 200, cookie);
}

// ---------------------------------------------------------------- sign-in

async function loginOptions(req: Request, env: Env): Promise<Response> {
  const now = nowISO();
  await env.DB.prepare("DELETE FROM app_challenges WHERE expires <= ?").bind(now).run();
  const live = await env.DB.prepare("SELECT COUNT(*) n FROM app_challenges").first<{ n: number }>();
  if ((live?.n ?? 0) >= MAX_LIVE_CHALLENGES) return appJSON({ error: "Too many sign-ins right now. Try again in a few minutes." }, 429);
  const options = await generateAuthenticationOptions({
    rpID: new URL(req.url).hostname,
    allowCredentials: [],
    userVerification: "required",
  });
  const challengeId = randomToken(16);
  await env.DB.prepare("INSERT INTO app_challenges(id,challenge,purpose,expires,used) VALUES(?,?,'login',?,0)")
    .bind(challengeId, options.challenge, inSeconds(CHALLENGE_SECONDS)).run();
  return appJSON({ challengeId, options });
}

async function loginFinish(req: Request, env: Env, body: any): Promise<Response> {
  const refuse = () => appJSON({ error: "That passkey didn't work. If this phone was removed, pair it again from your Mac." }, 400);
  const challengeId = str(body.challengeId, 100);
  if (!challengeId) return refuse();
  // Used once, whatever happens next.
  const ch = await env.DB.prepare("UPDATE app_challenges SET used=1 WHERE id=? AND used=0 AND purpose='login' AND expires > ? RETURNING challenge")
    .bind(challengeId, nowISO()).first<{ challenge: string }>();
  if (!ch) return refuse();
  const credId = str(body.response?.id, 1400);
  if (!credId) return refuse();
  const cred = await env.DB.prepare(`SELECT c.credential_id, c.device_id, c.user_id, c.public_key, c.counter, c.transports
      FROM app_credentials c JOIN app_devices d ON d.id = c.device_id WHERE c.credential_id=? AND d.revoked=0`)
    .bind(credId).first<{ credential_id: string; device_id: string; user_id: string; public_key: string; counter: number; transports: string | null }>();
  if (!cred) return refuse();
  const handle = body.response?.response?.userHandle;
  if (handle && handle !== b64url(new TextEncoder().encode(cred.user_id))) return refuse();
  const url = new URL(req.url);
  let v;
  try {
    v = await verifyAuthenticationResponse({
      response: body.response,
      expectedChallenge: ch.challenge,
      expectedOrigin: url.origin,
      expectedRPID: url.hostname,
      requireUserVerification: true,
      credential: { id: cred.credential_id, publicKey: unb64url(cred.public_key), counter: cred.counter, transports: parseTransports(cred.transports) },
    });
  } catch {
    return refuse();
  }
  if (!v.verified) return refuse();
  await env.DB.prepare("UPDATE app_credentials SET counter=? WHERE credential_id=?").bind(v.authenticationInfo.newCounter, cred.credential_id).run();
  const cookie = await newSession(env, cred.user_id, cred.device_id);
  await env.DB.prepare("UPDATE app_devices SET last_seen=? WHERE id=?").bind(nowISO(), cred.device_id).run();
  return appJSON({ ok: true }, 200, cookie);
}

async function me(req: Request, env: Env): Promise<Response> {
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "signed out" }, 401);
  const row = await env.DB.prepare("SELECT u.name user, d.name device FROM users u JOIN app_devices d ON d.user_id = u.id WHERE u.id=? AND d.id=?")
    .bind(s.userId, s.deviceId).first<{ user: string; device: string }>();
  if (!row) return appJSON({ error: "signed out" }, 401);
  return appJSON({ user: row.user, device: row.device }, 200, s.setCookie);
}

async function logout(req: Request, env: Env): Promise<Response> {
  const token = cookieValue(req, SESSION_COOKIE);
  if (token && token.length <= 100) await env.DB.prepare("DELETE FROM app_sessions WHERE token_hash=?").bind(await sha256Hex(token)).run();
  return appJSON({ ok: true }, 200, clearSessionCookie);
}

/**
 * `/app/api/*` auth routes. Returns null for paths it doesn't own, so later features can chain their own handlers.
 * Authorization headers are ignored here: only the session cookie signs a phone in.
 */
export async function handleAppAuth(req: Request, env: Env): Promise<Response | null> {
  const path = new URL(req.url).pathname;
  if (req.method === "GET" && path === "/app/api/me") return me(req, env);
  if (req.method !== "POST") return null;
  const handlers: Record<string, (req: Request, env: Env, body: any) => Promise<Response>> = {
    "/app/api/pair/options": pairOptions,
    "/app/api/pair/finish": pairFinish,
    "/app/api/login/options": (r, e) => loginOptions(r, e),
    "/app/api/login/finish": loginFinish,
    "/app/api/logout": (r, e) => logout(r, e),
  };
  const h = handlers[path];
  if (!h) return null;
  if (!sameOrigin(req)) return appJSON({ error: "refused" }, 403);
  const text = await req.text();
  if (text.length > 20_000) return appJSON({ error: "too large" }, 413);
  const rb = await readJSON(new Request(req.url, { method: "POST", body: text }));
  if (!rb.ok) return appJSON({ error: "Invalid JSON" }, 400);
  return h(req, env, rb.body);
}
