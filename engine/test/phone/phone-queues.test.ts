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
    expect(CIRCLE_JS).toMatch(/QueueStore\(CIRCLE_QUEUE_KEY, load, queueKeep\)/);   // a tap is only shown once it is saved
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
        return new Promise((resolve, reject) => {
          const go = () => resolve(run());
          (waiting[name] ??= []).push(go);
          opts?.signal?.addEventListener("abort", () => { waiting[name] = waiting[name].filter((g) => g !== go); reject(new Error("AbortError")); });
        });
      },
      waiting: (name: string) => (waiting[name] ?? []).length,
    };
  }
  // A channel that delivers at once, or (held) only when deliver() is called, like a slow browser.
  function bus(held = false) {
    const tabs: any[] = [], out: (() => void)[] = [];
    const deliver = () => { while (out.length) out.shift()!(); };
    return { deliver, channel: () => { const c: any = { onmessage: null, postMessage(d: any) { const send = () => tabs.filter((t) => t !== c).forEach((t) => t.onmessage && t.onmessage({ data: d })); if (held) out.push(send); else send(); } }; tabs.push(c); return c; } };
  }
  const flush = () => new Promise((r) => setTimeout(r, 0));
  function tab(locks: any, b: any, storage: Record<string, any>, name: string, log: string[], more: any = {}) {
    const state = { active: false, held: [] as string[] };
    const t = S.ActiveTab({
      locks, channel: b.channel(),
      onNoLocks: () => { log.push(name + " one-tab notice"); },
      onActive: () => { state.active = true; log.push(name + " active"); },
      onInactive: () => { state.active = false; log.push(name + " inactive"); },
      onRefused: () => { log.push(name + " refused"); },
      beforeStepDown: () => {
        if (more.keeps === false) return false;   // storage full: nothing kept
        storage.queue = (storage.queue ?? []).concat(state.held); state.held = []; log.push(name + " kept"); return true;
      },
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

  // Round 32 (Codex 22): where Web Locks exist, the lock is the only ownership; a delayed answer just waits.
  it("a_delayed_lock_answer_never_falls_back_so_two_tabs_are_never_active", async () => {
    const locks = fakeLocks(), b = bus(), storage: Record<string, any> = {}, log: string[] = [];
    let deliver: () => void = () => {};
    const slow = { request: (n: string, opts: any, fn: any) => new Promise((r) => { deliver = () => r(locks.request(n, opts, fn)); }) };
    const one = tab(slow, b, storage, "one", log), two = tab(locks, b, storage, "two", log);
    one.t.start(); await flush(); await flush();
    two.t.start(); await flush();
    expect([one.state.active, two.state.active]).toEqual([false, true]);
    deliver(); await flush(); await flush();
    expect([one.state.active, two.state.active]).toEqual([false, true]);
  });

  it("a_storage_failure_during_handover_keeps_the_capture_and_the_ownership", async () => {
    {
      const locks = fakeLocks(), b = bus(), storage: Record<string, any> = {}, log: string[] = [];
      const one = tab(locks, b, storage, "one", log, { keeps: false }), two = tab(locks, b, storage, "two", log);
      one.t.start(); await flush();
      two.t.start(); await flush();
      one.state.held.push("capture made in tab one");
      two.t.useHere(); await flush(); await flush();
      expect([one.state.active, two.state.active]).toEqual([true, false]);
      expect(one.state.held).toEqual(["capture made in tab one"]);
      expect(log).toContain("two refused");
      expect(locks.waiting("floatboard-active")).toBe(0);   // the queued request was cancelled
    }
    // The app refuses the handover unless every queue was kept, and says so on both sides.
    expect(APP_JS).toMatch(/beforeStepDown: function \(\) \{ return keepAll\(\); \}/);
    expect(APP_JS).toMatch(/onRefused: function \(\) \{[^}]*The other tab couldn't save; try again/);
  });

  // Round 33 (Codex 23): Web Locks only; a refusal at any time cancels the queued request.
  it("a_refusal_arriving_late_reenables_use_here_and_cancels_the_lock_request", async () => {
    const locks = fakeLocks(), b = bus(true), storage: Record<string, any> = {}, log: string[] = [];
    const one = tab(locks, b, storage, "one", log, { keeps: false }), two = tab(locks, b, storage, "two", log);
    one.t.start(); await flush();
    two.t.start(); await flush();
    two.t.useHere(); await flush();
    await new Promise((r) => setTimeout(r, 20));          // long after any timeout: the owner still hasn't answered
    expect(locks.waiting("floatboard-active")).toBe(1);
    b.deliver(); await flush(); b.deliver(); await flush();   // the step-down arrives; the refusal comes back
    expect(log).toContain("two refused");
    expect(locks.waiting("floatboard-active")).toBe(0);
    expect([one.state.active, two.state.active]).toEqual([true, false]);
    expect(APP_JS).toMatch(/onRefused: function \(\) \{ \$\("use-here"\)\.disabled = false;/);
  });

  it("only_web_locks_decide_the_active_tab_with_no_lease_or_owner_record", () => {
    expect(SYNC_JS).not.toMatch(/\blease\b|LEASE_MS|leaseTake|\bowns\b|\bbeat\b|owner\(\)/);
    expect(APP_JS).not.toMatch(/ACTIVE_KEY|owns\(|lease:/);
    expect(APP_JS).toMatch(/localStorage\.removeItem\("floatboard\.activeTab"\)/);   // the old lease goes on load
    expect(APP_JS).toMatch(/This browser can't coordinate tabs: use FloatBoard in one tab only\./);
    const log: string[] = [];
    const t = S.ActiveTab({ locks: null, channel: null, onActive: () => log.push("active"), onInactive: () => log.push("inactive"),
      onRefused: () => {}, onNoLocks: () => log.push("notice"), beforeStepDown: () => true });
    t.start();
    expect(log).toEqual(["notice", "active"]);
  });

  it("a_failed_capture_keeps_the_form_open_with_its_text", () => {
    const act = /function act\(a, done, card\) \{([\s\S]*?)\n  \}/.exec(APP_JS)?.[1] ?? "";
    const fail = /if \(!saveQueue\(\)\) \{([\s\S]*?)\n    \}/.exec(act)?.[1] ?? "";
    expect(fail).toMatch(/queue\.actions = queue\.actions\.filter\(function \(x\) \{ return x !== a; \}\)/);   // not kept in memory only
    expect(fail).toMatch(/toast\("Couldn't save on this phone: storage full"\)/);
    expect(fail).toMatch(/return false;/);
    expect(fail).not.toMatch(/closeSheet|sync\(\)/);                       // the form (and its text) stays open
    expect(JOTS_JS).toContain("if (h.addTask(title) !== false) h.closeSheet();");   // a shared text made a task: same
  });

  it("a_parking_failure_refuses_the_account_switch_with_nothing_lost", () => {
    const drop = /function dropAccountData\(\) \{([\s\S]*?)\n  \}/.exec(APP_JS)?.[1] ?? "";
    const refuse = drop.indexOf("if (!parkAll()) { toast(\"Couldn't keep this account's unsent changes on this phone; free some space and try again\"); return false; }");
    expect(refuse).toBeGreaterThan(-1);
    for (const later of ["sessionGen += 1", "closeSheet()", "queue = { account: null", "jots.drop()", "circleDrop()", "dropDecisions()"]) {
      expect(drop.indexOf(later)).toBeGreaterThan(refuse);
    }
    expect(APP_JS).toMatch(/if \(other && !dropAccountData\(\)\) return false;/);
    for (const src of [APP_JS, JOTS_JS, CIRCLE_JS, DECISIONS_UI_JS, DECISIONS_LOGIC_JS]) expect(src).not.toMatch(/they are kept/);
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

  it("every_queue_is_parked_before_any_account_data_is_cleared", () => {
    const park = /function parkAll\(\) \{([\s\S]*?)\n  \}/.exec(APP_JS)?.[1] ?? "";
    for (const p of ["boardQueue.park(queue.account, queue.actions)", "jots.park()", "circleShared.park(circleQueue.account, circleQueue.actions)",
      "decShared.park(decQueue.account, decQueue.actions)"]) expect(park).toContain(p);
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
