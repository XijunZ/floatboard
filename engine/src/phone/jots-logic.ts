/**
 * The phone's Jots screen (docs/superpowers/specs/2026-11-17-jots-design.md §5), files/jots.client.js, embedded in `/app/app.js`
 * at the @JOTS_JS@ marker (src/phone/client.ts). Its pure functions are tested on the same text (test/jots/jots-phone.test.ts):
 * - `jotsView(cache, queue, nowMs)`: the engine's copy plus queued captures, edits, deletes and restores; last 30 days, newest first.
 * - `jotsFilter(list, query, tag)`, `jotTags(list)`: search (every word, text or tags) and the tag filter ("untagged" for none).
 * - `jotDayLabel(ms, nowMs, zone)`: Today / Yesterday / "Tue 10 Nov" in the Mac's zone.
 * - `takeJotBatch(queue, sentAt)`, `afterJotSend(queue, result)`, `jotWaitingText(n)`: the offline queue (only malformed actions
 *   leave it without being taken). `markJotsAttempted`, `undoJotDelete`: Undo of a delete whose answer may have been lost queues a
 *   restore instead of dropping the delete.
 * - `launchTarget(search)`, `sharedText(search)`, `selectionTitle(text)`: icon shortcuts, Share into FloatBoard, Make task titles.
 * `JotsScreen(helpers)` draws the screen and keeps its cache and queue (dropped at sign-out with the rest of the account's data).
 */
import JOTS_SRC from "./files/jots.client.js";

export const JOTS_JS: string = JOTS_SRC;

/** Names the tests pull out of JOTS_JS. */
export const JOTS_EXPORTS = ["jotsView", "jotsFilter", "jotTags", "jotDayLabel", "takeJotBatch", "afterJotSend", "jotWaitingText", "launchTarget",
  "sharedText", "selectionTitle", "markJotsAttempted", "undoJotDelete", "JotsScreen"];
