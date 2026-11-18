import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { accountMarker } from "../../src/phone/auth";
import { SW_JS } from "../../src/phone/sw";
import { APP_JS } from "../../src/phone/client";

// Integration round 7 (Claude reviews): every phone write names the account its queue was made under, the engine refuses
// another account's (409, the phone keeps its queue), and answers name the session's account.

const ON = { jots: true, circle: true, decisions: true, resolutions: false };
async function phone(name: string) {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  await call("/v2/board", { method: "PUT", key: u.key, body: JSON.stringify({ cards: [], modules: ON }) });
  await env.DB.prepare("UPDATE settings SET modules=? WHERE user_id=?").bind(JSON.stringify(ON), u.id).run();
  return { ...u, cookie, account: await accountMarker(u.id) };
}
const post = (cookie: string, path: string, body: unknown) =>
  call(path, { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify(body) });

describe("jots: phone writes are bound to the account", () => {
  it("get_and_post_answer_with_the_sessions_account", async () => {
    const p = await phone("Jots bound");
    const got = await (await call("/app/api/jots", { headers: { Cookie: p.cookie } })).json<any>();
    expect(got.account).toBe(p.account);
    const r = await post(p.cookie, "/app/api/jots", { account: p.account, sent_at: new Date().toISOString(),
      actions: [{ id: "jb-00000001", op: "add", key: "phone:jb-1", text: "A note", made_at: new Date().toISOString() }] });
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.account).toBe(p.account);
    expect(body.accepted).toEqual(["jb-00000001"]);
  });

  it("another_accounts_queue_is_refused_and_nothing_is_stored", async () => {
    const a = await phone("Jots A"), b = await phone("Jots B");
    const action = { id: "jb-00000002", op: "add", key: "phone:jb-2", text: "A's private note", made_at: new Date().toISOString() };
    const wrong = await post(b.cookie, "/app/api/jots", { account: a.account, sent_at: new Date().toISOString(), actions: [action] });
    expect(wrong.status).toBe(409);
    expect((await wrong.json<any>()).account).toBe(b.account);
    expect((await post(b.cookie, "/app/api/jots", { sent_at: new Date().toISOString(), actions: [action] })).status).toBe(400);   // no account
    const n = await env.DB.prepare("SELECT count(*) AS n FROM jot_copies WHERE user_id=?").bind(b.id).first<{ n: number }>();
    expect(n!.n).toBe(0);
  });
});

describe("circle: in-app taps and notification buttons are bound to the account", () => {
  const tap = (id: string) => ({ id, person: "P-1", action: "contacted", made_at: new Date(Date.now() - 60_000).toISOString() });

  it("account_is_required_empty_counts_as_missing_and_another_is_refused", async () => {
    const a = await phone("Circle A"), b = await phone("Circle B");
    expect((await post(b.cookie, "/app/api/circle/action", { actions: [tap("cb-00000001")] })).status).toBe(400);
    expect((await post(b.cookie, "/app/api/circle/action", { account: "", actions: [tap("cb-00000002")] })).status).toBe(400);
    expect((await post(b.cookie, "/app/api/circle/action", { account: a.account, actions: [tap("cb-00000003")] })).status).toBe(409);
    const ok = await post(b.cookie, "/app/api/circle/action", { account: b.account, actions: [tap("cb-00000004")] });
    expect(ok.status).toBe(200);
    expect((await ok.json<any>()).account).toBe(b.account);
    const n = await env.DB.prepare("SELECT count(*) AS n FROM circle_actions WHERE user_id=?").bind(b.id).first<{ n: number }>();
    expect(n!.n).toBe(1);
  });

  it("a_notification_without_an_account_sends_none_and_opens_the_confirm_sheet", () => {
    expect(SW_JS).not.toMatch(/\|\| ""/);   // an old alert's missing account is never sent as ""
    expect(SW_JS).toMatch(/account \? \{ account, actions \} : \{ actions \}/);
  });

  it("the_phone_sends_each_queues_account_and_checks_the_answers", () => {
    expect(APP_JS).toMatch(/\/app\/api\/jots", \{ method: "POST", body: Object\.assign\(\{ account: heldBy \}/);
    expect(APP_JS).toMatch(/sameSession\(stamp, r\.account\)/);   // Jots
    expect(APP_JS).toMatch(/\/app\/api\/circle\/action", \{ method: "POST", body: \{ account: circleQueue\.account, actions: sent \}/);
    expect(APP_JS).toMatch(/if \(!still\(r\.account\)\) return;/);   // Circle
  });
});
