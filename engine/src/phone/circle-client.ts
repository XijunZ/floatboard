/**
 * The phone's Circle screen (files/circle-logic.client.js: pure functions, tested on their own; files/circle.client.js: the
 * screen, Plan's "Due to contact", the badge and the notification-button fallback). Both go into /app/app.js at the
 * `/*@CIRCLE_JS@*\/` marker, inside the app's scope, so they use its helpers (el, api, openSheet, ...).
 */
import LOGIC from "./files/circle-logic.client.js";
import UI from "./files/circle.client.js";

export const CIRCLE_LOGIC_JS: string = LOGIC;
export const CIRCLE_JS: string = LOGIC + "\n" + UI;
/** Names the tests pull out of CIRCLE_LOGIC_JS. */
export const CIRCLE_EXPORTS = ["circleView", "circleAction", "circleSearch", "circleAgo", "badgeCount", "draftLink", "circleHash"];
