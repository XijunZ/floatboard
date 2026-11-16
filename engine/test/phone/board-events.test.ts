import { describe, it, expect } from "vitest";
import { call, newUser } from "../helpers";
import { pairPhone } from "../phone-helpers";

const card = (id: number) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1, due: null, has_time: false,
  status: "todo", link: null, done_at: null });
const ev = (n: number, over: Record<string, unknown> = {}) => ({ id: `E-${n}`, title: `Meeting ${n}`, start: "2026-11-16T10:00:00.000Z",
  end: "2026-11-16T11:00:00.000Z", all_day: false, video: "https://meet.example.com/x", color: "#112233", tasks: [1], ...over });
const put = (key: string, body: unknown) => call("/v2/board", { method: "PUT", key, body: JSON.stringify(body) });

describe("board events", () => {
  it("serves_events_to_phone", async () => {
    const u = await newUser("Events user");
    const { cookie } = await pairPhone(u.key);
    const r = await put(u.key, { cards: [card(1)], time_zone: "Europe/London", events: [ev(37, { title: "  Standup  " }), ev(38, { video: null, all_day: true })] });
    expect(r.status).toBe(200);
    const b = await (await call("/app/api/board", { headers: { Cookie: cookie } })).json<any>();
    expect(b.time_zone).toBe("Europe/London");
    expect(b.events).toHaveLength(2);
    expect(b.events[0]).toEqual({ id: "E-37", title: "Standup", start: "2026-11-16T10:00:00.000Z", end: "2026-11-16T11:00:00.000Z", all_day: false,
      video: "https://meet.example.com/x", color: "#112233", tasks: [1] });
    expect(b.events[1].video).toBeNull();
  });

  it("old_macs_without_events_still_accepted", async () => {
    const u = await newUser("Old mac");
    const { cookie } = await pairPhone(u.key);
    expect((await put(u.key, { cards: [card(1)] })).status).toBe(200);
    const b = await (await call("/app/api/board", { headers: { Cookie: cookie } })).json<any>();
    expect(b.cards).toHaveLength(1);
    expect(b.events).toBeUndefined();
  });

  it("rejects_non_https_video", async () => {
    const u = await newUser("Video user");
    for (const video of ["http://meet.example.com/x", "javascript:alert(1)", "not a url", 5]) {
      expect((await put(u.key, { cards: [], events: [ev(1, { video })] })).status).toBe(400);
    }
  });

  it("caps_events_at_50", async () => {
    const u = await newUser("Cap user");
    const many = (n: number) => Array.from({ length: n }, (_, i) => ev(i + 1, { tasks: [] }));
    expect((await put(u.key, { cards: [], events: many(50) })).status).toBe(200);
    expect((await put(u.key, { cards: [], events: many(51) })).status).toBe(400);
  });

  it("rejects_malformed_events", async () => {
    const u = await newUser("Strict user");
    const bad: Record<string, unknown>[] = [{ id: "E-0" }, { id: "37" }, { title: "x".repeat(201) }, { start: "nope" }, { all_day: "yes" },
      { color: "red" }, { tasks: [0] }, { tasks: [1.5] }, { tasks: Array.from({ length: 21 }, (_, i) => i + 1) }, { tasks: "1" }];
    for (const over of bad) expect((await put(u.key, { cards: [], events: [ev(1, over)] })).status).toBe(400);
    expect((await put(u.key, { cards: [], events: "x" })).status).toBe(400);
    expect((await put(u.key, { cards: [], time_zone: "Nowhere/Land" })).status).toBe(400);
  });
});
