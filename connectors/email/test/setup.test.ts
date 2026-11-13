import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, form, freshIP, get, newUser, signIn } from "./helpers";
import { decrypt } from "../src/crypto";
import { sha256Hex } from "../src/auth";
import { setGoogleFetch } from "../src/routes/sources";
import { esc } from "../src/setup/page";
import { runAllUsers } from "../src/index";
import { RULES, PRE_RULES } from "../src/classify";

const unescapeAttr = (s: string) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

let googleCalls: { url: string; body: string }[] = [];
let googleReply: () => Response;
/** A JWT-shaped id_token whose payload is base64url of UTF-8 JSON (as Google sends it). */
const idToken = (claims: object) =>
  `x.${btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(claims)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}.y`;
beforeEach(() => {
  googleCalls = [];
  googleReply = () => Response.json({ access_token: "at", refresh_token: "rt-secret-xyz", id_token: idToken({ email: "me@gmail.com", email_verified: true }) });
  setGoogleFetch((async (url: RequestInfo | URL, init?: RequestInit) => {
    googleCalls.push({ url: String(url), body: String(init?.body ?? "") });
    return googleReply();
  }) as typeof fetch);
});

async function withClient(key: string) {
  const s = await signIn(key);
  const r = await form("/setup/google/client", { csrf: s.csrf, client_id: "web-cid.apps.googleusercontent.com", client_secret: "web-csecret" }, { cookie: s.cookie });
  expect(r.status).toBe(200);
  return s;
}

/** Browser nonce cookie set by each start, by state (the callback needs the one from the same browser). */
const nonceFor = new Map<string, string>();
/** Start the Google flow; returns the auth URL from the redirect and remembers the nonce cookie. */
async function startGoogle(s: { cookie: string; csrf: string }) {
  const r = await get(`/setup/google/start?csrf=${encodeURIComponent(s.csrf)}`, s.cookie);
  expect(r.status).toBe(303);
  const auth = new URL(r.headers.get("Location")!);
  const nonce = /fb_oauth=([^;]+)/.exec(r.headers.get("Set-Cookie") ?? "");
  if (nonce) nonceFor.set(auth.searchParams.get("state")!, nonce[0]);
  return auth;
}
/** Google → engine, as the same browser that started the flow (carries its nonce cookie when there is one). */
function callback(path: string, cookie?: string) {
  const state = new URL(BASE + path).searchParams.get("state") ?? "";
  return get(path, cookie ?? nonceFor.get(state));
}

const logRows = async (userId: string) =>
  (await env.DB.prepare("SELECT action, ok, detail FROM setup_log WHERE user_id=? ORDER BY rowid").bind(userId).all<any>()).results;

describe("setup page", () => {
  it("setup_requires_key", async () => {
    const u = await newUser("X");
    const page = await get("/setup");
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain('name="key"');
    expect(html).not.toContain("floatboard://");
    // A wrong key: no session, no cookie.
    const bad = await form("/setup/signin", { key: "wrong" }, { ip: freshIP() });
    expect(bad.status).toBe(401);
    expect(bad.headers.get("Set-Cookie")).toBeNull();
    // Without a session nothing behind the page works.
    expect((await form("/setup/claude", { csrf: "x", anthropic_key: "sk" })).status).toBe(401);
    expect((await get("/setup/google/start?csrf=x")).status).toBe(401);
    expect((await get("/setup", "fb_setup=forged")).headers.get("Content-Type")).toContain("text/html");
    expect(await (await get("/setup", "fb_setup=forged")).text()).not.toContain("floatboard://");
    // The right key works.
    const s = await signIn(u.key);
    expect(s.page).toContain("Connect to FloatBoard");
    expect((await logRows(u.id)).some((r) => r.action === "signin" && r.ok === 1)).toBe(true);
  });

  it("cookie_flags_secure", async () => {
    const u = await newUser("X");
    const r = await form("/setup/signin", { key: u.key }, { ip: freshIP() });
    expect(r.status).toBe(303);
    expect(r.headers.get("Location")).toBe("/setup");
    const c = r.headers.get("Set-Cookie")!;
    const sid = /^fb_setup=([A-Za-z0-9_-]{32,});/.exec(c)![1];
    for (const flag of ["HttpOnly", "Secure", "SameSite=Strict", "Path=/setup", "Max-Age=3600"]) expect(c).toContain(flag);
    // Stored hashed, never as the cookie value; the user key is stored encrypted only.
    const row = await env.DB.prepare("SELECT * FROM setup_sessions WHERE id_hash=?").bind(await sha256Hex(sid)).first<any>();
    expect(row).toBeTruthy();
    expect(JSON.stringify(row)).not.toContain(sid);
    expect(JSON.stringify(row)).not.toContain(u.key);
    expect(await decrypt(env as any, row.key_enc)).toBe(u.key);
    // Sign out ends the session.
    const csrf = /name="csrf" value="([^"]+)"/.exec(await (await get("/setup", `fb_setup=${sid}`)).text())![1];
    const out = await form("/setup/signout", { csrf }, { cookie: `fb_setup=${sid}` });
    expect(out.status).toBe(303);
    expect(out.headers.get("Set-Cookie")).toContain("Max-Age=0");
    expect(await (await get("/setup", `fb_setup=${sid}`)).text()).not.toContain("floatboard://");
  });

  it("expired_session_rejected", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    await env.DB.prepare("UPDATE setup_sessions SET expires=? WHERE user_id=?").bind(new Date(Date.now() - 1000).toISOString(), u.id).run();
    expect(await (await get("/setup", s.cookie)).text()).not.toContain("floatboard://");
    expect((await form("/setup/claude", { csrf: s.csrf, anthropic_key: "sk" }, { cookie: s.cookie })).status).toBe(401);
  });

  it("csp_and_strict_headers_present", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    for (const r of [await get("/setup"), await get("/setup", s.cookie), await get("/setup/admin"),
      await callback("/setup/google/callback?state=nope&code=x"), await form("/setup/signin", { key: "bad" }, { ip: freshIP() })]) {
      expect(r.headers.get("Content-Security-Policy")).toBe("default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
      expect(r.headers.get("X-Content-Type-Options")).toBe("nosniff");
      expect(r.headers.get("Referrer-Policy")).toBe("no-referrer");
      expect(r.headers.get("Cache-Control")).toBe("no-store");
    }
    const html = await (await get("/setup", s.cookie)).text();
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/\son[a-z]+=/i);
  });

  it("html_escaping", async () => {
    expect(esc(`<script>"x" & 'y'</script>`)).toBe("&lt;script&gt;&quot;x&quot; &amp; &#39;y&#39;&lt;/script&gt;");
    const u = await newUser(`<script>alert("hi")</script>`);
    const s = await signIn(u.key);
    expect(s.page).not.toContain("<script>");
    expect(s.page).toContain("&lt;script&gt;alert(&quot;hi&quot;)&lt;/script&gt;");
    // A Gmail address from Google is escaped too.
    await withClient(u.key);
    googleReply = () => Response.json({ access_token: "at", refresh_token: "rt", id_token: idToken({ email: `a"><b>@gmail.com`, email_verified: true }) });
    const s2 = await signIn(u.key);
    const auth = await startGoogle(s2);
    await callback(`/setup/google/callback?state=${auth.searchParams.get("state")}&code=c1`);
    const page = await (await get("/setup", s2.cookie)).text();
    expect(page).not.toContain(`a"><b>`);
    expect(page).toContain("a&quot;&gt;&lt;b&gt;@gmail.com");
  });

  it("csrf_rejected", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    expect((await form("/setup/claude", { anthropic_key: "sk-1" }, { cookie: s.cookie })).status).toBe(403);
    expect((await form("/setup/claude", { csrf: "wrong", anthropic_key: "sk-1" }, { cookie: s.cookie })).status).toBe(403);
    // Another session's token doesn't work either.
    const other = await signIn((await newUser("Y")).key);
    expect((await form("/setup/claude", { csrf: other.csrf, anthropic_key: "sk-1" }, { cookie: s.cookie })).status).toBe(403);
    // Cross-site origin is refused even with the right token.
    expect((await form("/setup/claude", { csrf: s.csrf, anthropic_key: "sk-1" }, { cookie: s.cookie, origin: "https://evil.example" })).status).toBe(403);
    expect((await call("/setup/claude", { method: "POST", headers: { Cookie: s.cookie, "Content-Type": "application/x-www-form-urlencoded", "Sec-Fetch-Site": "cross-site" },
      body: new URLSearchParams({ csrf: s.csrf, anthropic_key: "sk-1" }).toString() })).status).toBe(403);
    expect((await get(`/setup/google/start?csrf=wrong`, s.cookie)).status).toBe(403);
    const u2 = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(u.id).first<any>();
    expect(u2.anthropic_key_enc).toBeNull();
    expect((await logRows(u.id)).some((r) => r.action === "csrf" && r.ok === 0)).toBe(true);
    // Same origin (or the "null" origin browsers send under Referrer-Policy no-referrer) + right token is accepted.
    expect((await form("/setup/claude", { csrf: s.csrf, anthropic_key: "sk-1" }, { cookie: s.cookie, origin: BASE })).status).toBe(200);
    expect((await form("/setup/claude", { csrf: s.csrf, anthropic_key: "sk-2" }, { cookie: s.cookie, origin: "null" })).status).toBe(200);
  });

  it("claude_key_never_returned", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    expect(s.page).not.toContain("saved ✓");
    const r = await form("/setup/claude", { csrf: s.csrf, anthropic_key: "sk-ant-very-secret" }, { cookie: s.cookie });
    expect(r.status).toBe(200);
    const html = await r.text();
    expect(html).toContain("saved ✓");
    expect(html).not.toContain("sk-ant-very-secret");
    const again = await (await get("/setup", s.cookie)).text();
    expect(again).toContain("saved ✓");
    expect(again).not.toContain("sk-ant-very-secret");
    const row = await env.DB.prepare("SELECT anthropic_key_enc FROM users WHERE id=?").bind(u.id).first<any>();
    expect(row.anthropic_key_enc).not.toContain("sk-ant-very-secret");
    expect(await decrypt(env as any, row.anthropic_key_enc)).toBe("sk-ant-very-secret");
    const logs = JSON.stringify(await logRows(u.id));
    expect(logs).toContain("claude_key");
    expect(logs).not.toContain("sk-ant-very-secret");
    // The Google client secret is write-only too.
    await form("/setup/google/client", { csrf: s.csrf, client_id: "cid.apps", client_secret: "gcs-secret-777" }, { cookie: s.cookie });
    const page = await (await get("/setup", s.cookie)).text();
    expect(page).toContain("cid.apps");
    expect(page).not.toContain("gcs-secret-777");
  });

  it("connect_link_contains_engine_and_key", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    const hrefs = [...s.page.matchAll(/href="(floatboard:\/\/[^"]+)"/g)].map((m) => unescapeAttr(m[1]));
    expect(hrefs).toHaveLength(1);
    const link = new URL(hrefs[0]);
    expect(link.protocol).toBe("floatboard:");
    expect(link.host + link.pathname).toBe("connect");
    expect(link.searchParams.get("url")).toBe(BASE);
    expect(link.searchParams.get("key")).toBe(u.key);
    expect(link.searchParams.get("name")).toBe("Email");
    // The key appears only inside that one link.
    expect(s.page.split(u.key)).toHaveLength(2);
    // The engine's redirect address for Google Cloud is shown.
    expect(s.page).toContain(`${BASE}/setup/google/callback`);
  });

  it("signin_rate_limited", async () => {
    const u = await newUser("X");
    const ip = freshIP();
    for (let i = 0; i < 10; i++) expect((await form("/setup/signin", { key: `bad-${i}` }, { ip })).status).toBe(401);
    // The 11th attempt is refused even with the right key.
    const r = await form("/setup/signin", { key: u.key }, { ip });
    expect(r.status).toBe(429);
    expect(r.headers.get("Set-Cookie")).toBeNull();
    // Admin sign-in shares the limit.
    expect((await form("/setup/admin/signin", { key: "admin-test-key" }, { ip })).status).toBe(429);
    const n = await env.DB.prepare("SELECT COUNT(*) n FROM setup_attempts WHERE ip=? AND ok=0").bind(ip).first<{ n: number }>();
    expect(n!.n).toBeGreaterThanOrEqual(10);
    // Attempts older than 15 minutes don't count.
    await env.DB.prepare("UPDATE setup_attempts SET at=? WHERE ip=?").bind(new Date(Date.now() - 16 * 60_000).toISOString(), ip).run();
    expect((await form("/setup/signin", { key: u.key }, { ip })).status).toBe(303);
    // Another address is unaffected.
    expect((await form("/setup/signin", { key: u.key }, { ip: freshIP() })).status).toBe(303);
  });

  it("google_start_redirects_with_web_client", async () => {
    const u = await newUser("X");
    const plain = await signIn(u.key);
    // Without a Google Cloud client there's nothing to start.
    const none = await get(`/setup/google/start?csrf=${plain.csrf}`, plain.cookie);
    expect(none.status).toBe(400);
    const s = await withClient(u.key);
    const auth = await startGoogle(s);
    expect(auth.origin + auth.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    const q = auth.searchParams;
    expect(q.get("client_id")).toBe("web-cid.apps.googleusercontent.com");
    expect(q.get("redirect_uri")).toBe(`${BASE}/setup/google/callback`);
    expect(q.get("response_type")).toBe("code");
    expect(q.get("scope")!.split(" ").sort()).toEqual(["email", "https://www.googleapis.com/auth/gmail.modify", "openid"]);
    expect(q.get("access_type")).toBe("offline");
    expect(q.get("prompt")).toBe("consent");
    expect(q.get("state")).toMatch(/^[A-Za-z0-9_-]{32,}$/);
    const row = await env.DB.prepare("SELECT * FROM oauth_states WHERE state_hash=?").bind(await sha256Hex(q.get("state")!)).first<any>();
    expect(row.user_id).toBe(u.id);
    const secret = await env.DB.prepare("SELECT client_secret_enc FROM google_clients WHERE user_id=?").bind(u.id).first<any>();
    expect(await decrypt(env as any, secret.client_secret_enc)).toBe("web-csecret");
  });

  it("google_callback_rejects_bad_state", async () => {
    const u = await newUser("X");
    const s = await withClient(u.key);
    // Unknown state: refused, Google never called.
    const bad = await callback("/setup/google/callback?state=not-a-real-state&code=c1");
    expect(bad.status).toBe(400);
    expect(await bad.text()).not.toContain("is connected");
    expect((await callback("/setup/google/callback?code=c1")).status).toBe(400);
    expect(googleCalls).toHaveLength(0);
    // Expired state: refused.
    const st1 = (await startGoogle(s)).searchParams.get("state")!;
    await env.DB.prepare("UPDATE oauth_states SET expires=? WHERE state_hash=?").bind(new Date(Date.now() - 1000).toISOString(), await sha256Hex(st1)).run();
    expect((await callback(`/setup/google/callback?state=${st1}&code=c1`)).status).toBe(400);
    expect(googleCalls).toHaveLength(0);
    // The user refused on Google's page: recorded, no source.
    const st0 = (await startGoogle(s)).searchParams.get("state")!;
    expect((await callback(`/setup/google/callback?state=${st0}&error=access_denied`)).status).toBe(400);
    expect(googleCalls).toHaveLength(0);
    // Valid state: one token call, source saved with the Web client, refresh token encrypted.
    const st2 = (await startGoogle(s)).searchParams.get("state")!;
    const ok = await callback(`/setup/google/callback?state=${st2}&code=c2`);
    expect(ok.status).toBe(200);
    const okHtml = await ok.text();
    expect(okHtml).toContain("me@gmail.com");
    expect(okHtml).not.toContain("rt-secret-xyz");
    expect(googleCalls).toHaveLength(1);
    expect(googleCalls[0].url).toBe("https://oauth2.googleapis.com/token");
    const body = new URLSearchParams(googleCalls[0].body);
    expect(body.get("code")).toBe("c2");
    expect(body.get("redirect_uri")).toBe(`${BASE}/setup/google/callback`);
    expect(body.get("client_id")).toBe("web-cid.apps.googleusercontent.com");
    expect(body.get("client_secret")).toBe("web-csecret");
    const src = await env.DB.prepare("SELECT * FROM sources WHERE user_id=? AND kind='gmail'").bind(u.id).first<any>();
    expect(src.address).toBe("me@gmail.com");
    expect(src.client_id).toBe("web-cid.apps.googleusercontent.com");
    expect(await decrypt(env as any, src.refresh_enc)).toBe("rt-secret-xyz");
    expect(await decrypt(env as any, src.client_secret_enc)).toBe("web-csecret");
    // Single use: replaying the same state is refused.
    expect((await callback(`/setup/google/callback?state=${st2}&code=c3`)).status).toBe(400);
    expect(googleCalls).toHaveLength(1);
    // A state belongs to its user: the account landed on u, not anyone else.
    const page = await (await get("/setup", s.cookie)).text();
    expect(page).toContain("me@gmail.com");
    const logs = await logRows(u.id);
    expect(logs.filter((r) => r.action === "google_callback").map((r) => r.ok)).toEqual([0, 0, 1]);
    expect(JSON.stringify(logs)).not.toContain("rt-secret-xyz");
    const anon = (await env.DB.prepare("SELECT COUNT(*) n FROM setup_log WHERE action='google_callback' AND ok=0 AND user_id IS NULL").first<{ n: number }>())!.n;
    expect(anon).toBeGreaterThanOrEqual(2);
  });

  it("google_callback_failures_recorded", async () => {
    const u = await newUser("X");
    const s = await withClient(u.key);
    // Google returns no refresh token: nothing saved, failure shown and recorded.
    googleReply = () => Response.json({ access_token: "at", id_token: idToken({ email: "me@gmail.com" }) });
    const st = (await startGoogle(s)).searchParams.get("state")!;
    const r = await callback(`/setup/google/callback?state=${st}&code=c`);
    expect(r.status).toBe(502);
    // Google rejects the code.
    googleReply = () => Response.json({ error: "invalid_grant" }, { status: 400 });
    const st2 = (await startGoogle(s)).searchParams.get("state")!;
    expect((await callback(`/setup/google/callback?state=${st2}&code=c`)).status).toBe(502);
    expect(await env.DB.prepare("SELECT id FROM sources WHERE user_id=?").bind(u.id).first()).toBeNull();
    const logs = await logRows(u.id);
    expect(logs.filter((r) => r.action === "google_callback" && r.ok === 0)).toHaveLength(2);
  });

  it("gmail_remove_only_by_owner", async () => {
    const u = await newUser("X");
    const s = await withClient(u.key);
    const st = (await startGoogle(s)).searchParams.get("state")!;
    await callback(`/setup/google/callback?state=${st}&code=c`);
    const list = (await env.DB.prepare("SELECT id FROM sources WHERE user_id=?").bind(u.id).all<{ id: string }>()).results;
    expect(list).toHaveLength(1);
    // Another user can't remove it.
    const other = await signIn((await newUser("Y")).key);
    expect((await form("/setup/gmail/remove", { csrf: other.csrf, source_id: list[0].id }, { cookie: other.cookie })).status).toBe(404);
    expect((await form("/setup/gmail/remove", { csrf: s.csrf, source_id: list[0].id }, { cookie: s.cookie })).status).toBe(200);
    expect((await env.DB.prepare("SELECT id FROM sources WHERE user_id=?").bind(u.id).all()).results).toEqual([]);
  });

  it("fathom_section_and_no_telegram", async () => {
    const u = await newUser("X");
    const s = await signIn(u.key);
    expect(await (await get("/setup", s.cookie)).text()).not.toMatch(/telegram/i);
    expect((await form("/setup/telegram", { csrf: s.csrf }, { cookie: s.cookie })).status).toBe(404);
    const f = await form("/setup/fathom", { csrf: s.csrf }, { cookie: s.cookie });
    expect(f.status).toBe(200);
    const hook = /https:\/\/engine\.test\/hooks\/fathom\/[A-Za-z0-9_-]+/.exec(await f.text())![0];
    const stored = await env.DB.prepare("SELECT hook_id FROM sources WHERE user_id=? AND kind='fathom'").bind(u.id).first<{ hook_id: string }>();
    expect(hook).toBe(`${BASE}/hooks/fathom/${stored!.hook_id}`);
    expect(await (await get("/setup", s.cookie)).text()).toContain(hook);
  });

  it("admin_creates_invite_link", async () => {
    // Admin page needs the admin key; a user session isn't enough.
    const u = await newUser("X");
    const us = await signIn(u.key);
    const blocked = await get("/setup/admin", us.cookie);
    expect(await blocked.text()).not.toContain('name="name"');
    expect((await form("/setup/admin/users", { csrf: us.csrf, name: "Guest" }, { cookie: us.cookie })).status).toBe(401);
    const bad = await form("/setup/admin/signin", { key: "not-admin" }, { ip: freshIP() });
    expect(bad.status).toBe(401);
    const a = await signIn("admin-test-key", "/setup/admin/signin");
    expect(a.page).toContain('name="name"');
    // An admin session isn't a user session.
    expect(await (await get("/setup", a.cookie)).text()).not.toContain("floatboard://");
    const r = await form("/setup/admin/users", { csrf: a.csrf, name: "Sam" }, { cookie: a.cookie });
    expect(r.status).toBe(200);
    const html = await r.text();
    const href = unescapeAttr(/href="(floatboard:\/\/[^"]+)"/.exec(html)![1]);
    const link = new URL(href);
    expect(link.searchParams.get("url")).toBe(BASE);
    expect(link.searchParams.get("name")).toBe("Email");
    const key = link.searchParams.get("key")!;
    const row = await env.DB.prepare("SELECT id, name FROM users WHERE key_hash=?").bind(await sha256Hex(key)).first<any>();
    expect(row.name).toBe("Sam");
    expect((await call("/v2/status", { key })).status).toBe(200);
    // One-time: the admin page doesn't show it again.
    expect(await (await get("/setup/admin", a.cookie)).text()).not.toContain(key);
    const log = await env.DB.prepare("SELECT detail FROM setup_log WHERE action='admin_create_user' AND ok=1").all<any>();
    expect(JSON.stringify(log.results)).not.toContain(key);
  });
});

describe("setup page: how emails are judged", () => {
  it("lists_shared_rules_and_prechecks_escaped", async () => {
    const u = await newUser("Rules");
    const { page } = await signIn(u.key);
    expect(page).toContain("How emails are judged");
    expect(RULES.length).toBeGreaterThan(0);
    for (const r of [...RULES, ...PRE_RULES]) expect(page).toContain(esc(r));
    // PRE_RULES contain double quotes, which must appear escaped, never raw.
    expect(PRE_RULES.some((r) => r.includes('"'))).toBe(true);
    expect(page).toContain(esc(PRE_RULES[0]));
    expect(page).not.toContain(PRE_RULES[0]);
  });
});

describe("setup page: guidance and safety", () => {
  it("google_client_step_explains_production_and_unverified_warning", async () => {
    const { page } = await signIn((await newUser("X")).key);
    const step = page.slice(page.indexOf("1. Google Cloud client"), page.indexOf("2. Gmail accounts"));
    expect(step).toContain("In production");
    expect(step).toContain("Audience");
    expect(step).toContain("Publish app");
    expect(step).toContain("7 days");
    expect(step).toContain("unverified");
    expect(step).toContain("Advanced");
  });

  it("non_ascii_address_decoded_as_utf8", async () => {
    const u = await newUser("X");
    const s = await withClient(u.key);
    googleReply = () => Response.json({ access_token: "at", refresh_token: "rt", id_token: idToken({ email: "Renée.ユーザー@exämple.com", email_verified: true }) });
    const st = (await startGoogle(s)).searchParams.get("state")!;
    const r = await callback(`/setup/google/callback?state=${st}&code=c`);
    expect(r.status).toBe(200);
    expect(await r.text()).toContain("renée.ユーザー@exämple.com");
    const src = await env.DB.prepare("SELECT address FROM sources WHERE user_id=? AND kind='gmail'").bind(u.id).first<any>();
    expect(src.address).toBe("renée.ユーザー@exämple.com");
  });

  it("expired_sessions_purged_on_load_and_by_cron", async () => {
    const a = await newUser("A"), b = await newUser("B"), c = await newUser("C");
    const sa = await signIn(a.key), sb = await signIn(b.key);
    await signIn(c.key);
    const past = new Date(Date.now() - 1000).toISOString();
    const rows = async (id: string) => (await env.DB.prepare("SELECT COUNT(*) n FROM setup_sessions WHERE user_id=?").bind(id).first<{ n: number }>())!.n;
    // Loading an expired session deletes it (and any other expired one, key_enc included).
    await env.DB.prepare("UPDATE setup_sessions SET expires=? WHERE user_id IN (?,?)").bind(past, a.id, b.id).run();
    expect(await (await get("/setup", sa.cookie)).text()).not.toContain("floatboard://");
    expect(await rows(a.id)).toBe(0);
    expect(await rows(b.id)).toBe(0);
    expect(await rows(c.id)).toBe(1);
    // A cookie that matches nothing also purges expired sessions.
    await env.DB.prepare("UPDATE setup_sessions SET expires=? WHERE user_id=?").bind(past, c.id).run();
    await get("/setup", "fb_setup=no-such-session");
    expect(await rows(c.id)).toBe(0);
    // The hourly cron path purges them too (no session load needed).
    const d = await newUser("D");
    await signIn(d.key);
    await env.DB.prepare("UPDATE setup_sessions SET expires=? WHERE user_id=?").bind(past, d.id).run();
    await env.DB.prepare("INSERT INTO oauth_states(state_hash,user_id,expires,created) VALUES('old-state',?,?,?)").bind(d.id, past, past).run();
    await runAllUsers(env as any, async () => undefined, []);
    expect(await rows(d.id)).toBe(0);
    expect(await env.DB.prepare("SELECT 1 FROM oauth_states WHERE state_hash='old-state'").first()).toBeNull();
    void sb;
  });

  it("oauth_state_bound_to_browser", async () => {
    const u = await newUser("X");
    const s = await withClient(u.key);
    const r = await get(`/setup/google/start?csrf=${encodeURIComponent(s.csrf)}`, s.cookie);
    const c = r.headers.get("Set-Cookie")!;
    expect(c).toMatch(/^fb_oauth=[A-Za-z0-9_-]{32,};/);
    for (const flag of ["HttpOnly", "Secure", "SameSite=Lax", "Path=/setup/google/callback", "Max-Age=600"]) expect(c).toContain(flag);
    const st = new URL(r.headers.get("Location")!).searchParams.get("state")!;
    const nonce = /fb_oauth=([^;]+)/.exec(c)![1];
    const row = await env.DB.prepare("SELECT nonce_hash FROM oauth_states WHERE state_hash=?").bind(await sha256Hex(st)).first<any>();
    expect(row.nonce_hash).toBe(await sha256Hex(nonce));
    // No nonce cookie (another browser): refused, Google never called, state used up.
    expect((await callback(`/setup/google/callback?state=${st}&code=c`, "")).status).toBe(400);
    expect(googleCalls).toHaveLength(0);
    // Another flow's nonce: refused.
    const st2 = (await startGoogle(s)).searchParams.get("state")!;
    const st3 = (await startGoogle(s)).searchParams.get("state")!;
    const bad = await callback(`/setup/google/callback?state=${st2}&code=c`, nonceFor.get(st3));
    expect(bad.status).toBe(400);
    expect(googleCalls).toHaveLength(0);
    // The matching nonce works and the response clears the nonce cookie.
    const ok = await callback(`/setup/google/callback?state=${st3}&code=c`);
    expect(ok.status).toBe(200);
    expect(ok.headers.get("Set-Cookie")).toContain("Max-Age=0");
    const logs = (await env.DB.prepare("SELECT ok, detail FROM setup_log WHERE user_id=? AND action='google_callback' ORDER BY rowid").bind(u.id).all<any>()).results;
    expect(logs.map((l) => l.ok)).toEqual([0, 0, 1]);
    expect(logs[0].detail).toContain("browser");
  });
});

describe("remove needs a tick", () => {
  it("gmail_and_phone_remove_buttons_need_a_tick_first", async () => {
    const { dashboardPage } = await import("../src/setup/page");
    const html = dashboardPage({ name: "X", csrf: "c", origin: "https://e", connectLink: null, googleClientId: "cid", hasClaudeKey: true,
      fathomURL: null, gmail: [{ id: "g1", address: "a@b.c", enabled: 1, last_error: null, last_run: null }],
      phones: [{ id: "d1", name: "Phone", created: "2026-11-10T00:00:00Z", last_seen: null, shares_passkey: 0 }] } as any);
    expect(html.match(/<input type="checkbox" required> Yes, remove<\/label> <button class="danger" type="submit">Remove<\/button>/g)).toHaveLength(2);
  });
});
