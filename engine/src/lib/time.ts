/** Time zone used when the user's own has not been sent yet. */
export const DEFAULT_TIME_ZONE = "UTC";

/** True for a time zone name the runtime knows (IANA, e.g. "America/New_York"). */
export function isTimeZone(z: unknown): z is string {
  if (typeof z !== "string" || !z.trim()) return false;
  try { new Intl.DateTimeFormat("en-US", { timeZone: z }); return true; } catch { return false; }
}

/** The stored zone when it is usable, else DEFAULT_TIME_ZONE. */
export function zoneOrDefault(z: unknown): string {
  return isTimeZone(z) ? z : DEFAULT_TIME_ZONE;
}

/** Calendar parts of `d` as seen in `zone` (24-hour clock). */
export function zonedParts(d: Date, zone: string): Record<string, string> {
  return Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: zone, weekday: "long", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d).map((x) => [x.type, x.value]));
}
