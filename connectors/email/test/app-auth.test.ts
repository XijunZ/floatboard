import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, form, get, newUser, signIn } from "./helpers";
import { api, assert, b64url, cookieOf, count, login, me, newAuthenticator, pairCode, pairPhone, register, type Authenticator } from "./app-helpers";

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
    expect(await m.json()).toMatchObject({ user: "Finisher", device: "Pixel" });
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
    // A sign-in without an install id is a new browser: a new device, named by the client (default "Phone").
    expect(await (await me(cookieOf(r)!)).json()).toMatchObject({ user: "Login User", device: "Phone" });
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
    // It was the only device using its passkey, so the passkey is deleted too.
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
    expect(await (await me(p1.cookie)).json()).toMatchObject({ user: "First Person", device: "Phone 1" });
    expect(await (await me(p2.cookie)).json()).toMatchObject({ user: "Second Person", device: "Phone 2" });
    // The second user's code can't be used to register against the first user's pairing either.
    const code1 = await pairCode(one.key);
    const code2 = await pairCode(two.key);
    const o2 = await (await api("/app/api/pair/options", { code: code2 })).json<any>();
    expect((await api("/app/api/pair/finish", { code: code1, response: await register(await newAuthenticator(), o2), deviceName: "X" })).status).toBe(400);
  });
});
