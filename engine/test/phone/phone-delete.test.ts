import { describe, it, expect } from "vitest";
import { BASE, call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";

// Delete on the phone (docs/phone-app.md, "Sync v2"): `delete` (with an optional teach reason) and `restore`.

const iso = (ms: number) => new Date(ms).toISOString();
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
const board = (cookie: string) => call("/app/api/board", { headers: { Cookie: cookie } }).then((r) => r.json<any>());
const send = (cookie: string, body: unknown) =>
  call("/app/api/action", { method: "POST", headers: { Cookie: cookie, Origin: BASE }, body: JSON.stringify(body) });
const macActions = (key: string) => call("/v2/phone-actions", { key }).then((r) => r.json<{ actions: any[] }>());

async function setup(name: string) {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  return { ...u, cookie };
}

describe("phone delete", () => {
  it("board_carries_teach_on_delete_and_a_bad_value_is_ignored", async () => {
    const u = await setup("Teach flag");
    expect((await put(u.key, { cards: [card(1, { teach_on_delete: true }), card(2), card(3, { teach_on_delete: "yes" })] })).status).toBe(200);
    const b = await board(u.cookie);
    expect(b.cards.map((c: any) => c.teach_on_delete ?? false)).toEqual([true, false, false]);
  });

  it("delete_hides_the_card_and_reaches_the_mac_with_its_teach_reason", async () => {
    const u = await setup("Deleter");
    await put(u.key, { cards: [card(1, { teach_on_delete: true }), card(2)] });
    const r = await send(u.cookie, { sent_at: iso(Date.now()), actions: [{ id: "pdel-0001", made_at: iso(Date.now()), card_id: 1, action: "delete", teach: "not_action" }] });
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.accepted).toEqual(["pdel-0001"]);
    expect(body.cards.map((c: any) => c.id)).toEqual([2]);
    const a = (await macActions(u.key)).actions;
    expect(a).toHaveLength(1);
    expect(a[0]).toMatchObject({ client_id: "pdel-0001", card_id: 1, action: "delete", teach: "not_action" });
    // Sent again (a lost answer): stored once.
    await send(u.cookie, { actions: [{ id: "pdel-0001", card_id: 1, action: "delete", teach: "not_action" }] });
    expect((await macActions(u.key)).actions).toHaveLength(1);
  });

  it("a_bad_teach_reason_is_refused_as_invalid", async () => {
    const u = await setup("Bad teach");
    await put(u.key, { cards: [card(1)] });
    const body = await (await send(u.cookie, { actions: [{ id: "pdel-000x", card_id: 1, action: "delete", teach: "because" }] })).json<any>();
    expect(body.dropped).toEqual([{ id: "pdel-000x", reason: "invalid" }]);
  });

  it("a_delete_older_than_the_macs_change_loses", async () => {
    const u = await setup("Older delete");
    const now = Date.now();
    await put(u.key, { sent_at: iso(now), cards: [card(1, { status: "doing", status_at: iso(now - 60_000) })] });
    const body = await (await send(u.cookie, { sent_at: iso(now), actions: [{ id: "pdel-0old", made_at: iso(now - 5 * 60_000), card_id: 1, action: "delete" }] })).json<any>();
    expect(body.accepted).toEqual(["pdel-0old"]);
    expect(body.cards.map((c: any) => c.id)).toEqual([1]);
    expect(body.superseded).toContain("pdel-0old");
    expect((await macActions(u.key)).actions).toHaveLength(0);
  });

  it("restore_after_the_mac_deleted_it_is_accepted_and_reaches_the_mac", async () => {
    const u = await setup("Restorer");
    await put(u.key, { cards: [card(1), card(2)] });
    await send(u.cookie, { actions: [{ id: "pdel-0002", card_id: 1, action: "delete" }] });
    await put(u.key, { cards: [card(2)] });   // the Mac applied the delete
    const body = await (await send(u.cookie, { actions: [{ id: "pres-0002", card_id: 1, action: "restore" }] })).json<any>();
    expect(body.accepted).toEqual(["pres-0002"]);
    const a = (await macActions(u.key)).actions;
    expect(a.map((x: any) => x.action)).toEqual(["delete", "restore"]);
    // Restore of a card this board never had is not accepted.
    const never = await (await send(u.cookie, { actions: [{ id: "pres-0009", card_id: 99, action: "restore" }] })).json<any>();
    expect(never.dropped).toEqual([{ id: "pres-0009", reason: "unknown card" }]);
  });

  it("a_queued_restore_shows_the_card_again", async () => {
    const u = await setup("Overlay");
    await put(u.key, { cards: [card(1)] });
    const now = Date.now();
    await send(u.cookie, { actions: [{ id: "pdel-0003", made_at: iso(now), card_id: 1, action: "delete" }, { id: "pres-0003", made_at: iso(now + 1000), card_id: 1, action: "restore" }] });
    expect((await board(u.cookie)).cards.map((c: any) => c.id)).toEqual([1]);
  });
});

// The phone's own logic for delete (the exact text in /app/app.js).
import { SYNC_EXPORTS, SYNC_JS } from "../../src/phone/sync-logic";
// eslint-disable-next-line no-new-func
const L: any = new Function(SYNC_JS + "\nreturn {" + SYNC_EXPORTS.join(",") + "};")();

describe("phone delete logic", () => {
  const b = { cards: [{ id: 1, title: "One", status: "todo" }, { id: 2, title: "Two", status: "doing" }] };
  const at = "2026-11-17T10:00:00.000Z";

  it("a_queued_delete_hides_the_card_and_a_later_restore_shows_it", () => {
    expect(L.viewBoard(b, [{ id: "d", made_at: at, card_id: 1, action: "delete", teach: "duplicate" }]).cards.map((c: any) => c.id)).toEqual([2]);
    expect(L.viewBoard(b, [{ id: "d", made_at: at, card_id: 1, action: "delete" }, { id: "r", made_at: at, card_id: 1, action: "restore" }])
      .cards.map((c: any) => [c.id, c.status])).toEqual([[1, "todo"], [2, "doing"]]);
  });

  it("the_batch_carries_the_teach_reason", () => {
    const batch = L.takeBatch([{ id: "d1234567", made_at: at, card_id: 1, action: "delete", teach: "not_action" },
      { id: "d7654321", made_at: at, card_id: 2, action: "delete" }], at);
    expect(batch.actions).toEqual([{ id: "d1234567", made_at: at, action: "delete", card_id: 1, teach: "not_action" },
      { id: "d7654321", made_at: at, action: "delete", card_id: 2 }]);
  });

  it("undo_before_send_drops_the_delete_and_after_send_queues_a_restore", () => {
    const del = { id: "d1", made_at: at, card_id: 1, action: "delete" };
    const u = L.deleteUndoFor({ id: 1, title: "One", status: "todo" }, del, 1000);
    expect(L.undoText(u)).toBe("Deleted");
    expect(L.undoLive(u, 1000 + 7999)).toBe(true);
    const before = L.undoDeleteStep(u, [del, { id: "m", card_id: 2, action: "done", made_at: at }], false, "r1", "2026-11-17T10:00:05.000Z");
    expect(before.restore).toBeNull();
    expect(before.actions.map((a: any) => a.id)).toEqual(["m"]);
    const inFlight = L.undoDeleteStep(u, [del], true, "r1", "2026-11-17T10:00:05.000Z");
    expect(inFlight.restore).toMatchObject({ id: "r1", card_id: 1, action: "restore" });
    expect(inFlight.actions).toEqual([del]);
    const after = L.undoDeleteStep(u, [], false, "r1", "2026-11-17T09:00:00.000Z");   // phone clock went back
    expect(after.restore).toEqual({ id: "r1", made_at: "2026-11-17T10:00:00.001Z", card_id: 1, action: "restore" });
  });
});

// Round 6 (C2): a delete the engine took whose answer never came back. The phone keeps it queued and is no longer syncing;
// Undo must still send a restore (the delete may be on the Mac already), never just drop the delete locally.
describe("phone delete with a lost answer", () => {
  it("undo_after_a_lost_answer_sends_a_restore_and_the_card_comes_back", async () => {
    const u = await setup("Lost answer");
    await put(u.key, { cards: [card(1), card(2)] });
    const now = Date.now();
    const del = { id: "pdel-lost1", made_at: iso(now), card_id: 1, action: "delete" };
    let queue: any[] = [del];
    // The sync loop marks what it sends, sends it, and the engine stores the delete, but the answer is lost.
    const body = L.takeBatch(queue, iso(now));
    queue = L.markAttempted(queue, body);
    expect((await send(u.cookie, body)).status).toBe(200);
    expect((await board(u.cookie)).cards.map((c: any) => c.id)).toEqual([2]);
    // Undo while no sync runs.
    const u1 = L.deleteUndoFor({ id: 1, title: "Task 1", status: "todo" }, del, now);
    const step = L.undoDeleteStep(u1, queue, false, "pres-lost1", iso(Date.now() + 1));
    expect(step.restore).toMatchObject({ id: "pres-lost1", card_id: 1, action: "restore" });
    queue = step.actions.concat([step.restore]);
    // The next sync sends the delete again (idempotent) and the restore: the card is back.
    const r = await (await send(u.cookie, L.takeBatch(queue, iso(Date.now())))).json<any>();
    expect(r.accepted).toEqual(expect.arrayContaining(["pdel-lost1", "pres-lost1"]));
    expect((await board(u.cookie)).cards.map((c: any) => c.id).sort()).toEqual([1, 2]);
    expect((await macActions(u.key)).actions.map((x: any) => x.action)).toEqual(["delete", "restore"]);
  });

  it("a_delete_never_sent_is_still_taken_back_locally", () => {
    const del = { id: "pdel-new", made_at: "2026-11-17T10:00:00.000Z", card_id: 1, action: "delete" };
    const other = { id: "pdel-oth", made_at: "2026-11-17T10:00:00.000Z", card_id: 2, action: "delete" };
    // Only the batch's actions are marked; the mark is not sent to the engine.
    const marked = L.markAttempted([del, other], { actions: [{ id: "pdel-oth" }] });
    expect(marked.map((a: any) => !!a.attempted)).toEqual([false, true]);
    expect(L.takeBatch(marked, "2026-11-17T10:00:00.000Z").actions[1].attempted).toBeUndefined();
    const u = L.deleteUndoFor({ id: 1, title: "One", status: "todo" }, del, 1000);
    const step = L.undoDeleteStep(u, marked, false, "r", "2026-11-17T10:00:05.000Z");
    expect(step.restore).toBeNull();
    expect(step.actions.map((a: any) => a.id)).toEqual(["pdel-oth"]);
  });
});
