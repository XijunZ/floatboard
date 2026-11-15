import { describe, it, expect } from "vitest";
import { env } from "cloudflare:test";

// docs/data-model.md must name every engine table (as `name`) that the migrations leave in place, so the documented
// data model can never fall behind the schema. The app has the same check for its board tables (FloatBoardChecks).
describe("data model doc", () => {
  it("names every table the migrations create and do not drop", () => {
    const live = new Set<string>();
    for (const m of env.TEST_MIGRATIONS) {
      for (const q of m.queries) {
        const sql = q.replace(/--[^\n]*/g, "");
        for (const c of sql.matchAll(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`"[]?(\w+)/gi)) live.add(c[1]);
        for (const d of sql.matchAll(/DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?[`"[]?(\w+)/gi)) live.delete(d[1]);
      }
    }
    expect(live.size).toBeGreaterThan(10);
    expect(live.has("meeting_tasks")).toBe(false);
    const missing = [...live].filter((t) => !env.DATA_MODEL_DOC.includes("`" + t + "`"));
    expect(missing).toEqual([]);
  });
});
