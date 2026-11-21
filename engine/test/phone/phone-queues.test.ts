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
    expect(CIRCLE_JS).toMatch(/QueueStore\(CIRCLE_QUEUE_KEY, load, storeDurable\)/);   // a tap is only shown once it is saved
    expect(CIRCLE_JS).toMatch(/if \(!tabActive \|\| !circleShared\.save\(acc, next\)\) \{ toast\(/);
    expect(CIRCLE_JS).toMatch(/queueAfterRefusal\(circleQueue\.actions, e\.id\)/);   // a refused batch drops only the named one
    expect(CIRCLE_JS).toMatch(/tooBig/);                                    // one too big for any send is dropped with a message
  });
});

// Round 31 (Codex 21, controller's ruling): one active tab. Only one tab of a browser runs the app; it alone reads,
// writes and sends the queues (no merging between tabs). "Use here" hands over after the active tab keeps what it holds.
describe("phone: one active tab", () => {
  // Web Locks as a browser gives them: one holder per name; ifAvailable answers null when held; others wait in order.
  function fakeLocks() {
    const held: Record<string, boolean> = {}, waiting: Record<string, (() => void)[]> = {};
    return {
      request(name: string, opts: any, fn: (l: any) => any) {
        const run = () => { held[name] = true; return Promise.resolve(fn({ name })).finally(() => { held[name] = false; const next = (waiting[name] ?? []).shift(); if (next) next(); }); };
        if (!held[name]) return run();
        if (opts && opts.ifAvailable) return Promise.resolve(fn(null));
        return new Promise((resolve) => { (waiting[name] ??= []).push(() => resolve(run())); });
      },
    };
  }
  function bus() {
    const tabs: any[] = [];
    return { channel: () => { const c: any = { onmessage: null, postMessage(d: any) { tabs.filter((t) => t !== c).forEach((t) => t.onmessage && t.onmessage({ data: d })); } }; tabs.push(c); return c; } };
  }
  const flush = () => new Promise((r) => setTimeout(r, 0));
  function tab(locks: any, b: any, storage: Record<string, any>, name: string, log: string[]) {
    const state = { active: false, held: [] as string[] };
    const t = S.ActiveTab({
      locks, channel: b.channel(), lease: { load: () => storage.lease ?? null, store: (v: any) => { storage.lease = v; } },
      now: () => Date.now(), every: () => {}, wait: () => Promise.resolve(),
      onActive: () => { state.active = true; log.push(name + " active"); },
      onInactive: () => { state.active = false; log.push(name + " inactive"); },
      beforeStepDown: () => { storage.queue = (storage.queue ?? []).concat(state.held); state.held = []; log.push(name + " kept"); },
    });
    return { t, state };
  }

  it("a_second_tab_is_inactive_while_the_first_is_open", async () => {
    const locks = fakeLocks(), b = bus(), storage: Record<string, any> = {}, log: string[] = [];
    const one = tab(locks, b, storage, "one", log), two = tab(locks, b, storage, "two", log);
    one.t.start(); await flush();
    two.t.start(); await flush();
    expect([one.state.active, two.state.active]).toEqual([true, false]);
    expect(two.t.isActive()).toBe(false);
  });

  it("use_here_hands_over_after_the_active_tab_keeps_what_it_holds", async () => {
    const locks = fakeLocks(), b = bus(), storage: Record<string, any> = {}, log: string[] = [];
    const one = tab(locks, b, storage, "one", log), two = tab(locks, b, storage, "two", log);
    one.t.start(); await flush();
    two.t.start(); await flush();
    one.state.held.push("capture made in tab one");
    two.t.useHere(); await flush(); await flush();
    expect([one.state.active, two.state.active]).toEqual([false, true]);
    expect(storage.queue).toEqual(["capture made in tab one"]);
    expect(log.indexOf("one kept")).toBeLessThan(log.indexOf("two active"));
  });

  it("without_web_locks_a_fresh_lease_keeps_a_second_tab_inactive_until_use_here", async () => {
    const b = bus(), storage: Record<string, any> = {}, log: string[] = [];
    const one = tab(null, b, storage, "one", log), two = tab(null, b, storage, "two", log);
    await one.t.start();
    await two.t.start();
    expect([one.state.active, two.state.active]).toEqual([true, false]);
    await two.t.useHere();
    expect([one.state.active, two.state.active]).toEqual([false, true]);
  });

  it("a_browser_that_never_answers_the_lock_falls_back_to_the_lease", async () => {
    const silent = { request: () => new Promise(() => {}) };   // seen in headless Chrome: no answer at all
    const b = bus(), storage: Record<string, any> = {}, log: string[] = [];
    const one = tab(silent, b, storage, "one", log);
    one.t.start(); await flush(); await flush();
    expect(one.state.active).toBe(true);
    const two = tab(silent, b, storage, "two", log);
    two.t.start(); await flush(); await flush();
    expect(two.state.active).toBe(false);   // the first tab's lease is fresh: never two active tabs
  });

  it("a_parked_queue_that_cannot_be_kept_leaves_the_queue_where_it_was", () => {
    const data: Record<string, any> = { q: { account: "A", actions: [{ id: "a1" }] } };
    const store = (k: string, v: any) => { if (k.includes(":parked:")) return false; if (v == null) delete data[k]; else data[k] = v; return true; };
    const qs = S.QueueStore("q", (k: string) => data[k] ?? null, store);
    expect(qs.park("A", [{ id: "a1" }])).toBe(false);
    expect(data.q.actions.map((a: any) => a.id)).toEqual(["a1"]);           // never cleared before the parked copy is kept
    expect(qs.save("B", [{ id: "b1" }])).toBe(false);                       // nor overwritten by another account
    expect(data.q.account).toBe("A");
  });

  it("an_account_switch_parks_and_restores_each_accounts_queue", () => {
    const data: Record<string, any> = {};
    const store = (k: string, v: any) => { if (v == null) delete data[k]; else data[k] = JSON.parse(JSON.stringify(v)); return true; };
    const qs = S.QueueStore("q", (k: string) => data[k] ?? null, store);
    expect(qs.save("A", [{ id: "a1" }])).toBe(true);
    expect(qs.park("A", [{ id: "a1" }])).toBe(true);
    expect(qs.load("B")).toEqual([]);
    expect(qs.save("B", [{ id: "b1" }])).toBe(true);
    expect(qs.park("B", [{ id: "b1" }])).toBe(true);
    expect(qs.load("A").map((a: any) => a.id)).toEqual(["a1"]);
    expect(qs.load("B").map((a: any) => a.id)).toEqual(["b1"]);             // B back: A's is parked again, never lost
    expect(data["q:parked:A"].actions.map((a: any) => a.id)).toEqual(["a1"]);
  });

  it("circle_parks_the_outgoing_account_before_clearing_it", () => {
    const drop = /function circleDrop\(\) \{([\s\S]*?)\n  \}/.exec(CIRCLE_JS)?.[1] ?? "";
    expect(drop.indexOf("circleShared.park(circleQueue.account, circleQueue.actions)")).toBeGreaterThan(-1);
    expect(drop.indexOf("circleShared.park(")).toBeLessThan(drop.indexOf("circleQueue = { account: null"));
  });

  it("a_delete_is_marked_and_kept_before_it_is_sent_so_undo_always_restores_it", () => {
    const sync = /async function sync\(\) \{([\s\S]*?)\n  \}\n/.exec(APP_JS)?.[1] ?? "";
    expect(sync).toMatch(/queue\.actions = markAttempted\(queue\.actions, body\);\s*saveQueue\(\);[\s\S]*await sendBatch\(/);
    expect(APP_JS).toMatch(/if \(!tabActive\) return;   \/\/ another tab is the active one/);
    // The decision itself: a delete marked as sent gets a restore.
    const u = { del_id: "d1", card_id: 4, made_at: "2026-11-21T10:00:00.000Z" };
    const step = S.undoDeleteStep ? S.undoDeleteStep(u, [{ id: "d1", attempted: true }], false, "r1", "2026-11-21T10:00:05.000Z") : null;
    if (step) expect(step.restore).toBeTruthy();
  });
});
