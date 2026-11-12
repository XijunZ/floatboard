import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "./helpers";
import { api, count, pairPhone } from "./app-helpers";
import { b64url, encryptPayload, setPushFetch, unb64url, vapidAuthorization, vapidKeys } from "../src/app/webpush";
import { alertFor, setNtfyFetch } from "../src/alerts";
import { removeDevice } from "../src/app/auth";

const enc = new TextEncoder();
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}

/** The user agent's side of RFC 8291: decrypt an aes128gcm body with the phone's private key. */
async function decryptAsPhone(body: Uint8Array, uaPublic: string, uaPrivate: CryptoKey, auth: string): Promise<string> {
  const salt = body.slice(0, 16);
  const rs = new DataView(body.buffer, body.byteOffset).getUint32(16);
  expect(rs).toBe(4096);
  const idlen = body[20];
  const asPublic = body.slice(21, 21 + idlen);
  const ct = body.slice(21 + idlen);
  const asKey = await crypto.subtle.importKey("raw", asPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: asKey } as unknown as SubtleCryptoDeriveKeyAlgorithm, uaPrivate, 256));
  const ikm = await hkdf(unb64url(auth), ecdh, concat(enc.encode("WebPush: info\0"), unb64url(uaPublic), asPublic), 32);
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["decrypt"]);
  const padded = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, ct));
  let end = padded.length - 1;
  while (padded[end] === 0) end--;
  expect(padded[end]).toBe(2); // last-record delimiter
  return new TextDecoder().decode(padded.slice(0, end));
}

/** A phone's push subscription keys (a fresh ECDH P-256 key pair and auth secret). */
async function phoneKeys() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const p256dh = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer));
  return { p256dh, auth: b64url(crypto.getRandomValues(new Uint8Array(16))), privateKey: pair.privateKey };
}

type Sent = { url: string; headers: Record<string, string>; body: Uint8Array };
let sent: Sent[] = [];
let pushStatus = 201;
beforeEach(() => {
  sent = []; pushStatus = 201;
  setPushFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ url: String(url), headers: init?.headers as Record<string, string>, body: new Uint8Array(init!.body as Uint8Array) });
    return new Response("", { status: pushStatus });
  }) as typeof fetch);
  setNtfyFetch((async () => new Response("{}")) as typeof fetch);
});

const del = (path: string, opts: { cookie?: string; origin?: string | null } = {}) => {
  const headers: Record<string, string> = {};
  if (opts.origin !== null) headers.Origin = opts.origin ?? BASE;
  if (opts.cookie) headers.Cookie = opts.cookie;
  return call(path, { method: "DELETE", headers });
};

async function subscribe(cookie: string, endpoint: string) {
  const k = await phoneKeys();
  const r = await api("/app/api/push/subscribe", { endpoint, keys: { p256dh: k.p256dh, auth: k.auth } }, { cookie });
  expect(r.status).toBe(200);
  return k;
}

describe("RFC 8291 encryption", () => {
  // RFC 8291, Appendix A.
  const V = {
    plaintext: "When I grow up, I want to be a watermelon",
    asPublic: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    asPrivate: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
    uaPublic: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    uaPrivate: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
    salt: "DGv6ra1nlYgDCS1FRnbzlw",
    auth: "BTBZMqHH6r4Tts7J_aSIgg",
    body: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  };

  it("reproduces the RFC 8291 example body exactly", async () => {
    const out = await encryptPayload({ p256dh: V.uaPublic, auth: V.auth }, V.plaintext,
      { salt: unb64url(V.salt), asPrivate: V.asPrivate, asPublic: V.asPublic });
    expect(b64url(out)).toBe(V.body);
  });

  it("the phone can decrypt it (random salt and sender key)", async () => {
    const ua = unb64url(V.uaPublic);
    const uaPrivate = await crypto.subtle.importKey("jwk", {
      kty: "EC", crv: "P-256", d: V.uaPrivate, x: b64url(ua.slice(1, 33)), y: b64url(ua.slice(33)),
    }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
    const out = await encryptPayload({ p256dh: V.uaPublic, auth: V.auth }, V.plaintext);
    expect(await decryptAsPhone(out, V.uaPublic, uaPrivate, V.auth)).toBe(V.plaintext);
    expect(b64url(out)).not.toBe(V.body);
  });
});

describe("VAPID", () => {
  it("key is made once and the JWT verifies with the published key", async () => {
    const k1 = await vapidKeys(env as any);
    const k2 = await vapidKeys(env as any);
    expect(k2.publicKey).toBe(k1.publicKey);
    expect(unb64url(k1.publicKey)).toHaveLength(65);
    expect(await count("SELECT COUNT(*) n FROM app_keys WHERE name='vapid'")).toBe(1);
    const stored = (await env.DB.prepare("SELECT value_enc v FROM app_keys").first<{ v: string }>())!.v;
    expect(stored).not.toContain('"d"');

    const now = Date.now();
    const h = await vapidAuthorization(k1, "https://push.example.net/send/abc?x=1", "https://engine.test/app", now);
    const m = /^vapid t=([^.]+)\.([^.]+)\.([^,]+), k=(.+)$/.exec(h)!;
    expect(m).not.toBeNull();
    expect(m[4]).toBe(k1.publicKey);
    expect(JSON.parse(new TextDecoder().decode(unb64url(m[1])))).toEqual({ typ: "JWT", alg: "ES256" });
    const claims = JSON.parse(new TextDecoder().decode(unb64url(m[2])));
    expect(claims.aud).toBe("https://push.example.net");
    expect(claims.sub).toBe("https://engine.test/app");
    expect(claims.exp).toBe(Math.floor(now / 1000) + 12 * 3600);
    const pub = await crypto.subtle.importKey("raw", unb64url(m[4]), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, unb64url(m[3]), enc.encode(`${m[1]}.${m[2]}`));
    expect(ok).toBe(true);
  });
});

describe("push routes", () => {
  it("key needs a session; subscribe and unsubscribe need a session and the same origin", async () => {
    const u = await newUser("P1");
    const { cookie } = await pairPhone(u.key);
    expect((await call("/app/api/push/key")).status).toBe(401);
    const kr = await call("/app/api/push/key", { headers: { Cookie: cookie } });
    expect(kr.status).toBe(200);
    expect(unb64url((await kr.json<{ key: string }>()).key)).toHaveLength(65);

    const k = await phoneKeys();
    const body = { endpoint: "https://push.example.net/s/1", keys: { p256dh: k.p256dh, auth: k.auth } };
    expect((await api("/app/api/push/subscribe", body)).status).toBe(401);
    expect((await api("/app/api/push/subscribe", body, { cookie, origin: "https://evil.test" })).status).toBe(403);
    expect((await api("/app/api/push/subscribe", body, { cookie, origin: null })).status).toBe(403);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(0);

    expect((await api("/app/api/push/subscribe", body, { cookie })).status).toBe(200);
    expect((await api("/app/api/push/subscribe", { ...body, endpoint: "https://push.example.net/s/2" }, { cookie })).status).toBe(200);
    const rows = (await env.DB.prepare("SELECT endpoint, origin FROM app_push WHERE user_id=?").bind(u.id).all<any>()).results;
    expect(rows).toEqual([{ endpoint: "https://push.example.net/s/2", origin: BASE }]); // one row per phone, replaced

    expect((await del("/app/api/push/subscribe", { cookie, origin: "https://evil.test" })).status).toBe(403);
    expect((await del("/app/api/push/subscribe")).status).toBe(401);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(1);
    expect((await del("/app/api/push/subscribe", { cookie })).status).toBe(200);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(0);
  });

  it("subscribe refuses bad endpoints and keys", async () => {
    const u = await newUser("P2");
    const { cookie } = await pairPhone(u.key);
    const k = await phoneKeys();
    const ok = { endpoint: "https://push.example.net/s/1", keys: { p256dh: k.p256dh, auth: k.auth } };
    for (const bad of [
      { ...ok, endpoint: "http://push.example.net/s/1" },
      { ...ok, endpoint: "not a url" },
      { ...ok, endpoint: "https://x.test/" + "a".repeat(2100) },
      { endpoint: ok.endpoint },
      { ...ok, keys: { ...ok.keys, p256dh: b64url(new Uint8Array(33)) } },
      { ...ok, keys: { ...ok.keys, auth: b64url(new Uint8Array(8)) } },
      { ...ok, keys: { ...ok.keys, auth: "***" } },
    ]) {
      expect((await api("/app/api/push/subscribe", bad, { cookie })).status).toBe(400);
    }
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(0);
  });

  it("test notification goes to this phone only, encrypted, with VAPID headers", async () => {
    const u = await newUser("P3");
    const one = await pairPhone(u.key, "Phone one");
    const two = await pairPhone(u.key, "Phone two");
    const k1 = await subscribe(one.cookie, "https://push.example.net/s/one");
    await subscribe(two.cookie, "https://push.example.net/s/two");
    const r = await api("/app/api/push/test", {}, { cookie: one.cookie });
    expect(r.status).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe("https://push.example.net/s/one");
    expect(sent[0].headers).toMatchObject({ TTL: "86400", Urgency: "high", "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream" });
    expect(sent[0].headers.Authorization).toMatch(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+$/);
    const msg = JSON.parse(await decryptAsPhone(sent[0].body, k1.p256dh, k1.privateKey, k1.auth));
    expect(msg).toEqual({ title: "FloatBoard test notification", body: "Notifications work on this phone.", url: "/app/" });
    expect((await api("/app/api/push/test", {}, { cookie: one.cookie, origin: "https://evil.test" })).status).toBe(403);
  });

  it("a 410 from the push service deletes the subscription", async () => {
    const u = await newUser("P4");
    const { cookie } = await pairPhone(u.key);
    await subscribe(cookie, "https://push.example.net/s/gone");
    pushStatus = 410;
    expect((await api("/app/api/push/test", {}, { cookie })).status).toBe(410);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(0);
    expect((await api("/app/api/push/test", {}, { cookie })).status).toBe(409);
  });
});

describe("alert fan-out to phones", () => {
  const item = { id: "i1", title: "Pay invoice", why: "Due tomorrow", sender: "Acme <ap@acme.com>", due: "2026-11-08", link: "https://mail/1" };

  it("pushes to every phone of that user only", async () => {
    const a = await newUser("PA");
    const b = await newUser("PB");
    const a1 = await pairPhone(a.key, "A one");
    const a2 = await pairPhone(a.key, "A two");
    const b1 = await pairPhone(b.key, "B one");
    const k1 = await subscribe(a1.cookie, "https://push.example.net/a1");
    await subscribe(a2.cookie, "https://push.example.net/a2");
    await subscribe(b1.cookie, "https://push.example.net/b1");
    await alertFor(env as any, a.id)(item);
    expect(sent.map((s) => s.url).sort()).toEqual(["https://push.example.net/a1", "https://push.example.net/a2"]);
    const msg = JSON.parse(await decryptAsPhone(sent.find((s) => s.url.endsWith("/a1"))!.body, k1.p256dh, k1.privateKey, k1.auth));
    expect(msg.title).toBe("Pay invoice");
    expect(msg.body).toContain("Due: 2026-11-08");
    expect(msg.body).toContain("From: Acme <ap@acme.com>");
    expect(msg.url).toBe("https://mail/1");

    sent = [];
    await alertFor(env as any, a.id)({ ...item, link: "" });
    expect(JSON.parse(await decryptAsPhone(sent.find((s) => s.url.endsWith("/a1"))!.body, k1.p256dh, k1.privateKey, k1.auth)).url).toBe("/app/");
  });

  it("counts as sent if any phone got it; a gone phone is removed; throws when every phone fails", async () => {
    const u = await newUser("PC");
    const p1 = await pairPhone(u.key, "One");
    const p2 = await pairPhone(u.key, "Two");
    await subscribe(p1.cookie, "https://push.example.net/c1");
    await subscribe(p2.cookie, "https://push.example.net/c2");
    setPushFetch((async (url: RequestInfo | URL) => new Response("", { status: String(url).endsWith("c1") ? 410 : 201 })) as typeof fetch);
    await alertFor(env as any, u.id)(item); // c2 got it: no throw
    expect((await env.DB.prepare("SELECT endpoint FROM app_push WHERE user_id=?").bind(u.id).all<any>()).results)
      .toEqual([{ endpoint: "https://push.example.net/c2" }]);
    setPushFetch((async () => new Response("", { status: 500 })) as typeof fetch);
    await expect(alertFor(env as any, u.id)(item)).rejects.toThrow(/webpush: push failed \(500\)/);
  });

  it("user without subscriptions: push skipped, nothing sent", async () => {
    const u = await newUser("PD");
    await alertFor(env as any, u.id)(item);
    expect(sent).toHaveLength(0);
  });

  it("removing a phone deletes its subscription", async () => {
    const u = await newUser("PE");
    const p = await pairPhone(u.key);
    await subscribe(p.cookie, "https://push.example.net/e1");
    const dev = (await env.DB.prepare("SELECT id FROM app_devices WHERE user_id=?").bind(u.id).first<{ id: string }>())!.id;
    expect(await removeDevice(env as any, u.id, dev)).toBe("Test phone");
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE device_id=?", dev)).toBe(0);
  });
});
