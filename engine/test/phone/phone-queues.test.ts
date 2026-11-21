import { describe, expect, it } from "vitest";
import { SYNC_EXPORTS, SYNC_JS } from "../../src/phone/sync-logic";
import { CIRCLE_JS } from "../../src/phone/circle-client";
import { DECISIONS_LOGIC_JS, DECISIONS_UI_JS } from "../../src/phone/decisions-client";
import { JOTS_JS } from "../../src/phone/jots-logic";
import { APP_JS } from "../../src/phone/client";

// Round 13 (B1 step 1): the phone's three offline queues (Jots, Circle, Decisions) share one set of pure helpers in
// sync.client.js: the byte count, the next send, the queue after an answer, after a refusal, and the durable save.
// eslint-disable-next-line no-new-func
const S: any = new Function(SYNC_JS + "\nreturn {" + SYNC_EXPORTS.join(",") + "};")();

describe("phone queues: shared helpers", () => {
  it("queueTake_takes_the_oldest_under_the_count_and_byte_caps_and_names_one_too_big", () => {
    const q = [{ id: "a", t: "x".repeat(40) }, { id: "b", t: "y".repeat(40) }, { id: "c", t: "z" }];
    expect(S.queueTake(q, 2, 10_000, 0).actions.map((a: any) => a.id)).toEqual(["a", "b"]);
    expect(S.queueTake(q, 50, 70, 0).actions.map((a: any) => a.id)).toEqual(["a"]);
    const big = [{ id: "huge", t: "é".repeat(100) }, { id: "ok", t: "" }];
    expect(S.queueTake(big, 50, 100, 0)).toEqual({ actions: [], tooBig: "huge" });
  });

  it("queueWithout_and_queueAfterRefusal", () => {
    const q = [{ id: "a1" }, { id: "a2" }, { id: "a3" }];
    expect(S.queueWithout(q, ["a1", "a3"]).map((a: any) => a.id)).toEqual(["a2"]);
    expect(S.queueAfterRefusal(q, "a2").map((a: any) => a.id)).toEqual(["a1", "a3"]);
    expect(S.queueAfterRefusal(q, undefined).map((a: any) => a.id)).toEqual(["a2", "a3"]);
  });

  it("the_three_queues_use_the_shared_helpers_and_no_copies", () => {
    for (const src of [JOTS_JS, DECISIONS_LOGIC_JS, DECISIONS_UI_JS, CIRCLE_JS]) {
      expect(src).not.toMatch(/charCodeAt/);   // one byte count (sync.client.js)
    }
    expect(JOTS_JS).toContain("queueTake(");
    expect(DECISIONS_LOGIC_JS).toContain("queueTake(");
    expect(CIRCLE_JS).toContain("queueTake(");
    expect(SYNC_JS).toContain("function storeDurable(");
  });

  it("circle_queue_is_never_blocked_and_saved_durably", () => {
    expect(CIRCLE_JS).toMatch(/SharedQueue\(CIRCLE_QUEUE_KEY, load, storeDurable\)/);   // a tap is only shown once it is saved (round 28: merged across tabs)
    expect(CIRCLE_JS).toMatch(/if \(!kept\) \{ toast\(/);
    expect(CIRCLE_JS).toMatch(/queueAfterRefusal\(circleQueue\.actions, e\.id\)/);   // a refused batch drops only the named one
    expect(CIRCLE_JS).toMatch(/tooBig/);                                    // one too big for any send is dropped with a message
  });
});

// Round 30 (Codex 20): the queue every tab shares is changed one tab at a time (a lock around read, merge and write),
// markers only ever go from false to true, and a queue of another account is parked, never deleted.
describe("phone queues: one tab at a time", () => {
  // A storage shared by two "tabs"; `during` runs once, inside the next read (another tab acting between a read and a write).
  function world() {
    const data: Record<string, any> = {};
    let during: (() => void) | null = null;
    const load = (k: string) => { const v = data[k] ?? null; if (during) { const f = during; during = null; f(); } return v ? JSON.parse(JSON.stringify(v)) : null; };
    const store = (k: string, v: any) => { if (v == null) delete data[k]; else data[k] = JSON.parse(JSON.stringify(v)); return true; };
    // A lock as navigator.locks gives it: one holder at a time, the others wait in order.
    let tail: Promise<unknown> = Promise.resolve();
    const lock = (_name: string, fn: () => unknown) => { const run = tail.then(fn); tail = run.catch(() => {}); return run; };
    return { data, load, store, lock, between: (f: () => void) => { during = f; } };
  }

  it("two_tabs_saving_at_once_keep_both_captures", async () => {
    const w = world();
    const t1 = S.SharedQueue("q", w.load, w.store, w.lock), t2 = S.SharedQueue("q", w.load, w.store, w.lock);
    t1.load("A"); t2.load("A");
    let second: Promise<unknown> | null = null;
    w.between(() => { second = t2.save("A", [{ id: "b" }]); });   // tab two saves while tab one is between its read and write
    await t1.save("A", [{ id: "a" }]);
    await second;
    expect(w.data.q.actions.map((x: any) => x.id).sort()).toEqual(["a", "b"]);
  });

  it("an_ack_in_another_tab_is_never_undone", async () => {
    const w = world();
    w.store("q", { account: "A", actions: [{ id: "a" }, { id: "b" }] });
    const t1 = S.SharedQueue("q", w.load, w.store, w.lock), t2 = S.SharedQueue("q", w.load, w.store, w.lock);
    t1.load("A"); t2.load("A");
    let ack: Promise<unknown> | null = null;
    w.between(() => { ack = t2.save("A", [{ id: "b" }]); });       // tab two: the engine took a
    await t1.save("A", [{ id: "a" }, { id: "b" }, { id: "c" }]);   // tab one, still holding a, adds c
    await ack;
    expect(w.data.q.actions.map((x: any) => x.id).sort()).toEqual(["b", "c"]);
  });

  it("a_sent_marker_set_in_another_tab_stays_so_undo_sends_a_restore", async () => {
    const w = world();
    const del = { id: "d", op: "delete", key: "J-1" };
    w.store("q", { account: "A", actions: [del] });
    const t1 = S.SharedQueue("q", w.load, w.store, w.lock), t2 = S.SharedQueue("q", w.load, w.store, w.lock);
    t1.load("A"); t2.load("A");
    await t2.save("A", [{ ...del, attempted: true }]);              // tab two sent it (its answer may be lost)
    await t1.save("A", [del]);                                       // a stale copy in tab one never clears the marker
    expect(w.data.q.actions[0].attempted).toBe(true);
    // Undo decides on the shared state, under the lock.
    const out = await t1.update("A", [del], (list: any[]) => {
      const cur = list.find((x) => x.id === "d");
      return cur.attempted ? list.concat([{ id: "r", op: "restore", key: "J-1" }]) : list.filter((x) => x.id !== "d");
    });
    expect(out.map((x: any) => x.id)).toEqual(["d", "r"]);
  });

  it("another_accounts_queue_is_parked_and_comes_back_when_it_signs_in_again", async () => {
    const w = world();
    const t = S.SharedQueue("q", w.load, w.store, w.lock);
    t.load("A");
    await t.save("A", [{ id: "a1" }, { id: "a2" }]);
    await t.park("A", [{ id: "a1" }, { id: "a2" }]);                // another account signed in: A's changes are kept apart
    t.load("B");
    await t.save("B", [{ id: "b1" }]);
    expect(JSON.stringify(w.data)).toContain("a1");                   // never deleted or relabelled
    expect(w.data.q.actions.map((x: any) => x.id)).toEqual(["b1"]);
    await t.park("B", [{ id: "b1" }]);
    expect(t.load("A").map((x: any) => x.id)).toEqual(["a1", "a2"]); // A signs in again: its changes are back, to be sent
  });

  it("the_board_handles_409_by_keeping_the_changes_and_saying_so", () => {
    expect(APP_JS).toMatch(/e\.status === 409/);
    expect(APP_JS).toContain("Signed in as another account in another tab");
    expect(APP_JS).not.toMatch(/store\(QUEUE_KEY, null\)/);           // a queue is parked, never deleted
  });
});
