/**
 * More › Decisions on the phone (docs/superpowers/specs/2026-11-17-decisions-design.md §8): its own script files, put into
 * `/app/app.js` at the `@DECISIONS_LOGIC@` and `@DECISIONS_UI@` markers (src/phone/client.ts). The pure parts
 * (files/decisions-logic.client.js) are tested on their own (test/decisions/phone-decisions.test.ts):
 *
 * - `decisionSections(list, queue)`: Reviews due, This week, Maybe, Earlier, with queued actions shown at once.
 * - `canDismiss(d)`: "Not a decision" on this week's and Maybe decisions.
 * - `reviewAction(d, happened, sound, id, nowIso)`, `notDecisionAction(d, id, nowIso)`: the queued actions (own id and time).
 * - `decisionQueueSendable(queue, confirmed)`: send only for the confirmed account the queue was made under.
 * - `decisionQueueAfter(queue, accepted)`, `decisionDetail(d)`, `decisionPrediction(d)`, `decisionsWaiting(n)`.
 */
import LOGIC from "./files/decisions-logic.client.js";
import UI from "./files/decisions.client.js";

export const DECISIONS_LOGIC_JS: string = LOGIC;
export const DECISIONS_UI_JS: string = UI;
export const DECISIONS_EXPORTS = ["decisionSections", "canDismiss", "reviewAction", "notDecisionAction", "decisionQueueAfter", "decisionDetail",
  "decisionPrediction", "decisionsWaiting", "decisionQueueSendable", "decisionSendBody"];
