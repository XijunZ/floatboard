import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, form, get, newUser, signIn } from "./helpers";

// ---------------------------------------------------------------- a software authenticator (ES256, attestation "none")

const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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

type Authenticator = { credId: Uint8Array; keys: CryptoKeyPair; userHandle: string; counter: number };

async function newAuthenticator(): Promise<Authenticator> {
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
async function register(a: Authenticator, options: any, opts: { origin?: string; rpID?: string; uv?: boolean } = {}) {
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
async function assert(a: Authenticator, options: any, opts: { origin?: string } = {}) {
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

const api = (path: string, body: unknown, opts: { origin?: string | null; cookie?: string } = {}) => {
  const headers: Record<string, string> = {};
  if (opts.origin !== null) headers.Origin = opts.origin ?? BASE;
  if (opts.cookie) headers.Cookie = opts.cookie;
  return call(path, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
};
const me = (cookie?: string, extra: Record<string, string> = {}) => call("/app/api/me", { headers: { ...(cookie ? { Cookie: cookie } : {}), ...extra } });

async function pairCode(key: string): Promise<string> {
  const r = await call("/v2/app/pair", { method: "POST", key });
  expect(r.status).toBe(200);
  const { url } = await r.json<{ url: string }>();
  return /#pair=(.+)$/.exec(url)![1];
}

const cookieOf = (r: Response) => /fb_session=([^;]*)/.exec(r.headers.get("Set-Cookie") ?? "")?.[0] ?? null;

/** Pair a phone end to end; returns the authenticator and the session cookie. */
async function pairPhone(key: string, deviceName = "Test phone") {
  const code = await pairCode(key);
  const opt = await api("/app/api/pair/options", { code });
  expect(opt.status).toBe(200);
  const options = await opt.json<any>();
  const a = await newAuthenticator();
  const fin = await api("/app/api/pair/finish", { code, response: await register(a, options), deviceName });
  expect(fin.status).toBe(200);
  return { a, code, cookie: cookieOf(fin)!, fin };
}

async function login(a: Authenticator, opts: { origin?: string } = {}) {
  const o = await api("/app/api/login/options", {});
  expect(o.status).toBe(200);
  const { challengeId, options } = await o.json<any>();
  return api("/app/api/login/finish", { challengeId, response: await assert(a, options, opts) });
}

const count = async (sql: string, ...args: unknown[]) => (await env.DB.prepare(sql).bind(...args).first<{ n: number }>())!.n;

// ---------------------------------------------------------------- tests

describe("phone pairing", () => {
  it("pair_link_needs_the_user_key_and_lasts_ten_minutes", async () => {
    expect((await call("/v2/app/pair", { method: "POST" })).status).toBe(401);
    const u = await newUser("Pairer");
    const r = await call("/v2/app/pair", { method: "POST", key: u.key });
    const body = await r.json<{ url: string; expires: string }>();
    expect(body.url).toMatch(new RegExp(`^${BASE}/app/#pair=[A-Za-z0-9_-]{43}$`));
    const ms = Date.parse(body.expires) - Date.now();
    expect(ms).toBeGreaterThan(9 * 60_000);
    expect(ms).toBeLessThanOrEqual(10 * 60_000);
    const code = /#pair=(.+)$/.exec(body.url)![1];
    // Stored only as a hash.
    expect(await count("SELECT COUNT(*) n FROM app_pairings WHERE code_hash=?", code)).toBe(0);
    expect(await count("SELECT COUNT(*) n FROM app_pairings WHERE user_id=?", u.id)).toBe(1);
  });

  it("registration_options_are_passkey_options_for_this_host", async () => {
    const u = await newUser("Opts User");
    const first = await pairPhone(u.key);
    const code = await pairCode(u.key);
    const r = await api("/app/api/pair/options", { code });
    const o = await r.json<any>();
    expect(o.rp).toEqual({ name: "FloatBoard", id: "engine.test" });
    expect(o.user.name).toBe("Opts User");
    expect(o.authenticatorSelection.residentKey).toBe("required");
    expect(o.authenticatorSelection.userVerification).toBe("required");
    expect(o.attestation).toBe("none");
    expect(o.pubKeyCredParams.map((p: any) => p.alg).sort()).toEqual([-257, -7]);
    expect(o.excludeCredentials.map((c: any) => c.id)).toEqual([b64url(first.a.credId)]);
    expect(typeof o.challenge).toBe("string");
  });

  it("finish_creates_device_credential_and_session_with_exact_cookie_flags", async () => {
    const u = await newUser("Finisher");
    const { cookie, fin } = await pairPhone(u.key, "Pixel");
    expect(fin.headers.get("Set-Cookie")).toMatch(/^fb_session=[A-Za-z0-9_-]{43}; HttpOnly; Secure; SameSite=Strict; Path=\/app; Max-Age=7776000$/);
    expect(await fin.json()).toEqual({ ok: true, user: "Finisher", device: "Pixel" });
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=? AND name='Pixel' AND revoked=0", u.id)).toBe(1);
    expect(await count("SELECT COUNT(*) n FROM app_credentials WHERE user_id=?", u.id)).toBe(1);
    expect(await count("SELECT COUNT(*) n FROM app_sessions WHERE user_id=?", u.id)).toBe(1);
    const token = cookie.split("=")[1];
    expect(await count("SELECT COUNT(*) n FROM app_sessions WHERE token_hash=?", token)).toBe(0); // only the hash is stored
    const m = await me(cookie);
    expect(m.status).toBe(200);
    expect(await m.json()).toEqual({ user: "Finisher", device: "Pixel" });
  });

  it("pairing_code_is_single_use", async () => {
    const u = await newUser("Once");
    const { code } = await pairPhone(u.key);
    expect((await api("/app/api/pair/options", { code })).status).toBe(400);
    // Even with a fresh, otherwise valid registration for the old challenge, no second device appears.
    const row = await env.DB.prepare("SELECT challenge FROM app_pairings WHERE user_id=?").bind(u.id).first<{ challenge: string | null }>();
    const fake = await register(await newAuthenticator(), { rp: { id: "engine.test" }, user: { id: "x" }, challenge: row?.challenge ?? "x" });
    expect((await api("/app/api/pair/finish", { code, response: fake, deviceName: "Second" })).status).toBe(400);
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=?", u.id)).toBe(1);
  });

  it("failed_verification_does_not_burn_the_code", async () => {
    const u = await newUser("Retry");
    const code = await pairCode(u.key);
    const options = await (await api("/app/api/pair/options", { code })).json<any>();
    const a = await newAuthenticator();
    const bad = await api("/app/api/pair/finish", { code, response: await register(a, options, { origin: "https://evil.example.com" }), deviceName: "P" });
    expect(bad.status).toBe(400);
    expect(bad.headers.get("Set-Cookie")).toBeNull();
    const noUV = await api("/app/api/pair/finish", { code, response: await register(a, options, { uv: false }), deviceName: "P" });
    expect(noUV.status).toBe(400);
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=?", u.id)).toBe(0);
    const ok = await api("/app/api/pair/finish", { code, response: await register(a, options), deviceName: "P" });
    expect(ok.status).toBe(200);
  });

  it("expired_code_is_refused", async () => {
    const u = await newUser("Late");
    const code = await pairCode(u.key);
    await env.DB.prepare("UPDATE app_pairings SET expires=? WHERE user_id=?").bind(new Date(Date.now() - 1000).toISOString(), u.id).run();
    expect((await api("/app/api/pair/options", { code })).status).toBe(400);
    expect((await api("/app/api/pair/options", { code: "not-a-code" })).status).toBe(400);
  });

  it("code_expiring_between_options_and_finish_is_refused", async () => {
    const u = await newUser("Slow");
    const code = await pairCode(u.key);
    const options = await (await api("/app/api/pair/options", { code })).json<any>();
    await env.DB.prepare("UPDATE app_pairings SET expires=? WHERE user_id=?").bind(new Date(Date.now() - 1000).toISOString(), u.id).run();
    const r = await api("/app/api/pair/finish", { code, response: await register(await newAuthenticator(), options), deviceName: "P" });
    expect(r.status).toBe(400);
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=?", u.id)).toBe(0);
  });

  it("state_changing_calls_from_another_origin_are_refused", async () => {
    const u = await newUser("Origin");
    const code = await pairCode(u.key);
    for (const origin of ["https://evil.example.com", null]) {
      expect((await api("/app/api/pair/options", { code }, { origin })).status).toBe(403);
      expect((await api("/app/api/pair/finish", { code, response: {} }, { origin })).status).toBe(403);
      expect((await api("/app/api/login/options", {}, { origin })).status).toBe(403);
      expect((await api("/app/api/login/finish", {}, { origin })).status).toBe(403);
      expect((await api("/app/api/logout", {}, { origin })).status).toBe(403);
    }
    expect((await api("/app/api/pair/options", { code })).status).toBe(200);
  });
});

describe("phone sign-in and sessions", () => {
  it("login_with_assertion_creates_a_session", async () => {
    const u = await newUser("Login User");
    const { a } = await pairPhone(u.key, "Phone A");
    const o = await api("/app/api/login/options", {});
    const { challengeId, options } = await o.json<any>();
    expect(typeof challengeId).toBe("string");
    expect(options.rpId).toBe("engine.test");
    expect(options.userVerification).toBe("required");
    expect(options.allowCredentials ?? []).toEqual([]);
    const response = await assert(a, options);
    const r = await api("/app/api/login/finish", { challengeId, response });
    expect(r.status).toBe(200);
    expect(r.headers.get("Set-Cookie")).toMatch(/^fb_session=[A-Za-z0-9_-]{43}; HttpOnly; Secure; SameSite=Strict; Path=\/app; Max-Age=7776000$/);
    expect(await (await me(cookieOf(r)!)).json()).toEqual({ user: "Login User", device: "Phone A" });
    expect(await count("SELECT counter n FROM app_credentials WHERE user_id=?", u.id)).toBe(1);
    expect(await count("SELECT COUNT(*) n FROM app_sessions WHERE user_id=?", u.id)).toBe(2);
    // The challenge is single use.
    expect((await api("/app/api/login/finish", { challengeId, response })).status).toBe(400);
  });

  it("login_from_wrong_origin_or_unknown_credential_is_refused", async () => {
    const u = await newUser("Wrong");
    const { a } = await pairPhone(u.key);
    expect((await login(a, { origin: "https://evil.example.com" })).status).toBe(400);
    expect((await login(await newAuthenticator())).status).toBe(400);
  });

  it("expired_login_challenge_is_refused", async () => {
    const u = await newUser("Stale");
    const { a } = await pairPhone(u.key);
    const { challengeId, options } = await (await api("/app/api/login/options", {})).json<any>();
    await env.DB.prepare("UPDATE app_challenges SET expires=? WHERE id=?").bind(new Date(Date.now() - 1000).toISOString(), challengeId).run();
    expect((await api("/app/api/login/finish", { challengeId, response: await assert(a, options) })).status).toBe(400);
  });

  it("revoked_device_is_refused_and_removed_from_setup", async () => {
    const u = await newUser("Revoker");
    const { a, cookie } = await pairPhone(u.key, "Old phone");
    const s = await signIn(u.key);
    expect(s.page).toContain("Old phone");
    expect(s.page).toContain("Pair a phone");
    const dev = await env.DB.prepare("SELECT id FROM app_devices WHERE user_id=?").bind(u.id).first<{ id: string }>();
    // Without the CSRF token nothing happens.
    expect((await form("/setup/phones/remove", { device_id: dev!.id }, { cookie: s.cookie })).status).toBe(403);
    expect((await me(cookie)).status).toBe(200);
    const r = await form("/setup/phones/remove", { csrf: s.csrf, device_id: dev!.id }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    const html = await r.text();
    expect(html).toContain("Old phone removed");
    expect(await count("SELECT revoked n FROM app_devices WHERE id=?", dev!.id)).toBe(1);
    expect(await count("SELECT COUNT(*) n FROM app_sessions WHERE device_id=?", dev!.id)).toBe(0);
    expect(await count("SELECT COUNT(*) n FROM app_credentials WHERE device_id=?", dev!.id)).toBe(0);
    expect((await me(cookie)).status).toBe(401);
    expect((await login(a)).status).toBe(400);
    expect(await (await get("/setup", s.cookie)).text()).not.toContain("Old phone");
  });

  it("a_device_whose_row_is_revoked_cannot_use_a_live_session_or_credential", async () => {
    const u = await newUser("Revoked Row");
    const { a, cookie } = await pairPhone(u.key);
    await env.DB.prepare("UPDATE app_devices SET revoked=1 WHERE user_id=?").bind(u.id).run();
    expect((await me(cookie)).status).toBe(401);
    expect((await login(a)).status).toBe(400);
  });

  it("another_users_phone_cannot_be_removed", async () => {
    const owner = await newUser("Owner");
    const { cookie } = await pairPhone(owner.key);
    const other = await newUser("Other");
    const s = await signIn(other.key);
    const dev = await env.DB.prepare("SELECT id FROM app_devices WHERE user_id=?").bind(owner.id).first<{ id: string }>();
    expect((await form("/setup/phones/remove", { csrf: s.csrf, device_id: dev!.id }, { cookie: s.cookie })).status).toBe(404);
    expect((await me(cookie)).status).toBe(200);
  });

  it("expired_session_is_refused", async () => {
    const u = await newUser("Expired");
    const { cookie } = await pairPhone(u.key);
    await env.DB.prepare("UPDATE app_sessions SET expires=? WHERE user_id=?").bind(new Date(Date.now() - 1000).toISOString(), u.id).run();
    expect((await me(cookie)).status).toBe(401);
  });

  it("session_older_than_a_day_is_renewed_with_a_new_cookie", async () => {
    const u = await newUser("Renew");
    const { cookie } = await pairPhone(u.key);
    // Fresh session: no renewal.
    expect((await me(cookie)).headers.get("Set-Cookie")).toBeNull();
    // Last renewed two days ago (expires in 88 days).
    const old = new Date(Date.now() + 88 * 86400_000).toISOString();
    await env.DB.prepare("UPDATE app_sessions SET expires=? WHERE user_id=?").bind(old, u.id).run();
    const r = await me(cookie);
    expect(r.status).toBe(200);
    expect(r.headers.get("Set-Cookie")).toBe(`${cookie}; HttpOnly; Secure; SameSite=Strict; Path=/app; Max-Age=7776000`);
    const row = await env.DB.prepare("SELECT expires FROM app_sessions WHERE user_id=?").bind(u.id).first<{ expires: string }>();
    expect(Date.parse(row!.expires) - Date.now()).toBeGreaterThan(89.9 * 86400_000);
    const dev = await env.DB.prepare("SELECT last_seen FROM app_devices WHERE user_id=?").bind(u.id).first<{ last_seen: string | null }>();
    expect(dev!.last_seen).not.toBeNull();
  });

  it("logout_deletes_the_session_and_clears_the_cookie", async () => {
    const u = await newUser("Leaver");
    const { cookie } = await pairPhone(u.key);
    const r = await api("/app/api/logout", {}, { cookie });
    expect(r.status).toBe(200);
    expect(r.headers.get("Set-Cookie")).toBe("fb_session=; HttpOnly; Secure; SameSite=Strict; Path=/app; Max-Age=0");
    expect((await me(cookie)).status).toBe(401);
    expect(await count("SELECT COUNT(*) n FROM app_sessions WHERE user_id=?", u.id)).toBe(0);
  });

  it("cookie_is_not_accepted_on_v2", async () => {
    const u = await newUser("Cookie V2");
    const { cookie } = await pairPhone(u.key);
    expect((await call("/v2/app/pair", { method: "POST", headers: { Cookie: cookie } })).status).toBe(401);
    expect((await call("/v2/status", { headers: { Cookie: cookie } })).status).toBe(401);
  });

  it("user_key_is_not_accepted_on_app_api", async () => {
    const u = await newUser("Key App");
    await pairPhone(u.key);
    expect((await me(undefined, { Authorization: `Bearer ${u.key}` })).status).toBe(401);
    expect((await me()).status).toBe(401);
    expect((await me("fb_session=garbage")).status).toBe(401);
  });

  it("each_session_sees_only_its_own_user", async () => {
    const one = await newUser("First Person");
    const two = await newUser("Second Person");
    const p1 = await pairPhone(one.key, "Phone 1");
    const p2 = await pairPhone(two.key, "Phone 2");
    expect(await (await me(p1.cookie)).json()).toEqual({ user: "First Person", device: "Phone 1" });
    expect(await (await me(p2.cookie)).json()).toEqual({ user: "Second Person", device: "Phone 2" });
    // The second user's code can't be used to register against the first user's pairing either.
    const code1 = await pairCode(one.key);
    const code2 = await pairCode(two.key);
    const o2 = await (await api("/app/api/pair/options", { code: code2 })).json<any>();
    expect((await api("/app/api/pair/finish", { code: code1, response: await register(await newAuthenticator(), o2), deviceName: "X" })).status).toBe(400);
  });
});
