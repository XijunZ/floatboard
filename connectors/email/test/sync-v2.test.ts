import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { BASE, call, newUser } from "./helpers";
import { b64url, count, pairPhone } from "./app-helpers";
import { purgeBoardLog } from "../src/app/board";

// Sync v2 (docs/phone-app.md, "Sync v2"): the engine logs every change, corrects device clocks, and newest change wins.

const H = 3600_000;
const iso = (ms: number) => new Date(ms).toISOString();
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });

const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
const board = (cookie: string) => call("/app/api/board", { headers: { Cookie: cookie } }).then((r) => r.json<any>());
const send = (cookie: string, body: unknown) =>
  call("/app/api/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify(body) });
const macActions = (key: string) => call("/v2/phone-actions", { key }).then((r) => r.json<{ actions: any[]; server_time: string }>());
const ack = (key: string, body: unknown) => call("/v2/phone-actions/ack", { method: "POST", key, body: JSON.stringify(body) });
const status = (b: any, id: number) => b.cards.find((c: any) => c.id === id)?.status;
const logRows = (userId: string) => env.DB.prepare("SELECT * FROM board_log WHERE user_id=? ORDER BY made_at, rowid").bind(userId).all<any>().then((r) => r.results);
const near = (a: string, b: number, slackMs = 60_000) => expect(Math.abs(Date.parse(a) - b), `${a} vs ${iso(b)}`).toBeLessThan(slackMs);

async function phoneKeysForTest() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  return { p256dh: b64url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer)), auth: b64url(crypto.getRandomValues(new Uint8Array(16))) };
}

async function setup(name = "Sync user") {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  return { ...u, cookie };
}

describe("sync v2: board log", () => {
  it("mac_push_logs_its_own_status_change_with_the_corrected_time", async () => {
    const u = await setup();
    const now = Date.now();
    expect((await put(u.key, { sent_at: iso(now), cards: [card(1), card(2)] })).status).toBe(200);
    // Mac clock 1 h slow; the card moved 10 minutes ago (Mac time 1 h 10 min ago).
    const r = await put(u.key, { sent_at: iso(now - H), cards: [card(1, { status: "doing", status_at: iso(now - H - 10 * 60_000) }), card(3)] });
    expect(r.status).toBe(200);
    const rows = await logRows(u.id);
    const st = rows.find((x: any) => x.kind === "status");
    expect(st).toMatchObject({ device: "mac", card_id: 1, value: "doing" });
    near(st.made_at, now - 10 * 60_000);
    expect(rows.find((x: any) => x.kind === "add")).toMatchObject({ device: "mac", card_id: 3 });
    expect(rows.find((x: any) => x.kind === "add").value).not.toContain("Task 3"); // titles are encrypted
    expect(rows.find((x: any) => x.kind === "gone")).toMatchObject({ device: "mac", card_id: 2 });
    // the phone sees the corrected status_at
    const b = await board(u.cookie);
    near(b.cards.find((c: any) => c.id === 1).status_at, now - 10 * 60_000);
  });

  it("a_push_without_status_at_keeps_the_previous_time_for_an_unchanged_step", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const first = (await board(u.cookie)).cards[0].status_at;
    expect(first).toMatch(/^\d{4}-/);
    await new Promise((r) => setTimeout(r, 5));
    await put(u.key, { cards: [card(1)] });
    expect((await board(u.cookie)).cards[0].status_at).toBe(first);
    await put(u.key, { cards: [card(1, { status: "watch" })] });
    expect((await board(u.cookie)).cards[0].status_at > first).toBe(true);
    expect((await put(u.key, { cards: [card(1, { status_at: "soon" })] })).status).toBe(400);
  });

  it("board_log_rows_older_than_a_year_are_purged", async () => {
    const u = await newUser("Log purge");
    const ins = (id: string, at: string) => env.DB.prepare("INSERT INTO board_log(id,user_id,device,card_id,kind,value,made_at,received_at) VALUES(?,?,'mac',1,'status','done',?,?)")
      .bind(id, u.id, at, at);
    await env.DB.batch([ins("log-old", iso(Date.now() - 366 * 86400_000)), ins("log-new", iso(Date.now() - 300 * 86400_000))]);
    await purgeBoardLog(env as any);
    expect((await logRows(u.id)).map((x: any) => x.id)).toEqual(["log-new"]);
  });
});

describe("sync v2: phone actions", () => {
  it("duplicate_action_id_is_applied_once_and_still_succeeds", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const body = { sent_at: iso(Date.now()), actions: [{ id: crypto.randomUUID(), made_at: iso(Date.now()), card_id: 1, action: "done" }] };
    const r1 = await send(u.cookie, body);
    expect(r1.status).toBe(200);
    expect((await r1.json<any>()).accepted).toEqual([body.actions[0].id]);
    const r2 = await send(u.cookie, body);
    expect(r2.status).toBe(200);
    const b2 = await r2.json<any>();
    expect(b2.accepted).toEqual([body.actions[0].id]);
    expect(b2.dropped).toEqual([]);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(1);
    expect((await macActions(u.key)).actions).toHaveLength(1);
    expect(await count("SELECT COUNT(*) AS n FROM board_log WHERE user_id=? AND device<>'mac'", u.id)).toBe(1);
    // the same id twice in one batch is also applied once
    const id = crypto.randomUUID();
    const r3 = await (await send(u.cookie, { actions: [{ id, card_id: 1, action: "doing" }, { id, card_id: 1, action: "doing" }] })).json<any>();
    expect(r3.accepted).toEqual([id, id]);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(2);
  });

  it("a_resend_after_the_phone_action_was_purged_is_still_ignored_through_the_board_log", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1), card(2)] });
    const move = { id: crypto.randomUUID(), made_at: iso(Date.now()), card_id: 1, action: "done" };
    const add = { id: crypto.randomUUID(), made_at: iso(Date.now()), action: "add", title: "Buy milk" };
    expect((await send(u.cookie, { sent_at: iso(Date.now()), actions: [move, add] })).status).toBe(200);
    expect(await count("SELECT COUNT(*) AS n FROM board_log WHERE user_id=? AND client_id IN (?,?)", u.id, move.id, add.id)).toBe(2);
    // The Mac acked them and the hourly purge removed the rows (acked rows go after 7 days).
    await env.DB.prepare("DELETE FROM phone_actions WHERE user_id=?").bind(u.id).run();
    const r = await (await send(u.cookie, { sent_at: iso(Date.now()), actions: [move, add] })).json<any>();
    expect(r.accepted).toEqual([move.id, add.id]);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(0);
    expect((await macActions(u.key)).actions).toHaveLength(0);
    expect(await count("SELECT COUNT(*) AS n FROM board_log WHERE user_id=? AND device<>'mac'", u.id)).toBe(2);
    // Another user's log never counts: the same ids from them are new.
    const other = await setup("Other sync user");
    await put(other.key, { cards: [card(1)] });
    const r2 = await (await send(other.cookie, { actions: [move] })).json<any>();
    expect(r2.accepted).toEqual([move.id]);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", other.id)).toBe(1);
  });

  it("another_users_action_id_does_not_block_mine", async () => {
    const a = await setup("Id A");
    const b = await setup("Id B");
    await put(a.key, { cards: [card(1)] });
    await put(b.key, { cards: [card(1)] });
    const id = crypto.randomUUID();
    await send(a.cookie, { actions: [{ id, card_id: 1, action: "done" }] });
    await send(b.cookie, { actions: [{ id, card_id: 1, action: "watch" }] });
    expect((await macActions(b.key)).actions.map((x) => x.action)).toEqual(["watch"]);
    expect((await macActions(a.key)).actions.map((x) => x.action)).toEqual(["done"]);
  });

  it("phone_move_older_than_the_macs_change_loses_on_the_board_the_phone_sees", async () => {
    const u = await setup();
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status: "doing", status_at: iso(now - 60_000) })] });
    const id = crypto.randomUUID();
    const r = await (await send(u.cookie, { sent_at: iso(now), actions: [{ id, made_at: iso(now - 5 * 60_000), card_id: 1, action: "done" }] })).json<any>();
    expect(r.accepted).toEqual([id]);
    expect(status(r, 1)).toBe("doing");
    expect(r.superseded).toEqual([id]);
    expect((await macActions(u.key)).actions).toEqual([]); // nothing for the Mac to do
    expect((await logRows(u.id)).map((x: any) => x.kind)).toContain("superseded");
  });

  it("newer_phone_move_wins", async () => {
    const u = await setup();
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status: "doing", status_at: iso(now - 10 * 60_000) })] });
    const r = await (await send(u.cookie, { sent_at: iso(now), actions: [{ id: crypto.randomUUID(), made_at: iso(now - 60_000), card_id: 1, action: "done" }] })).json<any>();
    expect(status(r, 1)).toBe("done");
    expect(r.superseded).toEqual([]);
    expect(r.pending).toBe(1);
    // the Mac pushes again without having applied it: the phone still sees the move
    await put(u.key, { sent_at: iso(Date.now()), cards: [card(1, { status: "doing", status_at: iso(now - 10 * 60_000) })] });
    expect(status(await board(u.cookie), 1)).toBe("done");
    const { actions } = await macActions(u.key);
    expect(actions).toHaveLength(1);
    near(actions[0].made_at, now - 60_000, 2000);
  });

  it("a_later_mac_change_supersedes_an_untaken_phone_move", async () => {
    const u = await setup();
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status_at: iso(now - H) })] });
    const id = crypto.randomUUID();
    await send(u.cookie, { sent_at: iso(now), actions: [{ id, made_at: iso(now - 30 * 60_000), card_id: 1, action: "done" }] });
    // The Mac moved the card to watch 5 minutes ago (after the phone's move) and pushes.
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status: "watch", status_at: iso(now - 5 * 60_000) })] });
    const b = await board(u.cookie);
    expect(status(b, 1)).toBe("watch");
    expect(b.superseded).toEqual([id]);
    expect(b.pending).toBe(0);
    expect((await macActions(u.key)).actions).toEqual([]);
  });

  it("skew_correction_orders_an_offline_queued_action_correctly", async () => {
    // Phone clock 2 h fast; the action was queued offline 3 h ago and is sent now.
    const now = Date.now();
    const phoneNow = now + 2 * H;
    const madeOnPhoneClock = iso(phoneNow - 3 * H); // real time: 3 h ago
    // Mac changed the card 2 h ago (real time): the phone's move (3 h ago) is older and loses.
    const u = await setup();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status: "doing", status_at: iso(now - 2 * H) })] });
    const id = crypto.randomUUID();
    const r = await (await send(u.cookie, { sent_at: iso(phoneNow), actions: [{ id, made_at: madeOnPhoneClock, card_id: 1, action: "done" }] })).json<any>();
    expect(status(r, 1)).toBe("doing");
    expect(r.superseded).toEqual([id]);
    near((await env.DB.prepare("SELECT made_at FROM phone_actions WHERE client_id=?").bind(id).first<{ made_at: string }>())!.made_at, now - 3 * H);
    // Mac changed the card 4 h ago: the phone's move is newer and wins.
    const v = await setup("Skew 2");
    await put(v.key, { sent_at: iso(now), cards: [card(1, { status: "doing", status_at: iso(now - 4 * H) })] });
    const r2 = await (await send(v.cookie, { sent_at: iso(phoneNow), actions: [{ id: crypto.randomUUID(), made_at: madeOnPhoneClock, card_id: 1, action: "done" }] })).json<any>();
    expect(status(r2, 1)).toBe("done");
  });

  it("an_absurd_skew_falls_back_to_the_received_time", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const id = crypto.randomUUID();
    await send(u.cookie, { sent_at: "2001-01-01T00:00:00.000Z", actions: [{ id, made_at: "2000-12-31T00:00:00.000Z", card_id: 1, action: "done" }] });
    near((await env.DB.prepare("SELECT made_at FROM phone_actions WHERE client_id=?").bind(id).first<{ made_at: string }>())!.made_at, Date.now(), 10_000);
    // a made_at in the future is never later than the received time
    const id2 = crypto.randomUUID();
    await send(u.cookie, { sent_at: iso(Date.now()), actions: [{ id: id2, made_at: iso(Date.now() + 3 * H), card_id: 1, action: "doing" }] });
    expect(Date.parse((await env.DB.prepare("SELECT made_at FROM phone_actions WHERE client_id=?").bind(id2).first<{ made_at: string }>())!.made_at)).toBeLessThanOrEqual(Date.now());
  });

  it("action_on_a_card_gone_from_the_macs_board_is_dropped_with_a_reason", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1), card(2)] });
    await put(u.key, { cards: [card(1)] });
    const gone = crypto.randomUUID(), unknown = crypto.randomUUID(), ok = crypto.randomUUID();
    const r = await send(u.cookie, { sent_at: iso(Date.now()), actions: [
      { id: gone, made_at: iso(Date.now()), card_id: 2, action: "done" },
      { id: unknown, made_at: iso(Date.now()), card_id: 99, action: "done" },
      { id: "bad id!", card_id: 1, action: "done" },
      { id: crypto.randomUUID(), card_id: 1, action: "explode" },
      { id: ok, made_at: iso(Date.now()), card_id: 1, action: "watch" },
    ] });
    expect(r.status).toBe(200);
    const b = await r.json<any>();
    expect(b.accepted).toEqual([ok]);
    expect(b.dropped).toEqual([
      { id: gone, reason: "card gone" }, { id: unknown, reason: "unknown card" }, { id: "bad id!", reason: "invalid" },
      { id: expect.any(String), reason: "invalid" },
    ]);
    expect(status(b, 1)).toBe("watch");
    expect((await macActions(u.key)).actions).toHaveLength(1);
  });

  it("a_batch_of_50_queued_actions_is_accepted_in_one_request", async () => {
    const u = await setup();
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: Array.from({ length: 10 }, (_, i) => card(i + 1, { status_at: iso(now - 2 * H) })) });
    const steps = ["doing", "watch", "done", "todo"];
    const actions = Array.from({ length: 50 }, (_, i) => i % 5 === 4
      ? { id: crypto.randomUUID(), made_at: iso(now - (50 - i) * 60_000), action: "add", title: `Added ${i}`, group: "Work" }
      : { id: crypto.randomUUID(), made_at: iso(now - (50 - i) * 60_000), card_id: (i % 10) + 1, action: steps[i % 4] });
    const r = await send(u.cookie, { sent_at: iso(now), actions });
    expect(r.status).toBe(200);
    const b = await r.json<any>();
    expect(b.accepted).toHaveLength(50);
    expect(b.dropped).toEqual([]);
    expect(b.pending).toBe(50);
    expect(b.cards.filter((c: any) => c.pending)).toHaveLength(10);
    // the last move per card wins
    const last = new Map<number, string>();
    actions.forEach((a: any) => { if (a.card_id) last.set(a.card_id, a.action); });
    for (const [id, s] of last) expect(status(b, id)).toBe(s);
    const added = b.cards.find((c: any) => c.pending && c.title === "Added 4");
    expect(added.action_id).toBe(actions[4].id);
    expect((await macActions(u.key)).actions).toHaveLength(50);
  });

  it("limits_a_batch_is_at_most_100_actions_and_the_body_is_capped", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1)] });
    const mk = (n: number) => ({ actions: Array.from({ length: n }, () => ({ id: crypto.randomUUID(), card_id: 1, action: "done" })) });
    expect((await send(u.cookie, mk(101))).status).toBe(400);
    expect((await send(u.cookie, mk(0))).status).toBe(400);
    expect((await send(u.cookie, { actions: "x" })).status).toBe(400);
    expect((await send(u.cookie, { sent_at: "later", actions: mk(1).actions })).status).toBe(400);
    expect((await send(u.cookie, { actions: mk(1).actions, pad: "x".repeat(70_000) })).status).toBe(413);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(0);
    expect((await send(u.cookie, mk(100))).status).toBe(200);
    // a batch that would take the waiting queue over 200 is refused whole (the phone keeps it and retries later)
    expect((await send(u.cookie, mk(100))).status).toBe(200);
    expect((await send(u.cookie, mk(1))).status).toBe(429);
    expect(await count("SELECT COUNT(*) AS n FROM phone_actions WHERE user_id=?", u.id)).toBe(200);
  });

  it("board_response_has_server_time_and_account", async () => {
    const u = await setup();
    const b = await board(u.cookie);
    near(b.server_time, Date.now(), 10_000);
    const me = await call("/app/api/me", { headers: { Cookie: u.cookie } }).then((r) => r.json<any>());
    expect(b.account).toBe(me.account);
    expect(b.superseded).toEqual([]);
  });
});

describe("sync v2: the Mac's side", () => {
  it("ack_with_skipped_logs_the_reason_and_the_phone_hears_of_it", async () => {
    const u = await setup();
    await put(u.key, { cards: [card(1), card(2)] });
    const a1 = crypto.randomUUID(), a2 = crypto.randomUUID();
    await send(u.cookie, { sent_at: iso(Date.now()), actions: [
      { id: a1, made_at: iso(Date.now()), card_id: 1, action: "done" }, { id: a2, made_at: iso(Date.now()), card_id: 2, action: "watch" }] });
    const { actions, server_time } = await macActions(u.key);
    near(server_time, Date.now(), 10_000);
    expect(actions.map((x) => x.client_id)).toEqual([a1, a2]);
    const skip = actions.find((x) => x.client_id === a2)!;
    const r = await ack(u.key, { ids: [actions[0].id], skipped: [{ id: skip.id, reason: "kept the newer Mac change" }] });
    expect(r.status).toBe(200);
    expect((await macActions(u.key)).actions).toEqual([]);
    const rows = await logRows(u.id);
    expect(rows.find((x: any) => x.kind === "skipped")).toMatchObject({ device: "mac", card_id: 2 });
    expect(rows.find((x: any) => x.kind === "skipped").value).toContain("kept the newer Mac change");
    expect((await board(u.cookie)).superseded).toEqual([a2]);
    expect((await ack(u.key, { ids: [], skipped: [{ id: 5 }] })).status).toBe(400);
    expect((await ack(u.key, { ids: [], skipped: "x" })).status).toBe(400);
  });

  it("an_applied_move_still_shows_until_the_mac_pushes_and_then_the_mac_copy_rules", async () => {
    const u = await setup();
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status_at: iso(now - H) })] });
    await send(u.cookie, { sent_at: iso(now), actions: [{ id: crypto.randomUUID(), made_at: iso(now - 60_000), card_id: 1, action: "done" }] });
    const { actions } = await macActions(u.key);
    await ack(u.key, { ids: [actions[0].id] });
    expect(status(await board(u.cookie), 1)).toBe("done"); // acked, the Mac has not pushed yet
    await put(u.key, { sent_at: iso(Date.now()), cards: [card(1, { status: "done", status_at: iso(Date.now()) })] });
    expect(status(await board(u.cookie), 1)).toBe("done");
    await put(u.key, { sent_at: iso(Date.now()), cards: [card(1, { status: "doing", status_at: iso(Date.now()) })] });
    expect(status(await board(u.cookie), 1)).toBe("doing");
    expect((await board(u.cookie)).superseded).toEqual([]);
  });
});

describe("sync v2: push subscription from the service worker", () => {
  it("a_service_worker_resubscribe_is_accepted", async () => {
    const u = await setup();
    const k = await phoneKeysForTest();
    // A fetch from the service worker is same-origin: it sends the app origin and the session cookie, no Referer.
    const r = await call("/app/api/push/subscribe", {
      method: "POST",
      headers: { Cookie: u.cookie, Origin: BASE, "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty" },
      body: JSON.stringify({ endpoint: "https://fcm.googleapis.com/fcm/send/sw-renewed", keys: { p256dh: k.p256dh, auth: k.auth } }),
    });
    expect(r.status).toBe(200);
    expect(await count("SELECT COUNT(*) AS n FROM app_push WHERE user_id=? AND endpoint=?", u.id, "https://fcm.googleapis.com/fcm/send/sw-renewed")).toBe(1);
  });
});
