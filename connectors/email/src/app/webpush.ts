/**
 * Web Push from the engine itself, written with WebCrypto only.
 *
 * - VAPID (RFC 8292): the engine's ECDSA P-256 key pair is made on first use and kept in `app_keys` (private key
 *   encrypted with ENC_KEY). Each push carries `Authorization: vapid t=<ES256 JWT>, k=<public key>`.
 * - Payload encryption (RFC 8291, content coding aes128gcm from RFC 8188): one record, padding delimiter 0x02.
 * - Routes (session cookie): `GET /app/api/push/key`, `POST|DELETE /app/api/push/subscribe`, `POST /app/api/push/test`.
 */
import { type Env, nowISO } from "../env";
import { decrypt, encrypt } from "../crypto";
import { readJSON } from "../http";
import { appJSON, requireAppSession, sameOrigin } from "./auth";

const enc = new TextEncoder();
const RECORD_SIZE = 4096;
const MAX_ENDPOINT = 2000;
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

/** What the service worker receives (JSON), kept short and single-line in the title. */
function payloadJSON(p: PushPayload): string {
  return JSON.stringify({ title: p.title.replace(/[\r\n]+/g, " ").slice(0, 120), body: p.body.slice(0, 1000), url: p.url.slice(0, MAX_ENDPOINT) });
}

/**
 * Send one notification. Returns the push service's status and whether the subscription is gone (404/410: its row is
 * deleted). Network errors throw.
 */
export async function sendPush(env: Env, sub: PushSubscriptionRow, payload: PushPayload, keys?: VapidKeys): Promise<{ status: number; ok: boolean; gone: boolean }> {
  const k = keys ?? await vapidKeys(env);
  const body = await encryptPayload(sub, payloadJSON(payload));
  const r = await pushFetch(sub.endpoint, {
    method: "POST",
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

/** Push to every subscribed phone of one user. Resolves false when the user has none; throws when none got through. */
export async function pushToUser(env: Env, userId: string, payload: PushPayload): Promise<boolean> {
  const subs = (await env.DB.prepare("SELECT device_id, user_id, endpoint, p256dh, auth, origin FROM app_push WHERE user_id=?")
    .bind(userId).all<PushSubscriptionRow>()).results;
  if (!subs.length) return false;
  const keys = await vapidKeys(env);
  const results = await Promise.allSettled(subs.map((s) => sendPush(env, s, payload, keys)));
  if (results.some((r) => r.status === "fulfilled" && r.value.ok)) return true;
  const why = results.map((r) => r.status === "fulfilled" ? String(r.value.status) : String((r.reason as Error)?.message ?? r.reason));
  throw new Error(`push failed (${why.join(", ")})`);
}

// ---------------------------------------------------------------- routes

/** Validate a browser PushSubscription JSON: https endpoint, 65-byte p256dh, 16-byte auth. */
function parseSubscription(body: any): { endpoint: string; p256dh: string; auth: string } | string {
  const { endpoint, keys } = body ?? {};
  if (typeof endpoint !== "string" || endpoint.length > MAX_ENDPOINT) return "endpoint must be a web address";
  let u: URL;
  try { u = new URL(endpoint); } catch { return "endpoint must be a web address"; }
  if (u.protocol !== "https:") return "endpoint must be https";
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
    const text = await req.text();
    if (text.length > 5_000) return reply({ error: "too large" }, 413);
    const rb = await readJSON(new Request(req.url, { method: "POST", body: text }));
    if (!rb.ok) return reply({ error: "Invalid JSON" }, 400);
    const sub = parseSubscription(rb.body);
    if (typeof sub === "string") return reply({ error: sub }, 400);
    await env.DB.prepare(`INSERT INTO app_push (device_id, user_id, endpoint, p256dh, auth, origin, created) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(device_id) DO UPDATE SET user_id=excluded.user_id, endpoint=excluded.endpoint, p256dh=excluded.p256dh,
        auth=excluded.auth, origin=excluded.origin, created=excluded.created`)
      .bind(s.deviceId, s.userId, sub.endpoint, sub.p256dh, sub.auth, url.origin, nowISO()).run();
    return reply({ ok: true });
  }

  // POST /app/api/push/test: this phone only.
  const row = await env.DB.prepare("SELECT device_id, user_id, endpoint, p256dh, auth, origin FROM app_push WHERE device_id=? AND user_id=?")
    .bind(s.deviceId, s.userId).first<PushSubscriptionRow>();
  if (!row) return reply({ error: "Notifications are off on this phone." }, 409);
  try {
    const r = await sendPush(env, row, { title: "FloatBoard test notification", body: "Notifications work on this phone.", url: "/app/" });
    if (r.gone) return reply({ error: "This phone's notification subscription has ended. Turn notifications on again." }, 410);
    if (!r.ok) return reply({ error: `The push service refused it (${r.status}).` }, 502);
    return reply({ ok: true });
  } catch {
    return reply({ error: "Could not reach the push service." }, 502);
  }
}
