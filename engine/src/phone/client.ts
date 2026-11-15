/**
 * The phone app's script, served as `/app/app.js` (same origin, so the page's CSP needs no inline script).
 *
 * Plain JavaScript, no framework. Data from the engine is only ever written with textContent / attributes, never parsed
 * as HTML. Screens: pair (from `#pair=<code>`), sign in (passkey), board, settings. WebAuthn uses `navigator.credentials`
 * directly with base64url <-> bytes done here.
 *
 * - Each browser install keeps a random install id in localStorage and sends it, with a device name, when pairing and
 *   signing in, so the engine knows it as one device (see app/auth.ts).
 * - Works offline (sync v2). The last board is kept with the account marker of the account last confirmed on this phone
 *   and shown at once, labelled "Last synced hh:mm" or "Offline". When `/app/api/me` or the board answers with another
 *   account, that board and the queue are dropped before anything else happens. A 401 goes to Sign in; the queue is kept
 *   and sent only if the same account signs back in.
 * - Moves and adds go into a queue in localStorage, each with its own id and the time it was made, and show at once.
 *   The queue is sent in batches (`POST /app/api/action` with `sent_at`), retried 5 s doubling to 5 minutes and at once
 *   when the phone comes online, the app is opened or comes back to the front. No error pop-ups: a one-line status at the
 *   top says "Synced", "Last synced 14:02", "3 changes waiting" or "Offline, 3 changes waiting".
 * - After pairing or signing in, the browser is reset: cached board dropped and any old push subscription unsubscribed,
 *   so a browser that changes hands never shows or receives the previous account's data.
 * - After a move, a bar says "Moved to Done · Undo" for 8 seconds; Undo queues a new move back (its own id and time).
 * - The task sheet has a button per link the Mac sent ("Join meeting", "Open email", "Open calendar", "Open link"),
 *   each opening in a new tab or app.
 * - "Link an email" on a task the user made opens a search of their Gmail (subject, sender and day only); picking a
 *   result queues a link_email action for the Mac. "Remove email link" queues unlink_email.
 * - The queue logic is in src/phone/sync-logic.ts (pure functions, tested on their own).
 *
 * The script itself is files/app.client.js (bundled as text); the queue logic (files/sync.client.js) goes in at
 * the @SYNC_JS@ marker.
 */
import { SYNC_JS } from "./sync-logic";
import APP_SRC from "./files/app.client.js";

export const APP_JS: string = APP_SRC.replace("/*@SYNC_JS@*/", () => SYNC_JS);
