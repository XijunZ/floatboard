import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";
import { cronJobs, CRON, OLD_CRON, runAllUsers } from "../src/index";

describe("one cron schedule, every 5 minutes", () => {
  it("every_run_reads_and_sends_reminders", () => {
    expect(cronJobs(CRON, Date.parse("2026-11-12T23:05:00Z"))).toEqual({ due: true, read: true, hourly: false });
    expect(cronJobs(CRON, Date.parse("2026-11-12T23:55:00Z"))).toEqual({ due: true, read: true, hourly: false });
  });
  it("the_run_on_the_hour_also_does_the_hourly_work", () => {
    expect(cronJobs(CRON, Date.parse("2026-11-12T23:00:00Z"))).toEqual({ due: true, read: true, hourly: true });
    expect(cronJobs(CRON, Date.parse("2026-11-12T23:00:07Z"))).toEqual({ due: true, read: true, hourly: true });
  });
  it("a_config_still_on_15_minutes_keeps_working", () => {
    expect(cronJobs(OLD_CRON, Date.parse("2026-11-12T23:15:00Z"))).toEqual({ due: true, read: true, hourly: false });
    expect(cronJobs(OLD_CRON, Date.parse("2026-11-12T23:00:00Z"))).toEqual({ due: true, read: true, hourly: true });
  });
  it("an_old_hourly_schedule_does_everything_but_reminders", () => {
    expect(cronJobs("0 * * * *", Date.parse("2026-11-12T23:00:00Z"))).toEqual({ due: false, read: true, hourly: true });
  });
});

describe("hourly work only on the hour", () => {
  const expired = () => env.DB.prepare("INSERT INTO setup_sessions(id_hash,kind,csrf,expires,created) VALUES(?, 'admin', 'c', '2000-01-01T00:00:00Z', '2000-01-01T00:00:00Z')")
    .bind(crypto.randomUUID()).run();
  const left = async () => (await env.DB.prepare("SELECT COUNT(*) n FROM setup_sessions WHERE expires < '2001'").first<{ n: number }>())!.n;
  it("five_minute_runs_skip_cleanup_and_the_hourly_run_does_it", async () => {
    await expired();
    await runAllUsers(env as any, async () => undefined, [], { hourly: false });
    expect(await left()).toBe(1);
    await runAllUsers(env as any, async () => undefined, [], { hourly: true });
    expect(await left()).toBe(0);
  });
});
