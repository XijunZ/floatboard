import { describe, it, expect } from "vitest";
import { call, newUser } from "../helpers";
import { SCHEMA } from "../../src/routes/v2";
// The Mac's settings sync (its list of size-limited settings is read from the Swift source).
import SYNC_SWIFT from "../../../mac/Sources/FloatBoardConnectors/Engine/ConnectorSync.swift?raw";

// Integration round 4b: a setting whose oversize makes the engine refuse the WHOLE settings push must be held back by the
// Mac (just that key, with a warning); a setting the engine trims on its own must still be sent. The two lists must match.
const put = (key: string, version: number, values: Record<string, unknown>) =>
  call("/v2/settings", { method: "PUT", key, body: JSON.stringify({ version, values }) });

/** The Mac's `sizeLimitedSettings` dictionary: key -> limit. */
function macLimits(): Record<string, number> {
  const m = /static let sizeLimitedSettings: \[String: Int\] = \[([^\]]*)\]/.exec(SYNC_SWIFT as string);
  if (!m) return {};
  return Object.fromEntries([...m[1].matchAll(/"([a-z_]+)":\s*([\d_]+)/g)].map((x) => [x[1], Number(x[2].replace(/_/g, ""))]));
}

describe("settings sync: size limits agree between the engine and the Mac", () => {
  it("the_mac_holds_back_exactly_the_settings_the_engine_refuses_when_too_long", async () => {
    const u = await newUser("SizeLimits");
    const textKeys = SCHEMA.filter((f) => f.kind === "longtext" || f.kind === "text").map((f) => f.key);
    const refused: Record<string, number> = {};
    let version = 1;
    for (const k of textKeys) {
      // Find the engine's limit by its own count (JavaScript string length): accepted at the limit, refused one above.
      const big = await put(u.key, version++, { [k]: "x".repeat(100_000) });
      if (big.status === 200) continue;   // trimmed or kept by the engine: the Mac sends it as it is
      expect(big.status).toBe(400);
      let lo = 0, hi = 100_000;
      while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if ((await put(u.key, version++, { [k]: "x".repeat(mid) })).status === 200) lo = mid; else hi = mid;
      }
      refused[k] = lo;
    }
    expect(Object.keys(refused).length).toBeGreaterThan(0);
    expect(macLimits()).toEqual(refused);
  });

  it("settings_the_engine_trims_are_still_sent_whole", async () => {
    // my_rules, chat_rules and learned are cut by the engine, never refused: the Mac must not hold them back.
    const limits = macLimits();
    for (const k of ["my_rules", "chat_rules", "learned"]) expect(limits[k]).toBeUndefined();
    const u = await newUser("Trims");
    expect((await put(u.key, 1, { my_rules: "r".repeat(50_000), chat_rules: "c".repeat(50_000), learned: "l".repeat(50_000) })).status).toBe(200);
  });
});
