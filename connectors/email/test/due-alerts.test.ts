import { describe, it, expect, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import { call, newUser } from "./helpers";
import { api, count, pairPhone } from "./app-helpers";
import { setNtfyFetch } from "../src/alerts";
import { setTelegramFetch } from "../src/telegram";
import { dueAlertText, purgeDueAlerts, runDueAlerts } from "../src/due";
import worker from "../src/index";

/** Due reminders for every task on the board copy: every 15 minutes, once per (user, card, due value). */
let ntfy: { headers: Record<string, string>; body: string }[] = [];
beforeEach(() => {
  ntfy = [];
  setNtfyFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
    ntfy.push({ headers: init?.headers as Record<string, string>, body: String(init?.body) });
    return new Response("{}");
  }) as typeof fetch);
  setTelegramFetch((async () => Response.json({ ok: true, result: {} })) as typeof fetch);
});

const NY = "America/New_York";
const at = (s: string) => Date.parse(s);
const card = (id: number, over: Record<string, unknown> = {}) => ({ id, title: `Task ${id}`, group: "Work", color: "#aabbcc", importance: 1,
  due: null, has_time: false, status: "todo", link: null, done_at: null, ...over });
const put = (key: string, cards: unknown[]) => call("/v2/board", { method: "PUT", key, body: JSON.stringify({ cards }) });

async function userWithNtfy(name: string, zone: string | null = NY) {
  const u = await newUser(name);
  await env.DB.prepare("UPDATE users SET ntfy_topic='due-topic' WHERE id=?").bind(u.id).run();
  await env.DB.prepare("UPDATE settings SET time_zone=? WHERE user_id=?").bind(zone, u.id).run();
  return u;
}

describe("due alert windows", () => {
  // 14:30 in New York on 12 Nov 2026 (EST, UTC-5) is 19:30 UTC.
  const timed = { status: "todo", due: "2026-11-12T14:30:00-05:00", has_time: true };

  it("timed_due_alerts_from_15_minutes_before_until_15_minutes_after", () => {
    expect(dueAlertText(timed, at("2026-11-12T19:14:59Z"), NY)).toBeNull();
    expect(dueAlertText(timed, at("2026-11-12T19:15:00Z"), NY)).toBe("Due 14:30");
    expect(dueAlertText(timed, at("2026-11-12T19:30:00Z"), NY)).toBe("Due 14:30");
    expect(dueAlertText(timed, at("2026-11-12T19:44:59Z"), NY)).toBe("Due 14:30");
    expect(dueAlertText(timed, at("2026-11-12T19:45:00Z"), NY)).toBeNull();
    // The time is shown in the user's zone, not UTC.
    expect(dueAlertText(timed, at("2026-11-12T19:20:00Z"), "Europe/London")).toBe("Due 19:30");
  });

  it("date_only_due_alerts_on_that_day_after_9_in_the_users_zone", () => {
    const d = { status: "doing", due: "2026-11-12", has_time: false };
    expect(dueAlertText(d, at("2026-11-12T13:59:00Z"), NY)).toBeNull();          // 08:59 in New York
    expect(dueAlertText(d, at("2026-11-12T14:00:00Z"), NY)).toBe("Due today");   // 09:00 in New York
    expect(dueAlertText(d, at("2026-11-13T02:00:00Z"), NY)).toBe("Due today");   // 21:00 on the 12th in New York, the 13th in UTC
    expect(dueAlertText(d, at("2026-11-13T14:00:00Z"), NY)).toBeNull();          // the next day
    expect(dueAlertText(d, at("2026-11-11T15:00:00Z"), NY)).toBeNull();          // the day before
    // In UTC the same instant is already the 13th: no alert for the 12th.
    expect(dueAlertText(d, at("2026-11-13T02:00:00Z"), "UTC")).toBeNull();
  });

  it("only_open_tasks_with_a_due_get_an_alert", () => {
    const now = at("2026-11-12T19:20:00Z");
    for (const status of ["todo", "doing", "watch"]) expect(dueAlertText({ ...timed, status }, now, NY)).toBe("Due 14:30");
    expect(dueAlertText({ ...timed, status: "done" }, now, NY)).toBeNull();
    expect(dueAlertText({ ...timed, due: null }, now, NY)).toBeNull();
  });
});

describe("due alerts from the board copy", () => {
  const now = at("2026-11-12T19:20:00Z"); // 14:20 in New York

  it("alerts_once_per_card_and_due_value", async () => {
    const u = await userWithNtfy("Due once");
    expect((await put(u.key, [card(1, { title: "Call the bank", due: "2026-11-12T14:30:00-05:00", has_time: true }),
      card(2, { due: "2026-11-12" }), card(3)])).status).toBe(200);
    await runDueAlerts(env as any, now);
    expect(ntfy.map((n) => n.headers.Title).sort()).toEqual(["Call the bank", "Task 2"]);
    expect(ntfy.find((n) => n.headers.Title === "Call the bank")!.body).toContain("Due 14:30");
    expect(ntfy.find((n) => n.headers.Title === "Task 2")!.body).toContain("Due today");
    ntfy = [];
    await runDueAlerts(env as any, now + 10 * 60_000);
    expect(ntfy).toHaveLength(0); // once only
    // A new due value is a new reminder.
    await put(u.key, [card(1, { title: "Call the bank", due: "2026-11-12T14:40:00-05:00", has_time: true })]);
    await runDueAlerts(env as any, now + 10 * 60_000);
    expect(ntfy.map((n) => n.headers.Title)).toEqual(["Call the bank"]);
    expect(await count("SELECT COUNT(*) AS n FROM due_alerts_sent WHERE user_id=?", u.id)).toBe(3);
  });

  it("done_task_gets_no_alert_also_when_the_phone_moved_it", async () => {
    const u = await userWithNtfy("Due done");
    const { cookie } = await pairPhone(u.key);
    await put(u.key, [card(1, { status: "done", due: "2026-11-12", done_at: "2026-11-12T10:00:00Z" }), card(2, { due: "2026-11-12" })]);
    const r = await api("/app/api/action", { actions: [{ id: "move-0000-1", card_id: 2, action: "done" }] }, { cookie });
    expect(r.status).toBe(200);
    await runDueAlerts(env as any, now);
    expect(ntfy).toHaveLength(0);
  });

  it("alerts_off_sends_nothing_and_records_nothing", async () => {
    const u = await userWithNtfy("Due off");
    await env.DB.prepare("UPDATE settings SET alerts_on=0 WHERE user_id=?").bind(u.id).run();
    await put(u.key, [card(1, { due: "2026-11-12" })]);
    await runDueAlerts(env as any, now);
    expect(ntfy).toHaveLength(0);
    expect(await count("SELECT COUNT(*) AS n FROM due_alerts_sent WHERE user_id=?", u.id)).toBe(0);
  });

  it("an_alert_that_could_not_be_sent_is_tried_again", async () => {
    const u = await userWithNtfy("Due retry");
    await put(u.key, [card(1, { due: "2026-11-12" })]);
    setNtfyFetch((async () => new Response("{}", { status: 500 })) as typeof fetch);
    await runDueAlerts(env as any, now);
    expect(await count("SELECT COUNT(*) AS n FROM due_alerts_sent WHERE user_id=?", u.id)).toBe(0);
    setNtfyFetch((async (_u: RequestInfo | URL, init?: RequestInit) => {
      ntfy.push({ headers: init?.headers as Record<string, string>, body: String(init?.body) });
      return new Response("{}");
    }) as typeof fetch);
    await runDueAlerts(env as any, now + 15 * 60_000);
    expect(ntfy).toHaveLength(1);
  });

  it("each_user_gets_only_their_own_tasks", async () => {
    const a = await userWithNtfy("Due A");
    const b = await newUser("Due B"); // no channel: nothing reaches anyone for B's tasks
    await put(a.key, [card(1, { title: "A task", due: "2026-11-12" })]);
    await put(b.key, [card(1, { title: "B task", due: "2026-11-12" })]);
    await runDueAlerts(env as any, now);
    expect(ntfy.map((n) => n.headers.Title)).toEqual(["A task"]);
  });

  it("sent_records_are_purged_after_30_days", async () => {
    const u = await newUser("Due purge");
    const old = new Date(Date.now() - 31 * 86400_000).toISOString();
    await env.DB.prepare("INSERT INTO due_alerts_sent(user_id,card_id,due,sent_at) VALUES(?,?,?,?),(?,?,?,?)")
      .bind(u.id, 1, "2026-10-01", old, u.id, 2, "2026-11-12", new Date().toISOString()).run();
    await purgeDueAlerts(env as any);
    expect(await count("SELECT COUNT(*) AS n FROM due_alerts_sent WHERE user_id=?", u.id)).toBe(1);
  });

  it("the_15_minute_cron_sends_due_alerts_and_the_hourly_one_does_not", async () => {
    const u = await userWithNtfy("Due cron");
    const soon = new Date(Date.now() + 5 * 60_000).toISOString();
    await put(u.key, [card(1, { title: "Soon", due: soon, has_time: true })]);
    const waits: Promise<unknown>[] = [];
    const ctx = { waitUntil: (p: Promise<unknown>) => { waits.push(p); }, passThroughOnException() {} } as unknown as ExecutionContext;
    await worker.scheduled!({ cron: "0 * * * *", scheduledTime: Date.now() } as ScheduledController, env as any, ctx);
    await Promise.all(waits);
    expect(ntfy.filter((n) => n.headers.Title === "Soon")).toHaveLength(0);
    await worker.scheduled!({ cron: "*/15 * * * *", scheduledTime: Date.now() } as ScheduledController, env as any, ctx);
    await Promise.all(waits);
    expect(ntfy.filter((n) => n.headers.Title === "Soon")).toHaveLength(1);
  });
});
