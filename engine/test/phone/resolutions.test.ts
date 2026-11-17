import { describe, it, expect } from "vitest";
import { call } from "../helpers";
import { newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";
import { RESOLUTIONS_EXPORTS, RESOLUTIONS_JS } from "../../src/phone/resolutions-logic";
import { APP_JS } from "../../src/phone/client";
import { PAGE_HTML } from "../../src/phone/page";

// Resolutions on the phone (docs/superpowers/specs/2026-11-17-resolutions-design.md §6): the Mac sends this quarter's goals
// with the board copy; the phone's More › Resolutions shows them, read-only.

// eslint-disable-next-line no-new-func
const L: any = new Function(RESOLUTIONS_JS + "\nreturn {" + RESOLUTIONS_EXPORTS.join(",") + "};")();

const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
const goal = (n: number, over: Record<string, unknown> = {}) => ({ id: `R-${n}`, title: `Goal ${n}`, period: "Q4 2026", parent: "R-1 · Ship it",
  done: 1, open: 2, tasks: [1, 2], ...over });
const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });
const board = (cookie: string) => call("/app/api/board", { headers: { Cookie: cookie } }).then((r) => r.json<any>());

async function setup(name: string) {
  const u = await newUser(name);
  const { cookie } = await pairPhone(u.key);
  return { ...u, cookie };
}

describe("resolutions: goals in the board copy", () => {
  it("board_carries_this_quarters_goals_to_the_phone", async () => {
    const u = await setup("Goals");
    expect((await put(u.key, { cards: [card(1), card(2)], goals: [goal(4), goal(5, { parent: undefined, tasks: [] })] })).status).toBe(200);
    const b = await board(u.cookie);
    expect(b.goals).toEqual([goal(4), { ...goal(5), parent: null, tasks: [] }]);
  });

  it("no_goals_sent_means_none_shown", async () => {
    const u = await setup("No goals");
    await put(u.key, { cards: [card(1)] });
    expect((await board(u.cookie)).goals).toBeUndefined();
  });

  it("bad_goals_are_refused", async () => {
    const u = await setup("Bad goals");
    for (const goals of ["x", [goal(1, { id: "T-1" })], [goal(1, { title: "" })], [goal(1, { title: "x".repeat(201) })],
      [goal(1, { done: -1 })], [goal(1, { open: 1.5 })], [goal(1, { tasks: "1" })], [goal(1, { tasks: Array(51).fill(1) })],
      Array.from({ length: 11 }, (_, i) => goal(i + 1))]) {
      expect((await put(u.key, { cards: [card(1)], goals })).status).toBe(400);
    }
  });
});

describe("resolutions: the phone screen", () => {
  it("is_embedded_in_the_app_script_and_page", () => {
    expect(APP_JS).toContain(RESOLUTIONS_JS);
    expect(PAGE_HTML).toContain('id="goals"');
    expect(PAGE_HTML).not.toContain("Coming with the Resolutions area");
  });

  it("goals_view_lists_goals_with_counts_and_open_task_titles", () => {
    const cards = [card(1, { title: "Write it" }), card(2, { title: "Done since", status: "done" }), card(3, { title: "Other" })];
    const v = L.goalsView([goal(4, { tasks: [1, 2, 9] }), goal(5, { done: 0, open: 0, tasks: [], parent: null })], cards);
    expect(v.period).toBe("Q4 2026");
    expect(v.items[0]).toEqual({ id: "R-4", title: "Goal 4", parent: "under R-1 · Ship it", counts: "1 done · 2 open", tasks: ["Write it"] });
    expect(v.items[1]).toEqual({ id: "R-5", title: "Goal 5", parent: "", counts: "Nothing linked yet", tasks: [] });
  });

  it("goals_view_skips_bad_entries_and_handles_none", () => {
    expect(L.goalsView(undefined, []).items).toEqual([]);
    expect(L.goalsView([null, { id: 3 }, goal(6)], []).items.map((g: any) => g.id)).toEqual(["R-6"]);
  });

  it("more_row_says_how_many_goals", () => {
    expect(L.goalsSub([goal(1), goal(2)])).toBe("Q4 2026 · 2 goals");
    expect(L.goalsSub([goal(1)])).toBe("Q4 2026 · 1 goal");
    expect(L.goalsSub([])).toBe("No goals this quarter yet");
    expect(L.goalsSub(undefined)).toBe("No goals this quarter yet");
  });
});
