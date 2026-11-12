import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "./helpers";
import { count, pairPhone } from "./app-helpers";
import { purgePhoneActions } from "../src/app/board";

const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Secret task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: "2026-11-12T09:00:00.000Z", has_time: true, status: "todo", link: "https://example.com/x", done_at: null, ...over });

const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
const board = (cookie?: string) => call("/app/api/board", { headers: cookie ? { Cookie: cookie } : {} });
const act = (cookie: string | undefined, body: unknown, origin: string | null = BASE) =>
  call("/app/api/action", { method: "POST", headers: { ...(cookie ? { Cookie: cookie } : {}), ...(origin ? { Origin: origin } : {}) }, body: JSON.stringify(body) });
const pending = (key: string) => call("/v2/phone-actions", { key }).then((r) => r.json<{ actions: any[] }>());

async function setup(name = "Board user") {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  return { ...u, cookie };
}

describe("board mirror", () => {
  it("snapshot_is_stored_encrypted_and_the_phone_reads_it", async () => {
    const u = await setup();
    expect((await put(u.key, { cards: [card(1), card(2, { status: "done", done_at: "2026-11-12T08:00:00.000Z", link: null, due: null })] })).status).toBe(200);
    const raw = (await env.DB.prepare("SELECT data_enc FROM board_snapshots WHERE user_id=?").bind(u.id).first<{ data_enc: string }>())!.data_enc;
    expect(raw).not.toContain("Secret task");
    const r = await board(u.cookie);
    expect(r.headers.get("Cache-Control")).toBe("no-store");
    const b = await r.json<any>();
    expect(b.cards.map((c: any) => c.title)).toEqual(["Secret task 1", "Secret task 2"]);
    expect(b.pending).toBe(0);
    expect(b.updated).toMatch(/^\d{4}-/);
  });

  it("a_new_push_replaces_the_copy", async () => {
    const u = await setup();
    expect(await (await put(u.key, { cards: [card(1), card(2)] })).json()).toEqual({ ok: true, count: 2 });
    await put(u.key, { cards: [card(3)] });
    expect((await (await board(u.cookie)).json<any>()).cards.map((c: any) => c.id)).toEqual([3]);
    expect(await count("SELECT COUNT(*) AS n FROM board_snapshots WHERE user_id=?", u.id)).toBe(1);
  });

  it("no_snapshot_yet_gives_an_empty_board", async () => {
    const u = await setup();
    expect(await (await board(u.cookie)).json()).toEqual({ updated: null, cards: [], pending: 0 });
  });

  it("a_move_is_applied_to_the_stored_copy_and_listed_for_the_mac", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1), card(2)] });
    const r = await act(u.cookie, { card_id: 2, action: "done" });
    expect(r.status).toBe(200);
    const b = await r.json<any>();
    expect(b.pending).toBe(1);
    const c2 = b.cards.find((c: any) => c.id === 2);
    expect(c2.status).toBe("done");
    expect(c2.done_at).toMatch(/^\d{4}-/);
    // the stored copy itself changed
    const stored = await (await board(u.cookie)).json<any>();
    expect(stored.cards.find((c: any) => c.id === 2).status).toBe("done");
    const { actions } = await pending(u.key);
    expect(actions).toHaveLength(1);
    expect(actions[0]).toMatchObject({ card_id: 2, action: "done", title: null, group: null });
    expect(typeof actions[0].id).toBe("string");
    // moving back clears done_at
    const back = await (await act(u.cookie, { card_id: 2, action: "doing" })).json<any>();
    expect(back.cards.find((c: any) => c.id === 2)).toMatchObject({ status: "doing", done_at: null });
  });

  it("a_pushed_copy_still_shows_untaken_moves_until_the_mac_acks", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    await act(u.cookie, { card_id: 1, action: "watch" });
    await put(u.key, { cards: [card(1)] }); // Mac pushed before it had applied the move
    expect((await (await board(u.cookie)).json<any>()).cards[0].status).toBe("watch");
  });

  it("an_added_task_is_a_pending_card_and_not_stored_in_the_copy", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const b = await (await act(u.cookie, { action: "add", title: "  Buy milk  ", group: "Work" })).json<any>();
    expect(b.pending).toBe(1);
    const added = b.cards.find((c: any) => c.pending);
    expect(added).toMatchObject({ title: "Buy milk", group: "Work", color: "#aabbcc", status: "todo", id: expect.any(Number) });
    expect(added.id).toBeLessThan(0);
    const raw = (await env.DB.prepare("SELECT data_enc FROM board_snapshots WHERE user_id=?").bind(u.id).first<{ data_enc: string }>())!.data_enc;
    const { actions } = await pending(u.key);
    expect(actions[0]).toMatchObject({ card_id: null, action: "add", title: "Buy milk", group: "Work" });
    // an add works with no snapshot and no group
    const u2 = await setup("Fresh user");
    const b2 = await (await act(u2.cookie, { action: "add", title: "First" })).json<any>();
    expect(b2.cards).toHaveLength(1);
    expect(b2.cards[0]).toMatchObject({ pending: true, title: "First" });
  });

  it("ack_removes_actions_and_only_for_the_owner", async () => {
    const u = await setup();
    const o = await setup("Other user");
    await put(u.key, { cards: [card(1)] });
    await act(u.cookie, { card_id: 1, action: "doing" });
    await act(u.cookie, { action: "add", title: "A" });
    const { actions } = await pending(u.key);
    expect(actions.map((a) => a.action)).toEqual(["doing", "add"]); // oldest first
    // another user's ack changes nothing
    await call("/v2/phone-actions/ack", { method: "POST", key: o.key, body: JSON.stringify({ ids: actions.map((a) => a.id) }) });
    expect((await pending(u.key)).actions).toHaveLength(2);
    const r = await call("/v2/phone-actions/ack", { method: "POST", key: u.key, body: JSON.stringify({ ids: [actions[0].id] }) });
    expect(r.status).toBe(200);
    expect((await pending(u.key)).actions.map((a) => a.action)).toEqual(["add"]);
    expect((await (await board(u.cookie)).json<any>()).pending).toBe(1);
    expect((await call("/v2/phone-actions/ack", { method: "POST", key: u.key, body: JSON.stringify({ ids: "x" }) })).status).toBe(400);
  });

  it("users_are_isolated", async () => {
    const a = await setup("User A");
    const b = await setup("User B");
    await put(a.key, { cards: [card(7, { title: "A only" })] });
    await put(b.key, { cards: [card(8, { title: "B only" })] });
    const bb = await (await board(b.cookie)).json<any>();
    expect(bb.cards.map((c: any) => c.title)).toEqual(["B only"]);
    // B can't move A's card id
    expect((await act(b.cookie, { card_id: 7, action: "done" })).status).toBe(404);
    expect((await pending(a.key)).actions).toEqual([]);
    expect((await pending(b.key)).actions).toEqual([]);
    expect((await (await board(a.cookie)).json<any>()).cards[0].status).toBe("todo");
  });

  it("bad_pushes_are_refused", async () => {
    const u = await newUser("Pusher");
    const bad: unknown[] = [
      {}, { cards: "x" }, { cards: [1] }, { cards: [card(1.5)] }, { cards: [card(1, { id: "1" })] }, { cards: [card(1), card(1)] },
      { cards: [card(1, { title: 5 })] }, { cards: [card(1, { title: "x".repeat(201) })] }, { cards: [card(1, { group: null })] },
      { cards: [card(1, { color: "red" })] }, { cards: [card(1, { color: "#abc" })] }, { cards: [card(1, { importance: 3 })] },
      { cards: [card(1, { importance: "1" })] }, { cards: [card(1, { has_time: 1 })] }, { cards: [card(1, { status: "blocked" })] },
      { cards: [card(1, { due: "tomorrow" })] }, { cards: [card(1, { due: 5 })] }, { cards: [card(1, { done_at: "nope" })] },
      { cards: [card(1, { link: "javascript:alert(1)" })] }, { cards: [card(1, { link: "file:///etc/passwd" })] }, { cards: [card(1, { link: "not a url" })] },
      { cards: [card(1, { link: 5 })] }, { cards: [card(1, { due: undefined })] },
    ];
    for (const b of bad) expect((await put(u.key, b)).status, JSON.stringify(b).slice(0, 80)).toBe(400);
    expect((await call("/v2/board", { method: "PUT", key: u.key, body: "{oops" })).status).toBe(400);
    expect(await count("SELECT COUNT(*) AS n FROM board_snapshots WHERE user_id=?", u.id)).toBe(0);
    expect((await put(u.key, { cards: [card(1, { link: null, due: null })] })).status).toBe(200);
    expect((await call("/v2/board", { method: "PUT", body: "{}" })).status).toBe(401);
  });

  it("the_card_cap_is_500", async () => {
    const u = await newUser("Capper");
    const many = (n: number) => ({ cards: Array.from({ length: n }, (_, i) => card(i + 1, { title: "t" })) });
    expect((await put(u.key, many(500))).status).toBe(200);
    expect((await put(u.key, many(501))).status).toBe(400);
  });

  it("bad_actions_are_refused", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const bad: unknown[] = [
      {}, { action: "delete", card_id: 1 }, { action: "done" }, { action: "done", card_id: "1" }, { action: "done", card_id: 1.5 },
      { action: "add" }, { action: "add", title: "" }, { action: "add", title: "   " }, { action: "add", title: 5 },
      { action: "add", title: "x".repeat(201) }, { action: "add", title: "ok", group: 5 }, { action: "add", title: "ok", group: "g".repeat(201) },
    ];
    for (const b of bad) expect((await act(u.cookie, b)).status, JSON.stringify(b)).toBe(400);
    expect((await act(u.cookie, { action: "done", card_id: 99 })).status).toBe(404);
    expect((await act(u.cookie, { action: "add", title: "x".repeat(200) })).status).toBe(200);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(1);
  });

  it("at_most_200_waiting_actions", async () => {
    const u = await setup();
    const now = new Date().toISOString();
    await env.DB.batch(Array.from({ length: 200 }, (_, i) =>
      env.DB.prepare("INSERT INTO phone_actions(id,user_id,card_id,action,title,created,taken) VALUES(?,?,NULL,'add','t',?,0)").bind(`a${i}`, u.id, now)));
    expect((await act(u.cookie, { action: "add", title: "one more" })).status).toBe(429);
    // acked ones don't count
    await call("/v2/phone-actions/ack", { method: "POST", key: u.key, body: JSON.stringify({ ids: ["a0"] }) });
    expect((await act(u.cookie, { action: "add", title: "one more" })).status).toBe(200);
  });

  it("taken_actions_are_purged_after_seven_days", async () => {
    const u = await newUser("Purger");
    const old = new Date(Date.now() - 8 * 86400_000).toISOString();
    const fresh = new Date().toISOString();
    const ins = (id: string, created: string, taken: number) =>
      env.DB.prepare("INSERT INTO phone_actions(id,user_id,card_id,action,title,created,taken) VALUES(?,?,NULL,'add','t',?,?)").bind(id, u.id, created, taken);
    await env.DB.batch([ins("old-taken", old, 1), ins("old-untaken", old, 0), ins("new-taken", fresh, 1)]);
    await purgePhoneActions(env as any);
    const ids = (await env.DB.prepare("SELECT id FROM phone_actions WHERE user_id=? ORDER BY id").bind(u.id).all<{ id: string }>()).results.map((r) => r.id);
    expect(ids).toEqual(["new-taken", "old-untaken"]);
  });

  it("the_phone_needs_its_cookie_and_the_user_key_is_refused", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    expect((await board()).status).toBe(401);
    expect((await board("fb_session=nonsense")).status).toBe(401);
    expect((await call("/app/api/board", { headers: { Authorization: `Bearer ${u.key}` } })).status).toBe(401);
    expect((await act(undefined, { card_id: 1, action: "done" })).status).toBe(401);
    expect((await call("/app/api/action", { method: "POST", headers: { Authorization: `Bearer ${u.key}`, Origin: BASE }, body: JSON.stringify({ card_id: 1, action: "done" }) })).status).toBe(401);
    // and the cookie does not work on /v2
    expect((await call("/v2/phone-actions", { headers: { Cookie: u.cookie } })).status).toBe(401);
    expect((await call("/v2/board", { method: "PUT", headers: { Cookie: u.cookie }, body: JSON.stringify({ cards: [] }) })).status).toBe(401);
    expect((await pending(u.key)).actions).toEqual([]);
  });

  it("a_wrong_or_missing_origin_is_refused", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    expect((await act(u.cookie, { card_id: 1, action: "done" }, "https://evil.example")).status).toBe(403);
    expect((await act(u.cookie, { card_id: 1, action: "done" }, null)).status).toBe(403);
    expect((await pending(u.key)).actions).toEqual([]);
  });
});
