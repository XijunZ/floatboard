/**
 * Phone app sign-in: pairing codes, passkeys (WebAuthn) and device sessions.
 *
 * - A device is one browser install (a phone's Safari or Chrome, an installed Home Screen app, an iPad...). The phone
 *   app keeps a random install id in localStorage and sends it (plus a device name) when pairing and signing in; the
 *   engine stores only its sha256 (`app_devices.install_hash`). One install id belongs to one device of one account: a
 *   pairing or sign-in for another account on the same browser ends the old device (revoked, sessions and push
 *   subscription deleted), and so does pairing or signing in over a still-valid session of another device.
 * - Passkeys belong to the user (`app_credentials`; `device_id` is the device it was first paired on). A passkey synced to
 *   another browser (iCloud Keychain, Google Password Manager) signs that browser in as a NEW device with its own session
 *   and push subscription; signing in again on a known install reuses its device. `app_devices.credential_id` is the
 *   passkey the device last signed in with.
 * - Removing a device (setup page) ends that device only. A passkey is deleted when the last paired device using it is
 *   removed, and a passkey with no paired device using it can't sign in.
 * - The Mac asks `POST /v2/app/pair` (user key) for a one-time pairing link `<origin>/app/#pair=<code>` (32 random bytes,
 *   stored only as sha256, valid 10 minutes). Making a new code leaves older unexpired codes valid; each still works once.
 * - The phone opens the link and registers a passkey (`/app/api/pair/options|finish`): resident key, user verification
 *   required, attestation "none", ES256 or RS256. A failed verification leaves the code usable. A successful one uses the
 *   code and creates the device, passkey and session in one D1 batch led by the conditional "mark used" UPDATE, so one
 *   code can never make two devices and a failed insert never uses up the code.
 * - A phone without a session signs in with its passkey (`/app/api/login/options|finish`); login challenges live 5
 *   minutes and are used once. At most 20 live challenges per client address (CF-Connecting-IP, stored hashed) and
 *   2000 in all.
 * - The session is the `fb_session` cookie (32 random bytes, stored as sha256; HttpOnly, Secure, SameSite=Strict,
 *   Path=/app, 90 days, renewed on use when the last renewal is more than a day old).
 *
 * `/app/api/*` never accepts the user key and `/v2/*` never accepts the cookie. Every state-changing `/app/api` POST must
 * carry an `Origin` equal to the engine's own origin (CSRF defence on top of SameSite=Strict). Bodies over 20 KB are
 * refused before they are read.
 */
import {
  generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse,
  type AuthenticatorTransportFuture,
} from "@simplewebauthn/server";
import { randomToken, sha256Hex } from "../auth";
import { type Env, json, nowISO } from "../env";
import { readCappedJSON } from "../http";
import { route } from "../router";

export const SESSION_COOKIE = "fb_session";
export const SESSION_SECONDS = 90 * 86400;
const RENEW_AFTER_MS = 86400_000;
const PAIR_SECONDS = 600;
const CHALLENGE_SECONDS = 300;
/** Unauthenticated login/options calls can't grow the challenge table past this many live rows. */
const MAX_LIVE_CHALLENGES = 2000;
/** ...and one client address can't hold more than this many. */
const MAX_LIVE_CHALLENGES_PER_IP = 20;
const MAX_BODY = 20_000;
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

/** A SQL condition (with its bind values) that statements in a batch can be gated on. */
type Gate = { sql: string; args: unknown[] };
const gated = (env: Env, sql: string, args: unknown[], gate?: Gate) =>
  env.DB.prepare(gate ? `${sql} AND ${gate.sql}` : sql).bind(...args, ...(gate?.args ?? []));

/** A new session for a device: the INSERT (optionally gated) and the cookie to set once it ran. */
async function sessionInsert(env: Env, userId: string, deviceId: string, gate?: Gate): Promise<{ stmt: D1PreparedStatement; cookie: string }> {
  const token = randomToken(32);
  const now = nowISO();
  const args = [await sha256Hex(token), deviceId, userId, now, inSeconds(SESSION_SECONDS), now];
  const stmt = gate
    ? env.DB.prepare(`INSERT INTO app_sessions(token_hash,device_id,user_id,created,expires,last_used) SELECT ?,?,?,?,?,? WHERE ${gate.sql}`).bind(...args, ...gate.args)
    : env.DB.prepare("INSERT INTO app_sessions(token_hash,device_id,user_id,created,expires,last_used) VALUES(?,?,?,?,?,?)").bind(...args);
  return { stmt, cookie: sessionCookie(token) };
}

/** End one device: revoked, its sessions and push subscription deleted. */
function endDeviceStmts(env: Env, deviceId: string, userId: string, gate?: Gate): D1PreparedStatement[] {
  return [
    gated(env, "UPDATE app_devices SET revoked=1 WHERE id=? AND user_id=?", [deviceId, userId], gate),
    gated(env, "DELETE FROM app_sessions WHERE device_id=? AND user_id=?", [deviceId, userId], gate),
    gated(env, "DELETE FROM app_push WHERE device_id=? AND user_id=?", [deviceId, userId], gate),
  ];
}

/** Delete the user's passkeys that no paired device uses any more. */
function prunePasskeysStmt(env: Env, userId: string, gate?: Gate): D1PreparedStatement {
  return gated(env, `DELETE FROM app_credentials WHERE user_id=? AND credential_id NOT IN
      (SELECT credential_id FROM app_devices WHERE user_id=? AND revoked=0 AND credential_id IS NOT NULL)`, [userId, userId], gate);
}

/**
 * Remove a device: it is marked revoked, and its sessions and push subscription are deleted; a passkey no other paired
 * device uses is deleted too. Returns its name, or null when the user has no such (unrevoked) device. Later features that
 * store per-device data delete it here too.
 */
export async function removeDevice(env: Env, userId: string, deviceId: string): Promise<string | null> {
  const dev = await env.DB.prepare("SELECT name FROM app_devices WHERE id=? AND user_id=? AND revoked=0").bind(deviceId, userId).first<{ name: string }>();
  if (!dev) return null;
  await env.DB.batch([...endDeviceStmts(env, deviceId, userId), prunePasskeysStmt(env, userId)]);
  return dev.name;
}

export type DeviceRow = { id: string; name: string; created: string; last_seen: string | null; shares_passkey: number };

/** The user's paired (not removed) devices, oldest first, with how many other paired devices use the same passkey. */
export async function listDevices(env: Env, userId: string): Promise<DeviceRow[]> {
  return (await env.DB.prepare(`SELECT d.id, d.name, d.created, d.last_seen,
      (SELECT COUNT(*) FROM app_devices o WHERE o.user_id=d.user_id AND o.revoked=0 AND o.id<>d.id AND o.credential_id=d.credential_id) AS shares_passkey
      FROM app_devices d WHERE d.user_id=? AND d.revoked=0 ORDER BY d.created`)
    .bind(userId).all<DeviceRow>()).results;
}

const deviceName = (v: unknown) => (typeof v === "string" ? v.trim().slice(0, 60) : "") || "Phone";
const installHash = async (v: unknown) => {
  const s = str(v, 200);
  return s ? sha256Hex(`install:${s}`) : null;
};

/**
 * Devices this browser stands for that must end because it now signs in as `deviceId` of `userId`: another account's
 * device with the same install id, and the device of a still-valid session cookie the browser sent (when it isn't
 * `deviceId`). Statements, optionally gated, end them and prune passkeys left unused.
 */
async function replacedDeviceStmts(req: Request, env: Env, userId: string, deviceId: string, install: string | null, gate?: Gate): Promise<D1PreparedStatement[]> {
  const old = new Map<string, string>(); // device id -> user id
  if (install) {
    const rows = (await env.DB.prepare("SELECT id, user_id FROM app_devices WHERE install_hash=? AND revoked=0 AND user_id<>?")
      .bind(install, userId).all<{ id: string; user_id: string }>()).results;
    for (const r of rows) old.set(r.id, r.user_id);
  }
  const token = cookieValue(req, SESSION_COOKIE);
  if (token && token.length <= 100) {
    const s = await env.DB.prepare("SELECT device_id, user_id FROM app_sessions WHERE token_hash=? AND expires > ?")
      .bind(await sha256Hex(token), nowISO()).first<{ device_id: string; user_id: string }>();
    if (s && s.device_id !== deviceId) old.set(s.device_id, s.user_id);
  }
  const stmts: D1PreparedStatement[] = [];
  for (const [id, uid] of old) stmts.push(...endDeviceStmts(env, id, uid, gate));
  for (const uid of new Set(old.values())) stmts.push(prunePasskeysStmt(env, uid, gate));
  return stmts;
}

/** The phone app's account marker (`/app/api/me`): stable per user, different between users, not the user id. */
export async function accountMarker(userId: string): Promise<string> {
  return (await sha256Hex(`floatboard-account:${userId}`)).slice(0, 32);
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
    env.DB.prepare("UPDATE users SET app_origin=? WHERE id=?").bind(new URL(req.url).origin, user.id),
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
  const name = deviceName(body.deviceName);
  const deviceId = crypto.randomUUID();
  const install = await installHash(body.installId);
  const now = nowISO();
  // One batch (one transaction): the conditional UPDATE marks the code used with a marker only this request knows; every
  // later statement only runs when that marker is there. A failed insert rolls the whole batch back, code included.
  const marker = `used:${randomToken(16)}`;
  const gate: Gate = { sql: "EXISTS (SELECT 1 FROM app_pairings WHERE code_hash=? AND challenge=?)", args: [p.codeHash, marker] };
  const session = await sessionInsert(env, p.user_id, deviceId, gate);
  const stmts = [
    env.DB.prepare("UPDATE app_pairings SET used=1, challenge=? WHERE code_hash=? AND used=0 AND expires > ? AND challenge=?")
      .bind(marker, p.codeHash, now, p.challenge),
    env.DB.prepare(`INSERT INTO app_devices(id,user_id,name,created,last_seen,revoked,credential_id,install_hash) SELECT ?,?,?,?,?,0,?,? WHERE ${gate.sql}`)
      .bind(deviceId, p.user_id, name, now, now, credential.id, install, ...gate.args),
    env.DB.prepare(`INSERT INTO app_credentials(credential_id,device_id,user_id,public_key,counter,transports,created) SELECT ?,?,?,?,?,?,? WHERE ${gate.sql}`)
      .bind(credential.id, deviceId, p.user_id, b64url(credential.publicKey), credential.counter,
        credential.transports ? JSON.stringify(credential.transports) : null, now, ...gate.args),
    session.stmt,
    ...await replacedDeviceStmts(req, env, p.user_id, deviceId, install, gate),
  ];
  let results: D1Result[];
  try {
    results = await env.DB.batch(stmts);
  } catch {
    if (await env.DB.prepare("SELECT 1 FROM app_credentials WHERE credential_id=?").bind(credential.id).first()) {
      return appJSON({ error: "This passkey is already in use." }, 400);
    }
    return appJSON({ error: "Something went wrong. Try again." }, 500);
  }
  if (results[0].meta.changes !== 1) return badCode(); // another request used the code first: nothing was created
  const u = await env.DB.prepare("SELECT name FROM users WHERE id=?").bind(p.user_id).first<{ name: string }>();
  return appJSON({ ok: true, user: u?.name ?? "", device: name }, 200, session.cookie);
}

// ---------------------------------------------------------------- sign-in

async function loginOptions(req: Request, env: Env): Promise<Response> {
  const now = nowISO();
  const ipHash = await sha256Hex(`ip:${req.headers.get("CF-Connecting-IP") ?? ""}`);
  await env.DB.prepare("DELETE FROM app_challenges WHERE expires <= ?").bind(now).run();
  const live = await env.DB.prepare("SELECT COUNT(*) n, COALESCE(SUM(ip_hash=?), 0) mine FROM app_challenges").bind(ipHash).first<{ n: number; mine: number }>();
  if ((live?.n ?? 0) >= MAX_LIVE_CHALLENGES || (live?.mine ?? 0) >= MAX_LIVE_CHALLENGES_PER_IP) {
    return appJSON({ error: "Too many sign-ins right now. Try again in a few minutes." }, 429);
  }
  const options = await generateAuthenticationOptions({
    rpID: new URL(req.url).hostname,
    allowCredentials: [],
    userVerification: "required",
  });
  const challengeId = randomToken(16);
  await env.DB.prepare("INSERT INTO app_challenges(id,challenge,purpose,expires,used,ip_hash) VALUES(?,?,'login',?,0,?)")
    .bind(challengeId, options.challenge, inSeconds(CHALLENGE_SECONDS), ipHash).run();
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
  // A passkey signs in only while some paired device of its user uses it.
  const cred = await env.DB.prepare(`SELECT c.credential_id, c.user_id, c.public_key, c.counter, c.transports FROM app_credentials c
      WHERE c.credential_id=? AND EXISTS (SELECT 1 FROM app_devices d WHERE d.user_id=c.user_id AND d.credential_id=c.credential_id AND d.revoked=0)`)
    .bind(credId).first<{ credential_id: string; user_id: string; public_key: string; counter: number; transports: string | null }>();
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
  // This browser's device: the one its install id already names for this user, or a new one.
  const install = await installHash(body.installId);
  const known = install ? await env.DB.prepare("SELECT id FROM app_devices WHERE install_hash=? AND user_id=? AND revoked=0")
    .bind(install, cred.user_id).first<{ id: string }>() : null;
  const deviceId = known?.id ?? crypto.randomUUID();
  const now = nowISO();
  const session = await sessionInsert(env, cred.user_id, deviceId);
  await env.DB.batch([
    env.DB.prepare("UPDATE app_credentials SET counter=? WHERE credential_id=?").bind(v.authenticationInfo.newCounter, cred.credential_id),
    known
      ? env.DB.prepare("UPDATE app_devices SET last_seen=?, credential_id=? WHERE id=?").bind(now, cred.credential_id, deviceId)
      : env.DB.prepare("INSERT INTO app_devices(id,user_id,name,created,last_seen,revoked,credential_id,install_hash) VALUES(?,?,?,?,?,0,?,?)")
        .bind(deviceId, cred.user_id, deviceName(body.deviceName), now, now, cred.credential_id, install),
    session.stmt,
    ...await replacedDeviceStmts(req, env, cred.user_id, deviceId, install),
  ]);
  return appJSON({ ok: true }, 200, session.cookie);
}

async function me(req: Request, env: Env): Promise<Response> {
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "signed out" }, 401);
  const row = await env.DB.prepare("SELECT u.name user, d.name device FROM users u JOIN app_devices d ON d.user_id = u.id WHERE u.id=? AND d.id=?")
    .bind(s.userId, s.deviceId).first<{ user: string; device: string }>();
  if (!row) return appJSON({ error: "signed out" }, 401);
  return appJSON({ user: row.user, device: row.device, account: await accountMarker(s.userId) }, 200, s.setCookie);
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
  const rb = await readCappedJSON(req, MAX_BODY);
  if (!rb.ok) return rb.tooLarge ? appJSON({ error: "too large" }, 413) : appJSON({ error: "Invalid JSON" }, 400);
  return h(req, env, rb.body);
}
