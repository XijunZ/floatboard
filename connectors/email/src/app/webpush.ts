/**
 * Web Push from the engine itself, written with WebCrypto only.
 *
 * - VAPID (RFC 8292): the engine's ECDSA P-256 key pair is made on first use and kept in `app_keys` (private key
 *   encrypted with ENC_KEY). Each push carries `Authorization: vapid t=<ES256 JWT>, k=<public key>`.
 * - Payload encryption (RFC 8291, content coding aes128gcm from RFC 8188): one record, padding delimiter 0x02.
 * - Routes (session cookie): `GET /app/api/push/key`, `POST|DELETE /app/api/push/subscribe`, `POST /app/api/push/test`.
 * - Endpoints must be https on the default port at a known push service (`PUSH_HOSTS`); anything else is refused when
 *   subscribing and never fetched. Pushes don't follow redirects (a 3xx is a failure), and the test route never passes
 *   the push service's status on to the phone.
 * - One endpoint belongs to one device: saving a subscription deletes any other row with the same endpoint, whoever's.
 * - Alerts go to every subscribed device that is still paired (not revoked). A device whose session expired keeps
 *   getting alerts until it is removed or turns notifications off; signing in again is needed only to open the board.
 * - The payload JSON is trimmed to fit one 4096-byte record (RFC 8030's guaranteed size): body first, then title, by
 *   UTF-8 bytes; a link that doesn't fit becomes `/app/`.
 */
import { type Env, nowISO } from "../env";
import { decrypt, encrypt } from "../crypto";
import { readCappedJSON } from "../http";
import { appJSON, requireAppSession, sameOrigin } from "./auth";

const enc = new TextEncoder();
const RECORD_SIZE = 4096;
const MAX_ENDPOINT = 2000;
const MAX_URL = 2000;
/** Largest plaintext whose encrypted body (86-byte header + plaintext + delimiter + 16-byte tag) fits in 4096 bytes. */
export const MAX_PLAINTEXT = RECORD_SIZE - 86 - 17;

/** Push services browsers use: exact hosts, and suffixes (a subdomain of). */
const PUSH_HOSTS = ["fcm.googleapis.com", "updates.push.services.mozilla.com"];
const PUSH_SUFFIXES = [".push.apple.com", ".push.services.mozilla.com", ".notify.windows.com"];

/** True for an https URL on the default port, with no user info, at a known push service. */
export function isPushEndpoint(endpoint: string): boolean {
  let u: URL;
  try { u = new URL(endpoint); } catch { return false; }
  if (u.protocol !== "https:" || u.port !== "" || u.username || u.password) return false;
  const h = u.hostname.toLowerCase();
  return PUSH_HOSTS.includes(h) || PUSH_SUFFIXES.some((s) => h.endsWith(s) && h.length > s.length);
}
const JWT_SECONDS = 12 * 3600;

// ---------------------------------------------------------------- bytes

export const b64url = (b: Uint8Array): string => {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
export const unb64url = (s: string): Uint8Array =>
  Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const isB64url = (s: unknown): s is string => typeof s === "string" && /^[A-Za-z0-9_-]+={0,2}$/.test(s);

// ---------------------------------------------------------------- VAPID keys

export type VapidKeys = { publicKey: string; privateKey: CryptoKey };

async function importVapid(jwk: JsonWebKey): Promise<VapidKeys> {
  const privateKey = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, d: jwk.d, ext: true },
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return { publicKey: b64url(concat(Uint8Array.of(4), unb64url(jwk.x!), unb64url(jwk.y!))), privateKey };
}

/** The engine's VAPID key pair: loaded, or made on first use (race-safe: insert-or-ignore, then read what won). */
export async function vapidKeys(env: Env): Promise<VapidKeys> {
  const read = () => env.DB.prepare("SELECT value_enc FROM app_keys WHERE name='vapid'").first<{ value_enc: string }>();
  let row = await read();
  if (!row) {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey) as JsonWebKey;
    const value = await encrypt(env, JSON.stringify({ x: jwk.x, y: jwk.y, d: jwk.d }));
    await env.DB.prepare("INSERT OR IGNORE INTO app_keys (name, value_enc, created) VALUES ('vapid', ?, ?)").bind(value, nowISO()).run();
    row = await read();
  }
  return importVapid(JSON.parse(await decrypt(env, row!.value_enc)));
}

/** RFC 8292 header value for a push to `endpoint`. `subject` is an https address (the engine's /app). */
export async function vapidAuthorization(keys: VapidKeys, endpoint: string, subject: string, now = Date.now()): Promise<string> {
  const head = b64url(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const claims = b64url(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + JWT_SECONDS, sub: subject })));
  // WebCrypto ECDSA signatures are raw r||s (IEEE P1363), which is what JWS ES256 uses.
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, enc.encode(`${head}.${claims}`)));
  return `vapid t=${head}.${claims}.${b64url(sig)}, k=${keys.publicKey}`;
}

// ---------------------------------------------------------------- RFC 8291 encryption

export type PushKeys = { p256dh: string; auth: string };

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}

/**
 * Encrypt `plaintext` for one subscription (aes128gcm body: salt, record size, key id = the sender's public key, one
 * record). Tests pass a fixed `salt` and sender key pair (`asPrivate` = base64url d, `asPublic` = base64url point).
 */
export async function encryptPayload(sub: PushKeys, plaintext: string | Uint8Array,
  opts: { salt?: Uint8Array; asPrivate?: string; asPublic?: string } = {}): Promise<Uint8Array> {
  const uaPublic = unb64url(sub.p256dh);
  const authSecret = unb64url(sub.auth);
  const salt = opts.salt ?? crypto.getRandomValues(new Uint8Array(16));
  let asPrivate: CryptoKey, asPublic: Uint8Array;
  if (opts.asPrivate && opts.asPublic) {
    asPublic = unb64url(opts.asPublic);
    asPrivate = await crypto.subtle.importKey("jwk", {
      kty: "EC", crv: "P-256", d: opts.asPrivate, x: b64url(asPublic.slice(1, 33)), y: b64url(asPublic.slice(33, 65)), ext: true,
    }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  } else {
    const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
    asPrivate = pair.privateKey;
    asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer);
  }
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey } as unknown as SubtleCryptoDeriveKeyAlgorithm, asPrivate, 256));
  const ikm = await hkdf(authSecret, ecdh, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const data = typeof plaintext === "string" ? enc.encode(plaintext) : plaintext;
  if (data.length > RECORD_SIZE - 17) throw new Error("push payload too large");
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(data, Uint8Array.of(2))));
  const header = new Uint8Array(21);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, RECORD_SIZE);
  header[20] = asPublic.length;
  return concat(header, asPublic, ct);
}

// ---------------------------------------------------------------- sending

let pushFetch: typeof fetch = (...a) => fetch(...a);
/** Tests replace the push service. */
export function setPushFetch(f: typeof fetch) { pushFetch = f; }

export type PushSubscriptionRow = { device_id: string; user_id: string; endpoint: string; p256dh: string; auth: string; origin: string };
export type PushPayload = { title: string; body: string; url: string };

const utf8 = (s: string) => enc.encode(s).length;

/** The longest prefix of `s` (whole code points) for which `fits` holds. */
function longestFitting(s: string, fits: (t: string) => boolean): string {
  if (fits(s)) return s;
  const cps = [...s];
  let lo = 0, hi = cps.length; // fits(lo) holds (or lo=0), fits(hi) does not
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (fits(cps.slice(0, mid).join("") + "…")) lo = mid; else hi = mid;
  }
  return lo === 0 ? "" : cps.slice(0, lo).join("") + "…";
}

/**
 * What the service worker receives (JSON): single-line title of at most 120 characters, body of at most 1000, and the
 * whole thing at most MAX_PLAINTEXT UTF-8 bytes (body trimmed first, then title; a link that is too long, or still
 * doesn't fit, becomes /app/).
 */
export function payloadJSON(p: PushPayload): string {
  const title0 = [...p.title.replace(/[\r\n]+/g, " ")].slice(0, 120).join("");
  const body0 = [...p.body].slice(0, 1000).join("");
  const urls = p.url.length <= MAX_URL && p.url !== "/app/" ? [p.url, "/app/"] : ["/app/"];
  let out = "";
  for (const url of urls) {
    const json = (title: string, body: string) => JSON.stringify({ title, body, url });
    const fits = (title: string, body: string) => utf8(json(title, body)) <= MAX_PLAINTEXT;
    const body = longestFitting(body0, (b) => fits(title0, b));
    const title = fits(title0, body) ? title0 : longestFitting(title0, (t) => fits(t, body));
    out = json(title, body);
    if (fits(title, body)) return out;
  }
  return out; // unreachable in practice: "/app/" with an empty title and body always fits
}

/**
 * Send one notification. Returns the push service's status and whether the subscription is gone (404/410: its row is
 * deleted). A redirect is not followed and counts as a failure. An endpoint off the push-service list is never fetched
 * (its row is deleted and it throws). Network errors throw.
 */
export async function sendPush(env: Env, sub: PushSubscriptionRow, payload: PushPayload, keys?: VapidKeys): Promise<{ status: number; ok: boolean; gone: boolean }> {
  if (!isPushEndpoint(sub.endpoint)) {
    await env.DB.prepare("DELETE FROM app_push WHERE device_id=? AND endpoint=?").bind(sub.device_id, sub.endpoint).run();
    throw new Error("not a push service address");
  }
  const k = keys ?? await vapidKeys(env);
  const body = await encryptPayload(sub, payloadJSON(payload));
  const r = await pushFetch(sub.endpoint, {
    method: "POST",
    redirect: "manual",
    headers: {
      TTL: "86400", Urgency: "high", "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
      Authorization: await vapidAuthorization(k, sub.endpoint, `${sub.origin}/app`),
    },
    body,
  });
  const gone = r.status === 404 || r.status === 410;
  if (gone) await env.DB.prepare("DELETE FROM app_push WHERE device_id=? AND endpoint=?").bind(sub.device_id, sub.endpoint).run();
  return { status: r.status, ok: r.status >= 200 && r.status < 300, gone };
}

/**
 * Push to every subscribed, still-paired device of one user (an expired session doesn't stop alerts). Resolves false
 * when the user has none; throws when none got through.
 */
export async function pushToUser(env: Env, userId: string, payload: PushPayload): Promise<boolean> {
  const subs = (await env.DB.prepare(`SELECT p.device_id, p.user_id, p.endpoint, p.p256dh, p.auth, p.origin FROM app_push p
      JOIN app_devices d ON d.id = p.device_id AND d.user_id = p.user_id WHERE p.user_id=? AND d.revoked=0`)
    .bind(userId).all<PushSubscriptionRow>()).results;
  if (!subs.length) return false;
  const keys = await vapidKeys(env);
  const results = await Promise.allSettled(subs.map((s) => sendPush(env, s, payload, keys)));
  if (results.some((r) => r.status === "fulfilled" && r.value.ok)) return true;
  const why = results.map((r) => r.status === "fulfilled" ? String(r.value.status) : String((r.reason as Error)?.message ?? r.reason));
  throw new Error(`push failed (${why.join(", ")})`);
}

// ---------------------------------------------------------------- routes

/** Validate a browser PushSubscription JSON: push service endpoint, 65-byte p256dh, 16-byte auth. */
function parseSubscription(body: any): { endpoint: string; p256dh: string; auth: string } | string {
  const { endpoint, keys } = body ?? {};
  if (typeof endpoint !== "string" || endpoint.length > MAX_ENDPOINT) return "endpoint must be a web address";
  try { new URL(endpoint); } catch { return "endpoint must be a web address"; }
  if (!isPushEndpoint(endpoint)) return "endpoint must be a browser push service address";
  if (!keys || typeof keys !== "object") return "keys are required";
  if (!isB64url(keys.p256dh) || keys.p256dh.length > 100) return "keys.p256dh must be base64url";
  if (!isB64url(keys.auth) || keys.auth.length > 40) return "keys.auth must be base64url";
  const p = unb64url(keys.p256dh), a = unb64url(keys.auth);
  if (p.length !== 65 || p[0] !== 4) return "keys.p256dh must be an uncompressed P-256 point";
  if (a.length !== 16) return "keys.auth must be 16 bytes";
  return { endpoint, p256dh: b64url(p), auth: b64url(a) };
}

export async function handlePush(req: Request, env: Env): Promise<Response | null> {
  const url = new URL(req.url);
  const path = url.pathname;
  const owned = (path === "/app/api/push/key" && req.method === "GET")
    || (path === "/app/api/push/subscribe" && (req.method === "POST" || req.method === "DELETE"))
    || (path === "/app/api/push/test" && req.method === "POST");
  if (!owned) return null;
  if (req.method !== "GET" && !sameOrigin(req)) return appJSON({ error: "refused" }, 403);
  const s = await requireAppSession(req, env);
  if (!s) return appJSON({ error: "not signed in" }, 401);
  const reply = (data: unknown, status = 200) => appJSON(data, status, s.setCookie);

  if (path === "/app/api/push/key") return reply({ key: (await vapidKeys(env)).publicKey });

  if (path === "/app/api/push/subscribe" && req.method === "DELETE") {
    await env.DB.prepare("DELETE FROM app_push WHERE device_id=? AND user_id=?").bind(s.deviceId, s.userId).run();
    return reply({ ok: true });
  }

  if (path === "/app/api/push/subscribe") {
    const rb = await readCappedJSON(req, 5_000);
    if (!rb.ok) return rb.tooLarge ? reply({ error: "too large" }, 413) : reply({ error: "Invalid JSON" }, 400);
    const sub = parseSubscription(rb.body);
    if (typeof sub === "string") return reply({ error: sub }, 400);
    // The endpoint is this browser's: whoever had it before (another device or account on this browser) loses it.
    await env.DB.batch([
      env.DB.prepare("DELETE FROM app_push WHERE endpoint=? AND device_id<>?").bind(sub.endpoint, s.deviceId),
      env.DB.prepare(`INSERT INTO app_push (device_id, user_id, endpoint, p256dh, auth, origin, created) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_id) DO UPDATE SET user_id=excluded.user_id, endpoint=excluded.endpoint, p256dh=excluded.p256dh,
          auth=excluded.auth, origin=excluded.origin, created=excluded.created`)
        .bind(s.deviceId, s.userId, sub.endpoint, sub.p256dh, sub.auth, url.origin, nowISO()),
    ]);
    return reply({ ok: true });
  }

  // POST /app/api/push/test: this phone only.
  const row = await env.DB.prepare("SELECT device_id, user_id, endpoint, p256dh, auth, origin FROM app_push WHERE device_id=? AND user_id=?")
    .bind(s.deviceId, s.userId).first<PushSubscriptionRow>();
  if (!row) return reply({ error: "Notifications are off on this phone." }, 409);
  try {
    const r = await sendPush(env, row, { title: "FloatBoard test notification", body: "Notifications work on this phone.", url: "/app/" });
    if (r.gone) return reply({ error: "This phone's notification subscription has ended. Turn notifications on again." }, 410);
    if (!r.ok) return reply({ error: "The push service didn't accept the notification. Try again later." }, 502);
    return reply({ ok: true });
  } catch {
    return reply({ error: "Could not reach the push service." }, 502);
  }
}
