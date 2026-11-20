import { describe, expect, it } from "vitest";
import { SYNC_EXPORTS, SYNC_JS } from "../../src/phone/sync-logic";
import { CIRCLE_JS } from "../../src/phone/circle-client";
import { DECISIONS_LOGIC_JS, DECISIONS_UI_JS } from "../../src/phone/decisions-client";
import { JOTS_JS } from "../../src/phone/jots-logic";

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
