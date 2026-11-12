import { expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call } from "./helpers";

/** Phone pairing helpers shared by the phone-app tests: a software WebAuthn authenticator and end-to-end pairing. */
// ---------------------------------------------------------------- a software authenticator (ES256, attestation "none")

const enc = new TextEncoder();
export const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const sha256 = async (b: Uint8Array) => new Uint8Array(await crypto.subtle.digest("SHA-256", b));

/** Minimal CBOR encoder: integers, byte strings, text strings, maps. */
function cbor(v: unknown): Uint8Array {
  const head = (major: number, n: number) => {
    if (n < 24) return Uint8Array.of((major << 5) | n);
    if (n < 256) return Uint8Array.of((major << 5) | 24, n);
    if (n < 65536) return Uint8Array.of((major << 5) | 25, n >> 8, n & 255);
    return Uint8Array.of((major << 5) | 26, (n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
  };
  if (typeof v === "number") return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (v instanceof Uint8Array) return concat(head(2, v.length), v);
  if (typeof v === "string") { const b = enc.encode(v); return concat(head(3, b.length), b); }
  if (v instanceof Map) return concat(head(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)]));
  throw new Error("cbor: unsupported value");
}

/** Raw r||s (WebCrypto) to the DER signature WebAuthn uses. */
function derSignature(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let x = b.slice(i);
    if (x[0] & 0x80) x = concat(Uint8Array.of(0), x);
    return concat(Uint8Array.of(0x02, x.length), x);
  };
  const body = concat(int(raw.slice(0, 32)), int(raw.slice(32)));
  return concat(Uint8Array.of(0x30, body.length), body);
}

export type Authenticator = { credId: Uint8Array; keys: CryptoKeyPair; userHandle: string; counter: number };

export async function newAuthenticator(): Promise<Authenticator> {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  return { credId: crypto.getRandomValues(new Uint8Array(16)), keys, userHandle: "", counter: 0 };
}

const FLAGS_UP_UV = 0x01 | 0x04;

async function authData(rpID: string, flags: number, counter: number, attested?: Uint8Array) {
  const c = new Uint8Array(4);
  new DataView(c.buffer).setUint32(0, counter);
  return concat(await sha256(enc.encode(rpID)), Uint8Array.of(flags), c, attested ?? new Uint8Array());
}

/** navigator.credentials.create() as a phone would answer it. */
export async function register(a: Authenticator, options: any, opts: { origin?: string; rpID?: string; uv?: boolean } = {}) {
  const jwk = await crypto.subtle.exportKey("jwk", a.keys.publicKey) as JsonWebKey;
  const cose = cbor(new Map<number, unknown>([[1, 2], [3, -7], [-1, 1], [-2, unb64url(jwk.x!)], [-3, unb64url(jwk.y!)]]));
  const idLen = Uint8Array.of(a.credId.length >> 8, a.credId.length & 255);
  const attested = concat(new Uint8Array(16), idLen, a.credId, cose);
  const flags = (opts.uv === false ? 0x01 : FLAGS_UP_UV) | 0x40;
  const ad = await authData(opts.rpID ?? options.rp.id, flags, a.counter, attested);
  const clientDataJSON = enc.encode(JSON.stringify({ type: "webauthn.create", challenge: options.challenge, origin: opts.origin ?? BASE, crossOrigin: false }));
  const attestationObject = cbor(new Map<string, unknown>([["fmt", "none"], ["attStmt", new Map()], ["authData", ad]]));
  a.userHandle = options.user.id;
  return {
    id: b64url(a.credId), rawId: b64url(a.credId), type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "platform",
    response: { clientDataJSON: b64url(clientDataJSON), attestationObject: b64url(attestationObject), transports: ["internal", "hybrid"] },
  };
}

/** navigator.credentials.get() as a phone would answer it. */
export async function assert(a: Authenticator, options: any, opts: { origin?: string } = {}) {
  a.counter += 1;
  const ad = await authData(options.rpId, FLAGS_UP_UV, a.counter);
  const clientDataJSON = enc.encode(JSON.stringify({ type: "webauthn.get", challenge: options.challenge, origin: opts.origin ?? BASE, crossOrigin: false }));
  const signed = concat(ad, await sha256(clientDataJSON));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, a.keys.privateKey, signed));
  return {
    id: b64url(a.credId), rawId: b64url(a.credId), type: "public-key", clientExtensionResults: {}, authenticatorAttachment: "platform",
    response: { clientDataJSON: b64url(clientDataJSON), authenticatorData: b64url(ad), signature: b64url(derSignature(sig)), userHandle: a.userHandle },
  };
}

// ---------------------------------------------------------------- engine calls

export const api = (path: string, body: unknown, opts: { origin?: string | null; cookie?: string } = {}) => {
  const headers: Record<string, string> = {};
  if (opts.origin !== null) headers.Origin = opts.origin ?? BASE;
  if (opts.cookie) headers.Cookie = opts.cookie;
  return call(path, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
};
export const me = (cookie?: string, extra: Record<string, string> = {}) => call("/app/api/me", { headers: { ...(cookie ? { Cookie: cookie } : {}), ...extra } });

export async function pairCode(key: string): Promise<string> {
  const r = await call("/v2/app/pair", { method: "POST", key });
  expect(r.status).toBe(200);
  const { url } = await r.json<{ url: string }>();
  return /#pair=(.+)$/.exec(url)![1];
}

export const cookieOf = (r: Response) => /fb_session=([^;]*)/.exec(r.headers.get("Set-Cookie") ?? "")?.[0] ?? null;

/** Pair a phone end to end; returns the authenticator and the session cookie. */
export async function pairPhone(key: string, deviceName = "Test phone") {
  const code = await pairCode(key);
  const opt = await api("/app/api/pair/options", { code });
  expect(opt.status).toBe(200);
  const options = await opt.json<any>();
  const a = await newAuthenticator();
  const fin = await api("/app/api/pair/finish", { code, response: await register(a, options), deviceName });
  expect(fin.status).toBe(200);
  return { a, code, cookie: cookieOf(fin)!, fin };
}

export async function login(a: Authenticator, opts: { origin?: string } = {}) {
  const o = await api("/app/api/login/options", {});
  expect(o.status).toBe(200);
  const { challengeId, options } = await o.json<any>();
  return api("/app/api/login/finish", { challengeId, response: await assert(a, options, opts) });
}

export const count = async (sql: string, ...args: unknown[]) => (await env.DB.prepare(sql).bind(...args).first<{ n: number }>())!.n;

