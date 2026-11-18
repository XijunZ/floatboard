/**
 * The phone app's offline queue logic, as plain functions with no access to the page, storage or network. The source is
 * embedded in `/app/app.js` (src/phone/client.ts) and tests run the same text (test/phone/phone-sync.test.ts), so what is tested
 * is exactly what the phone runs.
 *
 * - `viewBoard(board, actions)`: the board as the phone shows it: the last board from the engine plus queued actions not
 *   sent yet (moves change the step, adds show as cards waiting for the Mac).
 * - `takeBatch(actions, sentAt)`: the next request body for `POST /app/api/action`: at most 100 actions and under 60 KB.
 * - `sendBatch(body, send, now)`: sends one batch; when the engine refuses it as malformed (400), sends each action on
 *   its own once and reports the ones still refused (`rejected`) so they can leave the queue instead of blocking it.
 * - `afterSend(actions, sentIds, result)`: drops accepted and dropped ids from the queue.
 * - `noticeSuperseded(sentIds, superseded)`: which of this phone's sent ids the engine reports as not applied.
 * - `retryDelay(failures)`: 5 s doubling to 5 minutes.
 * - `statusText(s)`: the one-line sync status at the top of the board.
 * - `undoFor(card, move, nowMs)`, `undoLive(u, nowMs)`, `undoText(u)`, `undoAction(u, id, nowIso)`: after a move the
 *   phone shows "Moved to Done · Undo" for 8 seconds; Undo queues a new move (its own id, made after the move) back
 *   to the step the card was on. Adds can't be undone.
 * - `deleteUndoFor(card, del, nowMs)`, `undoDeleteStep(u, actions, inFlight, id, nowIso)`: after a delete the phone
 *   shows "Deleted · Undo" for 8 seconds; Undo takes a delete not sent yet out of the queue (nothing is sent), else
 *   queues a `restore` made after it. `viewBoard` hides a card with a queued delete and shows it again after a restore.
 * - `cardLinks(card)`, `linkLabel(link)`: the task sheet's link buttons (every web link the Mac sent, or the older
 *   single `link`).
 * - `emailChoice(card)`, `linkAction(card, hit, id, nowIso)`, `hitLines(hit, nowMs)`: "Link an email" on a task the
 *   user made ("Remove email link" once they linked one; neither on the email sorting's own tasks), the queued action
 *   for a picked search result, and the two lines a result shows.
 * - `dayKey(ms, zone)`, `planBlocks(events, cards, nowMs, zone)`: the planning summary above the board: Today, Rest of
 *   this week (tomorrow to Sunday) and Next week (Monday to Sunday), in the Mac's zone; each with its meetings (a
 *   repeating one once, with its label) and the open tasks due then; Today also has `overdue`, the open tasks due before
 *   today, oldest first (shown at its top in red). Bad entries are skipped.
 *
 * - `visibleViews(modules)`, `moreEntries(modules)`: the bottom bar (Board · Plan · Jots · Circle · More) and More's list,
 *   following which areas the Mac has on (none when it has not said).
 * - `tagChoices(cards)`, `tagsAction(card, group, others, id, nowIso)`: "Tags" on a task: the groups and tags the board
 *   knows, and the queued `set_tags` (group first). `viewBoard` shows a queued one at once.
 *
 * The functions themselves are in files/sync.client.js (bundled as text).
 */
import SYNC_SRC from "./files/sync.client.js";

export const SYNC_JS: string = SYNC_SRC;


/** Names the tests pull out of SYNC_JS. */
export const SYNC_EXPORTS = ["viewBoard", "takeBatch", "sendBatch", "afterSend", "rememberSent", "noticeSuperseded", "retryDelay", "statusText",
  "replacedText", "byteLength", "undoFor", "undoLive", "undoText", "undoAction", "cardLinks", "linkLabel", "emailChoice", "linkAction", "hitLines",
  "dayKey", "planBlocks", "deleteUndoFor", "undoDeleteStep", "markAttempted", "visibleViews", "moreEntries", "tagChoices", "tagsAction", "sessionAccepts"];
