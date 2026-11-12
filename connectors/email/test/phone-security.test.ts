import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, form, get, newUser, signIn } from "./helpers";
import { api, assert, cookieOf, count, login, me, newAuthenticator, pairCode, pairPhone, register } from "./app-helpers";
import { b64url, setPushFetch, unb64url } from "../src/app/webpush";
import { alertFor, setNtfyFetch } from "../src/alerts";
import { removeDevice, handleAppAuth } from "../src/app/auth";
import { handleBoard } from "../src/app/board";
import { APP_JS } from "../src/app/client";
import { sha256Hex } from "../src/auth";

/** Fixes from the phone-app security review (I1-I3, M1-M7). Each test failed before its fix. */

const enc = new TextEncoder();
const FCM = "https://fcm.googleapis.com/fcm/send/";

type Sent = { url: string; init: RequestInit; body: Uint8Array };
let sent: Sent[] = [];
let pushStatus = 201;
let ntfy: { url: string; headers: Record<string, string>; body: string }[] = [];
beforeEach(() => {
  sent = []; pushStatus = 201; ntfy = [];
  setPushFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    sent.push({ url: String(url), init: init!, body: new Uint8Array(init!.body as Uint8Array) });
    return new Response("", { status: pushStatus });
  }) as typeof fetch);
  setNtfyFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    ntfy.push({ url: String(url), headers: init?.headers as Record<string, string>, body: String(init?.body) });
    return new Response("{}");
  }) as typeof fetch);
});

async function phoneKeys() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const p256dh = b64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer));
  return { p256dh, auth: b64url(crypto.getRandomValues(new Uint8Array(16))), privateKey: pair.privateKey };
}
const subscribeBody = async (endpoint: string) => { const k = await phoneKeys(); return { endpoint, keys: { p256dh: k.p256dh, auth: k.auth } }; };
const subscribe = async (cookie: string, endpoint: string) => api("/app/api/push/subscribe", await subscribeBody(endpoint), { cookie });
const deviceId = async (userId: string, name: string) =>
  (await env.DB.prepare("SELECT id FROM app_devices WHERE user_id=? AND name=? AND revoked=0").bind(userId, name).first<{ id: string }>())!.id;

/** The real D1 binding, except that `.first()` on statements matching `match` goes through `onFirst` (call number, real row). */
function hookedEnv(match: RegExp, onFirst: (n: number, row: unknown) => Promise<unknown>) {
  let n = 0;
  const DB = new Proxy(env.DB, {
    get(t, p) {
      if (p === "prepare") {
        return (sql: string) => {
          const st = t.prepare(sql);
          if (!match.test(sql)) return st;
          const bind = st.bind.bind(st);
          (st as any).bind = (...a: unknown[]) => {
            const b = bind(...a);
            const first = b.first.bind(b);
            (b as any).first = async (...x: any[]) => { const r = await (first as any)(...x); const o = await onFirst(++n, r); return o === undefined ? r : o; };
            return b;
          };
          return st;
        };
      }
      const v = Reflect.get(t, p);
      return typeof v === "function" ? v.bind(t) : v;
    },
  });
  return { ...(env as any), DB };
}

// ---------------------------------------------------------------- I1

describe("I1 a device is one browser install", () => {
  it("i1_passkey_sign_in_on_a_second_browser_makes_its_own_device", async () => {
    const u = await newUser("Synced");
    const first = await pairPhone(u.key, "iPhone", "install-iphone");
    const r = await login(first.a, { deviceName: "iPad", installId: "install-ipad" });
    expect(r.status).toBe(200);
    const ipad = cookieOf(r)!;
    expect((await (await me(first.cookie)).json<any>()).device).toBe("iPhone");
    expect((await (await me(ipad)).json<any>()).device).toBe("iPad");
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=? AND revoked=0", u.id)).toBe(2);

    // Push subscriptions are per device: the iPad's doesn't replace the iPhone's.
    expect((await subscribe(first.cookie, FCM + "iphone")).status).toBe(200);
    expect((await subscribe(ipad, FCM + "ipad")).status).toBe(200);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", u.id)).toBe(2);

    // The setup page lists both.
    const s = await signIn(u.key);
    expect(s.page).toContain("iPhone");
    expect(s.page).toContain("iPad");

    // Removing the iPad ends only the iPad; the shared passkey keeps working while the iPhone uses it.
    expect(await removeDevice(env as any, u.id, await deviceId(u.id, "iPad"))).toBe("iPad");
    expect((await me(ipad)).status).toBe(401);
    expect((await me(first.cookie)).status).toBe(200);
    expect((await env.DB.prepare("SELECT endpoint FROM app_push WHERE user_id=?").bind(u.id).all<any>()).results).toEqual([{ endpoint: FCM + "iphone" }]);
    expect((await login(first.a, { deviceName: "iPhone", installId: "install-iphone" })).status).toBe(200);

    // Signing in again on the same browser reuses its device; removing the last device using the passkey deletes it.
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=? AND revoked=0", u.id)).toBe(1);
    await removeDevice(env as any, u.id, await deviceId(u.id, "iPhone"));
    expect(await count("SELECT COUNT(*) n FROM app_credentials WHERE user_id=?", u.id)).toBe(0);
    expect((await login(first.a, { deviceName: "iPad", installId: "install-ipad" })).status).toBe(400);
  });

  it("i1_a_removed_passkey_cannot_sign_in_anywhere", async () => {
    const u = await newUser("Removed key");
    const one = await pairPhone(u.key, "Phone");
    await removeDevice(env as any, u.id, await deviceId(u.id, "Phone"));
    expect((await login(one.a, { deviceName: "Other", installId: "other" })).status).toBe(400);
    expect((await me(one.cookie)).status).toBe(401);
  });
});

// ---------------------------------------------------------------- I2

describe("I2 one browser, one account", () => {
  it("i2_saving_a_subscription_drops_the_same_endpoint_for_anyone_else", async () => {
    const a = await newUser("Shared A");
    const b = await newUser("Shared B");
    const pa = await pairPhone(a.key, "Family iPad");
    const pb = await pairPhone(b.key, "Family iPad");
    expect((await subscribe(pa.cookie, FCM + "shared")).status).toBe(200);
    expect((await subscribe(pb.cookie, FCM + "shared")).status).toBe(200);
    const rows = (await env.DB.prepare("SELECT user_id FROM app_push WHERE endpoint=?").bind(FCM + "shared").all<{ user_id: string }>()).results;
    expect(rows).toEqual([{ user_id: b.id }]);
    await alertFor(env as any, a.id)({ id: "x", title: "A's secret", why: "", sender: "", due: null, link: "" });
    expect(sent).toHaveLength(0);
  });

  it("i2_pairing_another_account_on_the_same_browser_ends_the_old_device", async () => {
    const a = await newUser("Browser A");
    const b = await newUser("Browser B");
    const pa = await pairPhone(a.key, "Old phone", "same-install");
    expect((await subscribe(pa.cookie, FCM + "old")).status).toBe(200);
    await pairPhone(b.key, "Old phone", "same-install");
    expect((await me(pa.cookie)).status).toBe(401);
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=? AND revoked=0", a.id)).toBe(0);
    expect(await count("SELECT COUNT(*) n FROM app_push WHERE user_id=?", a.id)).toBe(0);
  });

  it("i2_me_returns_a_stable_account_marker", async () => {
    const a = await newUser("Marker A");
    const b = await newUser("Marker B");
    const pa = await pairPhone(a.key);
    const pa2 = await pairPhone(a.key, "Second");
    const pb = await pairPhone(b.key);
    const ma = await (await me(pa.cookie)).json<any>();
    const ma2 = await (await me(pa2.cookie)).json<any>();
    const mb = await (await me(pb.cookie)).json<any>();
    expect(ma.account).toMatch(/^[0-9a-f]{16,}$/);
    expect(ma2.account).toBe(ma.account);
    expect(mb.account).not.toBe(ma.account);
    expect(ma.account).not.toContain(a.id);
  });

  it("i2_client_ties_the_cached_board_to_the_account_and_resets_the_browser_on_sign_in", () => {
    // The cached board is stored with the account marker and only shown after /me confirms the same account.
    expect(APP_JS).toContain("cached.account === me.account");
    // Pairing and sign-in drop the cache and unsubscribe the browser's old push subscription first.
    expect(APP_JS).toMatch(/function resetBrowser\(\)[\s\S]*store\(BOARD_KEY, null\)[\s\S]*unsubscribe\(\)/);
    expect((APP_JS.match(/await resetBrowser\(\)/g) ?? []).length).toBe(2);
    // The browser install id and device name go with pairing and sign-in.
    expect(APP_JS).toMatch(/pair\/finish[^\n]*installId: installId\(\)/);
    expect(APP_JS).toMatch(/login\/finish[^\n]*deviceName: defaultDeviceName\(\), installId: installId\(\)/);
  });
});

// ---------------------------------------------------------------- I3

describe("I3 push endpoints are push services only", () => {
  it("i3_subscribe_accepts_only_known_push_service_hosts", async () => {
    const u = await newUser("SSRF");
    const { cookie } = await pairPhone(u.key);
    for (const bad of ["https://victim.example/x", "https://engine.test/app/api/board", "https://fcm.googleapis.com:8443/fcm/send/x",
      "http://fcm.googleapis.com/fcm/send/x", "https://user:pw@fcm.googleapis.com/fcm/send/x", "https://fcm.googleapis.com.evil.example/x",
      "https://push.apple.com.evil.example/x", "https://evilpush.apple.com/x"]) {
      expect((await subscribe(cookie, bad)).status, bad).toBe(400);
    }
    for (const ok of [FCM + "a", "https://web.push.apple.com/QK", "https://updates.push.services.mozilla.com/wpush/v2/x",
      "https://wns2-par02p.notify.windows.com/w/?token=x"]) {
      expect((await subscribe(cookie, ok)).status, ok).toBe(200);
    }
  });

  it("i3_push_does_not_follow_redirects_and_the_test_route_hides_the_status", async () => {
    const u = await newUser("Redirect");
    const { cookie } = await pairPhone(u.key);
    expect((await subscribe(cookie, FCM + "r")).status).toBe(200);
    pushStatus = 302;
    const r = await api("/app/api/push/test", {}, { cookie });
    expect(r.status).toBe(502);
    expect(sent[0].init.redirect).toBe("manual");
    const body = await r.json<{ error: string }>();
    expect(body.error).not.toMatch(/\d{3}/);
  });

  it("i3_a_stored_endpoint_off_the_list_is_never_fetched", async () => {
    const u = await newUser("Stored bad");
    const { cookie } = await pairPhone(u.key);
    expect((await subscribe(cookie, FCM + "s")).status).toBe(200);
    await env.DB.prepare("UPDATE app_push SET endpoint='https://victim.example/x' WHERE user_id=?").bind(u.id).run();
    await expect(alertFor(env as any, u.id)({ id: "x", title: "t", why: "", sender: "", due: null, link: "" })).rejects.toThrow();
    expect(sent).toHaveLength(0);
  });
});

// ---------------------------------------------------------------- M1

describe("M1 sign-in challenges per address", () => {
  it("m1_one_address_can_hold_at_most_20_live_challenges", async () => {
    const opts = (ip: string) => call("/app/api/login/options", { method: "POST", headers: { Origin: BASE, "CF-Connecting-IP": ip }, body: "{}" });
    for (let i = 0; i < 20; i++) expect((await opts("203.0.113.9")).status).toBe(200);
    expect((await opts("203.0.113.9")).status).toBe(429);
    expect((await opts("203.0.113.10")).status).toBe(200);
    // Only a hash of the address is stored.
    expect(await count("SELECT COUNT(*) n FROM app_challenges WHERE ip_hash='203.0.113.9'")).toBe(0);
    expect(await count("SELECT COUNT(*) n FROM app_challenges WHERE ip_hash=?", await sha256Hex("ip:203.0.113.9"))).toBe(20);
  });
});

// ---------------------------------------------------------------- M2

describe("M2 request size is checked before the body is read", () => {
  const streamOf = (total: number, pulled: { n: number }) => new ReadableStream<Uint8Array>({
    pull(c) {
      if (pulled.n >= total) { c.close(); return; }
      const chunk = new Uint8Array(65536).fill(0x20);
      pulled.n += chunk.length;
      c.enqueue(chunk);
    },
  });

  it("m2_a_big_body_without_content_length_is_cut_off_early", async () => {
    const pulled = { n: 0 };
    const r = await handleAppAuth(new Request(BASE + "/app/api/login/options", {
      method: "POST", headers: { Origin: BASE }, body: streamOf(4_000_000, pulled), duplex: "half",
    } as RequestInit), env as any);
    expect(r!.status).toBe(413);
    expect(pulled.n).toBeLessThan(300_000);
  });

  it("m2_content_length_over_the_limit_is_refused_unread", async () => {
    const pulled = { n: 0 };
    const req = new Request(BASE + "/app/api/login/options", {
      method: "POST", headers: { Origin: BASE, "Content-Length": "50000000" }, body: streamOf(4_000_000, pulled), duplex: "half",
    } as RequestInit);
    const r = await handleAppAuth(req, env as any);
    expect(r!.status).toBe(413);
    expect(pulled.n).toBeLessThanOrEqual(65536 * 2); // at most what the stream pre-buffers
  });

  it("m2_size_is_counted_in_bytes_not_characters", async () => {
    const u = await newUser("Bytes");
    const { cookie } = await pairPhone(u.key);
    // 25,000 three-byte characters: 75,000 bytes, over the 64,000-byte cap, but only 25,000 UTF-16 units.
    const r = await api("/app/api/action", { action: "add", title: "x", pad: "紧".repeat(25_000) }, { cookie });
    expect(r.status).toBe(413);
  });
});

// ---------------------------------------------------------------- M3

const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
const putBoard = (key: string, cards: unknown[]) => call("/v2/board", { method: "PUT", key, body: JSON.stringify({ cards }) });

describe("M3 phone actions don't overwrite a newer board", () => {
  it("m3_a_mac_push_during_a_phone_action_is_kept", async () => {
    const u = await newUser("Race");
    const { cookie } = await pairPhone(u.key);
    await putBoard(u.key, [card(1)]);
    // The Mac pushes a newer board after the action read the snapshot, before it wrote.
    const e = hookedEnv(/FROM phone_actions WHERE user_id=\? AND taken=0$/, async (n) => {
      if (n === 1) expect((await putBoard(u.key, [card(1), card(2)])).status).toBe(200);
      return undefined;
    });
    const r = await handleBoard(new Request(BASE + "/app/api/action", {
      method: "POST", headers: { Origin: BASE, Cookie: cookie }, body: JSON.stringify({ card_id: 1, action: "doing" }),
    }), e);
    expect(r!.status).toBe(200);
    const b = await (await call("/app/api/board", { headers: { Cookie: cookie } })).json<any>();
    expect(b.cards.map((c: any) => [c.id, c.status])).toEqual([[1, "doing"], [2, "todo"]]);
  });

  it("m3_a_mac_push_between_the_reread_and_the_write_still_wins_and_the_overlay_shows_the_move", async () => {
    const u = await newUser("Race 2");
    const { cookie } = await pairPhone(u.key);
    await putBoard(u.key, [card(1)]);
    const e = hookedEnv(/^SELECT data_enc, updated FROM board_snapshots/, async (n) => {
      if (n === 2) { await new Promise((r) => setTimeout(r, 5)); expect((await putBoard(u.key, [card(1), card(3)])).status).toBe(200); }
      return undefined;
    });
    await handleBoard(new Request(BASE + "/app/api/action", {
      method: "POST", headers: { Origin: BASE, Cookie: cookie }, body: JSON.stringify({ card_id: 1, action: "done" }),
    }), e);
    const b = await (await call("/app/api/board", { headers: { Cookie: cookie } })).json<any>();
    expect(b.cards.map((c: any) => [c.id, c.status])).toEqual([[1, "done"], [3, "todo"]]);
  });
});

// ---------------------------------------------------------------- M4

describe("M4 a pairing code is only used up by a pairing that completes", () => {
  it("m4_an_insert_failure_leaves_the_code_usable", async () => {
    const u = await newUser("Burn");
    const first = await pairPhone(u.key, "First");
    const code = await pairCode(u.key);
    const options = await (await api("/app/api/pair/options", { code })).json<any>();
    // A finish that races another finish with the same passkey: the "already in use" check sees nothing, the insert fails.
    const e = hookedEnv(/^SELECT 1 FROM app_credentials WHERE credential_id=\?$/, async (n) => (n === 1 ? null : undefined));
    const req = new Request(BASE + "/app/api/pair/finish", {
      method: "POST", headers: { Origin: BASE }, body: JSON.stringify({ code, response: await register(first.a, options), deviceName: "Dup" }),
    });
    const r = await handleAppAuth(req, e);
    expect(r!.status).toBe(400);
    expect(await count("SELECT used n FROM app_pairings WHERE challenge=?", options.challenge)).toBe(0);
    expect(await count("SELECT COUNT(*) n FROM app_devices WHERE user_id=?", u.id)).toBe(1);
    // The same code still pairs a new passkey.
    const ok = await api("/app/api/pair/finish", { code, response: await register(await newAuthenticator(), options), deviceName: "Second" });
    expect(ok.status).toBe(200);
  });
});

// ---------------------------------------------------------------- M5

describe("M5 push payloads fit in one 4096-byte record", () => {
  async function decryptLen(cookie: string, userId: string, item: any) {
    expect((await subscribe(cookie, FCM + "big")).status).toBe(200);
    await alertFor(env as any, userId)(item);
    return sent[0].body.length;
  }

  it("m5_long_multibyte_text_is_trimmed_to_fit", async () => {
    const u = await newUser("Big");
    const { cookie } = await pairPhone(u.key);
    const len = await decryptLen(cookie, u.id, { id: "b", title: "标".repeat(120), why: "紧".repeat(2000), sender: "发".repeat(500),
      due: null, link: "https://mail.google.com/mail/u/0/#search/" + "a".repeat(1950) });
    expect(len).toBeLessThanOrEqual(4096);
  });

  it("m5_a_link_too_long_to_send_falls_back_to_the_app", async () => {
    const u = await newUser("Long link");
    const { cookie } = await pairPhone(u.key);
    const k = await phoneKeys();
    expect((await api("/app/api/push/subscribe", { endpoint: FCM + "l", keys: { p256dh: k.p256dh, auth: k.auth } }, { cookie })).status).toBe(200);
    await alertFor(env as any, u.id)({ id: "l", title: "T", why: "w", sender: "", due: null, link: "https://x.example/" + "a".repeat(2100) });
    expect(sent).toHaveLength(1);
    const msg = JSON.parse(await decryptAsPhone(sent[0].body, k.p256dh, k.privateKey, k.auth));
    expect(msg.url).toBe("/app/");
    expect(msg.title).toBe("T");
  });
});

// ---------------------------------------------------------------- M6

describe("M6 alerts go only to devices that are still paired", () => {
  it("m6_a_subscription_left_on_a_removed_device_gets_nothing", async () => {
    const u = await newUser("Ghost");
    const { cookie } = await pairPhone(u.key, "Ghost phone");
    expect((await subscribe(cookie, FCM + "ghost")).status).toBe(200);
    // A subscribe that raced the removal left the row behind.
    await env.DB.prepare("UPDATE app_devices SET revoked=1 WHERE user_id=?").bind(u.id).run();
    await alertFor(env as any, u.id)({ id: "g", title: "t", why: "", sender: "", due: null, link: "" });
    expect(sent).toHaveLength(0);
  });

  it("m6_a_device_whose_session_expired_still_gets_alerts", async () => {
    const u = await newUser("Expired push");
    const { cookie } = await pairPhone(u.key);
    expect((await subscribe(cookie, FCM + "exp")).status).toBe(200);
    await env.DB.prepare("UPDATE app_sessions SET expires=? WHERE user_id=?").bind(new Date(Date.now() - 1000).toISOString(), u.id).run();
    await alertFor(env as any, u.id)({ id: "e", title: "t", why: "", sender: "", due: null, link: "" });
    expect(sent).toHaveLength(1);
  });
});

// ---------------------------------------------------------------- M7

describe("M7 ntfy carries titles only", () => {
  const item = { id: "n", title: "Pay invoice", why: "Supplier says overdue", sender: "Acme <ap@acme.com>", due: "2026-11-08", link: "https://mail.google.com/mail/u/me@x.com/#all/1" };

  it("m7_ntfy_body_has_no_sender_or_reason_and_clicks_open_the_app", async () => {
    const u = await newUser("Ntfy min");
    const s = await signIn(u.key);
    expect((await form("/setup/ntfy/on", { csrf: s.csrf }, { cookie: s.cookie })).status).toBe(200);
    await alertFor(env as any, u.id)(item);
    expect(ntfy).toHaveLength(1);
    expect(ntfy[0].body).toBe("Due: 2026-11-08\nOpen FloatBoard for details");
    expect(ntfy[0].headers.Click).toBe(`${BASE}/app/`);
  });

  it("m7_without_a_stored_address_there_is_no_click_link", async () => {
    const u = await newUser("Ntfy noclick");
    await env.DB.prepare("UPDATE users SET ntfy_topic='t-abc' WHERE id=?").bind(u.id).run();
    await alertFor(env as any, u.id)({ ...item, due: null });
    expect(ntfy[0].headers.Click).toBeUndefined();
    expect(ntfy[0].body).toBe("Open FloatBoard for details");
  });

  it("m7_setup_page_warns_that_ntfy_is_public", async () => {
    const u = await newUser("Ntfy warn");
    const s = await signIn(u.key);
    expect(s.page).toContain("ntfy.sh is a public server");
    await form("/setup/ntfy/on", { csrf: s.csrf }, { cookie: s.cookie });
    expect(await (await get("/setup", s.cookie)).text()).toContain("ntfy.sh is a public server");
  });
});

// ---------------------------------------------------------------- shared

async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
async function decryptAsPhone(body: Uint8Array, uaPublic: string, uaPrivate: CryptoKey, auth: string): Promise<string> {
  const salt = body.slice(0, 16);
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
  return new TextDecoder().decode(padded.slice(0, end));
}
void assert;
