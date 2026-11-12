import { describe, it, expect } from "vitest";
import { cronJobs, DUE_CRON } from "../src/index";

describe("one cron schedule", () => {
  it("quarter_hours_send_reminders_only", () => {
    expect(cronJobs(DUE_CRON, Date.parse("2026-11-12T23:15:00Z"))).toEqual({ due: true, hourly: false });
    expect(cronJobs(DUE_CRON, Date.parse("2026-11-12T23:45:00Z"))).toEqual({ due: true, hourly: false });
  });
  it("on_the_hour_also_does_the_hourly_work", () => {
    expect(cronJobs(DUE_CRON, Date.parse("2026-11-12T23:00:00Z"))).toEqual({ due: true, hourly: true });
    expect(cronJobs(DUE_CRON, Date.parse("2026-11-12T23:00:07Z"))).toEqual({ due: true, hourly: true });
  });
  it("an_old_hourly_schedule_still_does_the_hourly_work", () => {
    expect(cronJobs("0 * * * *", Date.parse("2026-11-12T23:00:00Z"))).toEqual({ due: false, hourly: true });
  });
});
