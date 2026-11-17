import { describe, expect, it } from "vitest";
import { SYNC_EXPORTS, SYNC_JS } from "../../src/phone/sync-logic";

/** The phone's planning summary (Today, rest of this week, next week): the exact text embedded in /app/app.js. */
// eslint-disable-next-line no-new-func
const L: any = new Function(SYNC_JS + "\nreturn {" + SYNC_EXPORTS.join(",") + "};")();

const Z = "Europe/London";
// Wednesday 18 Nov 2026, 08:00 in London (UTC in November).
const NOW = Date.parse("2026-11-18T08:00:00Z");
const ev = (id: string, start: string, over: Record<string, unknown> = {}) => ({ id, title: id, start, end: new Date(Date.parse(start) + 3600e3).toISOString(),
  all_day: false, video: null, color: "#112233", tasks: [], ...over });
const card = (id: number, due: string | null, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, status: "todo", due, has_time: !!due && due.length > 10, ...over });

describe("phone planning summary", () => {
  it("splits_into_today_rest_of_week_and_next_week", () => {
    const blocks = L.planBlocks([
      ev("Today call", "2026-11-18T10:00:00Z"),
      ev("Friday review", "2026-11-20T14:00:00Z"),
      ev("Sunday dinner", "2026-11-22T18:00:00Z"),
      ev("Monday kickoff", "2026-11-23T09:00:00Z"),
      ev("Next Sunday", "2026-11-29T09:00:00Z"),
      ev("Too far", "2026-11-30T09:00:00Z"),
      ev("Yesterday", "2026-11-17T09:00:00Z"),
    ], [card(1, "2026-11-18"), card(2, "2026-11-21T09:30:00Z"), card(3, "2026-11-24"), card(4, "2026-11-18", { status: "done" }), card(5, null), card(6, "2026-12-01")], NOW, Z);
    expect(blocks.map((b: any) => b.title)).toEqual(["Today", "Rest of this week", "Next week"]);
    expect(blocks[0].meetings.map((m: any) => [m.when, m.title])).toEqual([["10:00", "Today call"]]);
    expect(blocks[1].meetings.map((m: any) => [m.when, m.title])).toEqual([["Fri 14:00", "Friday review"], ["Sun 18:00", "Sunday dinner"]]);
    expect(blocks[2].meetings.map((m: any) => m.title)).toEqual(["Monday kickoff", "Next Sunday"]);
    expect(blocks.map((b: any) => b.tasks.map((c: any) => c.id))).toEqual([[1], [2], [3]]);
  });

  it("lists_a_repeating_meeting_once_per_block_with_its_label", () => {
    const standup = (d: string, tasks: number[] = []) => ev(`E-${d}`, `2026-11-${d}T09:00:00Z`, { title: "Standup", series: "S-abc", repeat: "weekdays 09:00", tasks,
      video: d === "18" ? "https://meet.example.com/today" : "https://meet.example.com/other" });
    const all = ["18", "19", "20", "23", "24", "25", "26", "27"].map((d) => standup(d, d === "19" ? [7] : []));
    all.push(ev("No rule yet", "2026-11-19T11:00:00Z", { series: "S-def" }));
    const blocks = L.planBlocks(all, [], NOW, Z);
    const titles = (b: any) => b.meetings.map((m: any) => `${m.when}|${m.title}${m.label ? " · " + m.label : ""}`);
    expect(titles(blocks[0])).toEqual(["|Standup · weekdays 09:00"]);
    expect(blocks[0].meetings[0].video).toBe("https://meet.example.com/today");
    expect(titles(blocks[1])).toEqual(["|Standup · weekdays 09:00", "|No rule yet · repeats"]);
    expect(blocks[1].meetings[0].tasks).toEqual([7]);
    expect(titles(blocks[2])).toEqual(["|Standup · weekdays 09:00"]);
  });

  it("sunday_has_no_rest_of_week_and_all_day_events_show_as_such", () => {
    const sunday = Date.parse("2026-11-22T10:00:00Z");
    const blocks = L.planBlocks([ev("Holiday", "2026-11-22T00:00:00Z", { all_day: true, end: "2026-11-24T00:00:00Z" })], [], sunday, Z);
    expect(blocks.map((b: any) => b.title)).toEqual(["Today", "Next week"]);
    expect(blocks[0].meetings[0].when).toBe("All day");
    expect(blocks[1].meetings[0].when).toBe("Mon");
  });

  it("bad_entries_are_skipped_not_fatal", () => {
    const blocks = L.planBlocks([{ id: "E-1", start: "nope" }, null, ev("Fine", "2026-11-18T12:00:00Z", { series: 5, repeat: {} })], [null, { id: 9 }], NOW, Z);
    expect(blocks[0].meetings.map((m: any) => [m.title, m.label])).toEqual([["Fine", null]]);
  });
});
