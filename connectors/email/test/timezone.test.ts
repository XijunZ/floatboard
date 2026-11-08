import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { isCritical, wallClockToDate } from "../src/run";
import { classify, nowIn } from "../src/classify";
import { DEFAULT_TIME_ZONE, isTimeZone } from "../src/time";
import { makeClient } from "../src/llm";
import { HAIKU } from "../src/llm";
import { call, newUser } from "./helpers";
import type { Action } from "../src/classify";
import type { Message } from "../src/sources/types";

const act = (over: Partial<Action> = {}): Action => ({ title: "Do it", why: "asked", due: null, hasTime: false, importance: 1, group: null, urgent: false, ...over });
const put = (key: string, version: number, values: unknown) =>
  call("/v2/settings", { key, method: "PUT", body: JSON.stringify({ version, values }) });
const exported = async (key: string) => (await (await call("/v2/export", { key })).json<any>()).settings;

describe("time zone", () => {
  it("due_times_are_read_in_the_users_zone", () => {
    expect(wallClockToDate("2026-07-10T12:00", "America/New_York").toISOString()).toBe("2026-07-10T16:00:00.000Z"); // EDT
    expect(wallClockToDate("2027-01-10T12:00", "America/New_York").toISOString()).toBe("2027-01-10T17:00:00.000Z"); // EST
    expect(wallClockToDate("2026-07-10T12:00", "Asia/Tokyo").toISOString()).toBe("2026-07-10T03:00:00.000Z");
    expect(wallClockToDate("2026-07-10", "Asia/Tokyo").toISOString()).toBe("2026-07-10T14:59:00.000Z"); // date only = 23:59
    expect(wallClockToDate("2026-07-10T12:00", DEFAULT_TIME_ZONE).toISOString()).toBe("2026-07-10T12:00:00.000Z");
  });

  it("critical_uses_the_users_zone", () => {
    const now = new Date("2026-07-10T09:00:00Z");
    // 2026-07-11 08:00 in Tokyo is 2026-07-10 23:00 UTC: 14 h away. In UTC it would be 23 h away.
    expect(isCritical(act({ due: "2026-07-11T08:00", hasTime: true }), now, 20, "Asia/Tokyo")).toBe(true);
    expect(isCritical(act({ due: "2026-07-11T08:00", hasTime: true }), now, 20, "UTC")).toBe(false);
  });

  it("valid_zones_are_iana_names", () => {
    expect(isTimeZone("Europe/Berlin")).toBe(true);
    expect(isTimeZone("UTC")).toBe(true);
    expect(isTimeZone("Mars/Olympus")).toBe(false);
    expect(isTimeZone("")).toBe(false);
    expect(isTimeZone(5)).toBe(false);
  });

  it("classifier_is_told_now_in_the_users_zone", async () => {
    const bodies: string[] = [];
    const f = (async (_u: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body));
      return Response.json({ id: "m", type: "message", role: "assistant", model: HAIKU, stop_reason: "end_turn", stop_sequence: null,
        content: [{ type: "text", text: JSON.stringify({ action_required: false, title: "", why: "", due: null, has_time: false, importance: 1, group: null, urgent: false }) }],
        usage: { input_tokens: 1, output_tokens: 1 } });
    }) as typeof fetch;
    const m: Message = { messageId: "<t@x>", sourceId: "s", from: "a@b.com", to: ["me@x.com"], cc: [], subject: "Hi", date: "", labels: [], headers: {}, text: "hello", link: "" };
    await classify(m, ["me@x.com"], [], makeClient("sk", f), [], { timeZone: "Asia/Tokyo" });
    await classify(m, ["me@x.com"], [], makeClient("sk", f));
    const users = bodies.map((b) => JSON.parse(b).messages[0].content as string);
    expect(users[0]).toMatch(/Now \(Asia\/Tokyo\): \w+day \d{4}-\d{2}-\d{2} \d{2}:\d{2}/);
    expect(users[1]).toMatch(/Now \(UTC\): /);
    expect(nowIn("Asia/Tokyo", new Date("2026-07-10T20:30:00Z"))).toBe("Saturday 2026-07-11 05:30");
  });

  it("time_zone_setting_round_trip_and_validation", async () => {
    const u = await newUser("T");
    expect(await exported(u.key)).toMatchObject({ time_zone: "UTC" }); // default when unset
    expect((await put(u.key, 1, { time_zone: "America/Sao_Paulo" })).status).toBe(200);
    expect(await exported(u.key)).toMatchObject({ time_zone: "America/Sao_Paulo" });
    const bad = await put(u.key, 2, { time_zone: "Nowhere/Special" });
    expect(bad.status).toBe(400);
    expect((await bad.json<any>()).error).toMatch(/time_zone/);
    expect((await put(u.key, 2, { time_zone: 3 })).status).toBe(400);
    expect(await exported(u.key)).toMatchObject({ time_zone: "America/Sao_Paulo" });
    const status = await (await call("/v2/status", { key: u.key })).json<any>();
    expect(status.schema.map((f: any) => f.key)).not.toContain("time_zone"); // sent by the app, never shown
  });

  it("stored_zone_reaches_the_run", async () => {
    const u = await newUser("R");
    await put(u.key, 1, { time_zone: "Pacific/Auckland" });
    const row = await env.DB.prepare("SELECT time_zone FROM settings WHERE user_id=?").bind(u.id).first<{ time_zone: string }>();
    expect(row?.time_zone).toBe("Pacific/Auckland");
  });
});
