/**
 * The phone's More › Resolutions screen logic (docs/superpowers/specs/2026-11-17-resolutions-design.md §6), as plain
 * functions embedded in `/app/app.js` at the `@RESOLUTIONS_JS@` marker and tested on their own
 * (test/phone/resolutions.test.ts):
 * - `goalsView(goals, cards)`: the quarter's title and each goal (id, title, "under R-1 · …", counts, open task titles).
 * - `goalsSub(goals)`: the More row's second line ("Q4 2026 · 2 goals").
 * - `goalCounts(goal)`: "2 done · 3 open", or "Nothing linked yet" (no percentages).
 */
import RESOLUTIONS_SRC from "./files/resolutions.client.js";

export const RESOLUTIONS_JS: string = RESOLUTIONS_SRC;
export const RESOLUTIONS_EXPORTS = ["goalsView", "goalsSub", "goalCounts"];
