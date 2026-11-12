# Phone app and phone alerts: design and plan

One installable web app (PWA) for Android and iPhone, served by the engine at `<engine>/app`. No app stores, no native
code. Urgent alerts reach phones as push notifications from the engine itself (Web Push), with ntfy as an optional
second channel, so alerts no longer depend on Telegram.

## Goals

- See the board on the phone (To do, Doing, Watch, and Done today) and act on it: move a task to Doing / Watch / Done /
  To do, open its link, add a task.
- Urgent emails notify the phone (lock screen), for each person separately.
- Signing in is phishing-proof and happens once per phone.
- Works on Android (Chrome, installed via "Install app") and iPhone (Safari, "Add to Home Screen", iOS 16.4+).

## Non-goals

- Native apps, app stores, SMS, WhatsApp.
- Editing task details, groups or settings on the phone (the Mac stays the place for that).
- Offline editing on the phone (it shows the last board it loaded; actions need a connection).

## Constraints

- The Mac board (SQLite) stays the record. The engine keeps an encrypted copy of the open board (ENC_KEY, AES-GCM),
  replaced on each push; phone actions are queued on the engine and applied by the Mac.
- No new secrets to set by hand: the engine creates its VAPID key pair on first use and stores the private key encrypted.
- No personal details in code or docs. RP ID and origins come from the request host.
- Alerts carry only the task title, due and a link; never email text. ntfy alerts carry title and due only.
- Tests first (vitest for the engine, FloatBoardChecks for the app). No AI attribution in commits.

## Decisions

1. **Sign-in: passkey + device session.** The Mac's Connectors tab shows "Pair a phone": a QR code of
   `<engine>/app/#pair=<code>` (random 32 bytes, valid 10 minutes, one use, stored hashed). The phone opens it, the user
   taps "Set up this phone", and a passkey is created (WebAuthn, resident key, user verification required, attestation
   "none"). The engine then sets a session cookie `fb_session` (random 32 bytes, stored hashed; HttpOnly, Secure,
   SameSite=Strict, Path=/app, Max-Age 90 days, renewed on use when more than a day old). A phone whose session ended
   signs in again with its passkey (no code). A **device is one browser install**: the app keeps a random install id in
   localStorage and sends it (with a device name) on pair/finish and login/finish. A passkey synced to another browser
   (iCloud Keychain, Google Password Manager) signs that browser in as a new device with its own session and push
   subscription; signing in again on a known install reuses its device; a sign-in for another account on the same
   browser ends the old account's device there. Passkeys belong to the user. The setup page lists every device with
   Remove (ends that device's sessions and push subscription only); a passkey is deleted when the last device using it is
   removed (chosen over a separate per-passkey Remove: one button, and a removed single phone still can't sign back in),
   and the page says which devices share a passkey. Logout ends only the session (the device stays listed).
2. **WebAuthn on the server:** `@simplewebauthn/server` (runs on Workers with WebCrypto). Challenges are stored with a
   5-minute expiry and used once. The browser side is plain `navigator.credentials` calls (no library).
3. **Board mirror:** the Mac `PUT /v2/board` with its open tasks plus tasks done today (id, title, group, group colour,
   importance, due, has_time, status, link), at most 500, after each local change (debounced 10 s) and on every sync.
4. **Phone actions:** `POST /app/api/action` `{card_id, action: todo|doing|watch|done}` or `{action: add, title, group}`.
   Queued in `phone_actions`; the phone sees it through the overlay at once (sync v2: the stored copy is never changed
   by the phone, and a batch shape carries the phone's action ids and times, see below). The Mac polls
   `GET /v2/phone-actions` every 2 minutes (and on each sync), applies them (as the user, so connector "done" events
   still go to the engine) and acks with `POST /v2/phone-actions/ack`. Unknown or deleted card ids are acked and logged.
5. **Web Push:** RFC 8291 (aes128gcm) + RFC 8292 (VAPID, ES256) written with WebCrypto, tested against RFC 8291's
   example vector. Subscriptions per device; one endpoint belongs to one device (saving it deletes other rows with that
   endpoint). Endpoints only at known push services (`fcm.googleapis.com`, `*.push.apple.com`,
   `*.push.services.mozilla.com`, `*.notify.windows.com`), https on the default port; no redirects followed. 404/410
   from the push service deletes the subscription. Payload: `{title, body, url}`, trimmed to fit one 4096-byte record;
   the service worker shows it and opens the app (or the link) on tap. TTL 1 day, Urgency high. Alerts go to devices
   that are still paired; an expired session keeps getting alerts (signing in again is only needed to open the board).
6. **ntfy (optional):** the setup page turns on "Phone alerts with the ntfy app": creates a random 24-character topic,
   shows the subscribe address. Alerts POST to `https://ntfy.sh/<topic>` with Title, Priority 5 for urgent, body = due
   date and "Open FloatBoard for details", Click = `<engine>/app/` (never the email link, sender or reason: ntfy.sh is
   public and anyone with the topic name can read the alerts; the setup page says so).
7. **Alert fan-out:** an urgent item goes to every channel the user has: Web Push devices, ntfy, Telegram (if linked).
   One failing channel never stops the others; failures go to the run log.

## Tasks

### Task 1: ntfy alerts (engine)
Migration `0025_ntfy.sql`: `users.ntfy_topic TEXT`. `src/alerts.ts`: `alertFor(env, userId)` fans out to channels
(moves the Telegram sender behind it); `sendNtfy`. Setup page section with turn on / new topic / turn off and a "Send a
test alert" button. Tests: `ntfy_alert_sends_title_priority_click`, `alert_fanout_one_channel_failing_still_sends_others`,
`ntfy_off_sends_nothing`, `setup_turns_ntfy_on_and_shows_topic_once_per_page`.

### Task 2: Pairing, passkeys and sessions (engine)
Migration `0026_phone_app.sql`: `app_devices`, `app_credentials`, `app_sessions`, `app_pairings`, `app_challenges`.
`src/app/auth.ts`, routes `/v2/app/pair` (user key), `/app/api/pair/options|finish`, `/app/api/login/options|finish`,
`/app/api/logout`, `/app/api/me`. Setup page "Phones" list with Remove. Tests: pairing code single use and 10-minute
expiry; finish with a valid registration creates device + credential + session cookie flags; login with assertion
renews session; revoked device's session refused; session older than 90 days refused; cookie not accepted on /v2;
user key not accepted on /app/api.

### Task 3: Board mirror and phone actions (engine)
Migration `0027_board_mirror.sql`: `board_snapshots`, `phone_actions`. Routes `PUT /v2/board`, `GET /app/api/board`,
`POST /app/api/action`, `GET /v2/phone-actions`, `POST /v2/phone-actions/ack`. Tests: snapshot stored encrypted
(not plain in D1); phone action applied to the stored copy; actions listed oldest first and gone after ack; another
user's session can't read or act; caps (500 cards, 200 pending actions, title 200 chars).

### Task 4: Web Push (engine)
Migration `0028_web_push.sql`: `app_push`, `app_keys`. `src/app/webpush.ts`: VAPID keys on first use; `encrypt` per
RFC 8291; `sendPush`. Routes `GET /app/api/push/key`, `POST|DELETE /app/api/push/subscribe`, `POST /app/api/push/test`.
Alert fan-out includes push. Tests: RFC 8291 example vector; VAPID JWT verifies with the public key; 410 deletes the
subscription; fan-out pushes to every device of that user only.

### Task 5: The phone app (engine-served PWA)
`src/app/page.ts` (HTML/CSS/JS as strings), `manifest.webmanifest`, `sw.js`, icons (SVG + 180/192/512 PNG). Screens:
pair, sign in, board (tabs To do / Doing / Watch / Done today; tap a task for its actions; add), settings (notifications
on/off, test notification, sign out, how to install on Android / iPhone). Light and dark. Tests: routes return the right
content types, CSP header, service worker scope `/app/`, manifest fields.

### Task 6: Mac app
`ConnectorClient`: `pairPhone`, `putBoard`, `phoneActions`, `ackPhoneActions` (404 = engine without the phone app:
skipped quietly). `ConnectorSync`: push the board (only when its hash changed) and apply phone actions. A 2-minute
phone-actions poll and a 10-second debounced push after local changes. Connectors tab: "Pair a phone…" sheet with QR
(CoreImage) and the address. Checks: actions applied once and acked; add creates a To do task in the named group (or the
first); done on a connector card queues the connector event; unknown id acked and logged; board payload has only open
tasks + done today.

### Task 7: Ship
Deploy order: migrations, engine deploy, app install, push to GitHub. README: "Phone app" section (install on Android
and iPhone, pairing, alerts). Smoke test the live `/app` and manifest.

## Evaluation (the bar the phone app is measured against)

1. **Long-lived.** A phone stays signed in with normal use (90-day sliding session; passkey sign-in if it lapses). Push
   keeps working when the browser rotates its subscription (`pushsubscriptionchange` re-subscribes; the app shows
   "Notifications are off" when it has none). Deploys update the installed app without reinstalling. VAPID keys never
   change.
2. **Secure.** Independent review with no open Critical/Important findings. Tests prove one user can never read or act
   on another's board, alerts or devices. Passkeys only (phishing-resistant); a lost phone is removed in one step.
   Alerts carry no email text.
3. **Syncs without clashes.** Every phone action carries the time it was made and the card's `updated` time the phone
   saw. Newest change wins: the Mac skips (and reports) a phone move when the card changed on the Mac after the phone
   action was made. Scenarios with automated checks: phone done then Mac move later (Mac wins); phone done while the Mac
   sleeps (applied on wake unless the Mac changed the card later); action on a card deleted on the Mac (ignored, the
   phone shows it gone); duplicate delivery (applied once); add while the Mac is off (appears once); phone offline
   (last board, read-only, labelled offline); stale phone copy (refresh on open and on focus).
4. **Logical UI on a phone.** Rendered and checked at 360, 390 and 430 px wide, light and dark, long and CJK titles,
   30+ cards per column, tap targets at least 44 px, safe areas respected.
5. **Parity with the Mac, or clearly marked.** On the phone: board by step, move, done, add, open link, edit due /
   importance / group, delete with Undo and teach choices, search, urgent alerts. Mac only (stated in the app's Settings
   and on the task sheet): editing title and notes, reply drafts, Google Calendar and Meet, groups, column sort, bar
   settings, engine settings.

## Security review fixes (Nov 2026)

The review of the engine side (I1-I3, M1-M7) changed: device = browser install (above); one push endpoint per device
and push hosts on an allow list; the phone's cached board is tied to the account marker from `/app/api/me` and shown only
after `/me` confirms it (no cached board at an offline launch); pairing or signing in resets the browser (cache dropped,
old push subscription unsubscribed); at most 20 live sign-in challenges per client address; request bodies capped
before reading; phone moves applied to the latest board copy with a conditional write (a Mac push in the tiny window
between re-read and write wins, and the overlay still shows the move); a pairing code is used up only by a pairing whose
device, passkey and session were all created; push payloads trimmed to fit 4096 bytes; ntfy alerts minimal.

## Sync v2: engine keeps the record, newest change wins (decided)

Scope stays **view + quick actions** on the phone: see the board, alerts, move between To do / Doing / Watch / Done,
add a task. Editing details (title, notes, due, importance, group, delete) is Mac only; the phone's task sheet says
"Edit details on your Mac".

1. **Action log on the engine** (`board_log`, kept 1 year): one row per change from any device: `id` (UUID, unique:
   a repeat is ignored), `user_id`, `device` ("mac" or the phone's device id), `card_id`, `kind`
   (`status` | `add` | `delete`), `value` (new status or title), `made_at` (corrected, see 3), `received_at`.
2. **Newest change wins per card status.** Phone actions carry `made_at`. The Mac's board push carries each card's
   `status_at` (when its step last changed on the Mac). The engine logs Mac changes by comparing each push with the last
   one. The board the phone sees applies an untaken phone action only when it is newer than the card's `status_at`; the
   Mac applies a phone action only when it is newer than its own last step change for that card (else acks it and logs
   "kept the newer Mac change").
3. **Clock correction.** Each batch a device sends includes `sent_at` (its clock at send time). The engine computes
   `skew = received_at - sent_at` and stores `made_at + skew`, so a wrong phone clock or hours offline in a queue still
   orders correctly.
4. **Phone works offline.** It opens on the last board (only the board of the account last confirmed on this phone;
   pairing or signing in as another account clears it), queues actions locally, retries with back-off (5 s doubling to
   5 minutes, plus on reconnect / opening the app), shows "N changes waiting to sync" or "Last synced hh:mm", never
   error pop-ups. Syncs on any connection. Built to cope with unreliable networks (e.g. mainland China without a VPN);
   note: Android push needs Google's push service, which mainland China blocks; iPhone push works there.
5. **Push subscription renewal:** the service worker handles `pushsubscriptionchange` by re-subscribing and saving it;
   the app shows "Notifications are off" when this phone has no working subscription.
6. **Phone layout** checked at 360, 390 and 430 px, light and dark, long and CJK titles, 30+ tasks.

Checks (engine and Mac): duplicate action id applied once; phone action older than the Mac's change loses (both on the
engine's board and when the Mac applies it); newer phone action wins; skew correction (phone clock 2 h fast, action
queued offline 3 h); action on a card deleted on the Mac is dropped and logged; Mac push logs its own changes.

### Sync v2 engine contract (built)

Migration `0029_board_log.sql`: `board_log`; `phone_actions` gains `client_id` (unique per user), `device_id`,
`made_at`, `sent_at`, `outcome`.

- `PUT /v2/board` `{ sent_at?, cards: [{ ...card, status_at? }] }`. A missing `status_at` keeps the previous time when
  the step is unchanged, else the push time. Each push is compared with the last one: step changes, new cards and gone
  cards are logged (device "mac"); the first push is the baseline. Waiting phone moves older than a card's new
  `status_at` are marked taken (the Mac already shows that step) or superseded.
- `POST /app/api/action` `{ sent_at?, actions: [{ id, made_at?, card_id?, action, title?, group? }] }` (1 to 100; body
  at most 64 KB; the older single action still works). Times are corrected by `received_at - sent_at` (ignored past
  7 days) and never later than `received_at`. A repeated id is accepted and not stored again. A move older than the
  card's `status_at` is stored as superseded. Dropped: `invalid`, `unknown card`, `card gone`. A batch that would take
  the waiting queue past 200 is refused whole (429). Ties go to the phone.
- `GET /app/api/board` and the action response: `{ updated, server_time, account, cards (with status_at; pending cards
  carry action_id), pending, superseded }` (+ `accepted`, `dropped` on the action response). `superseded` lists this
  phone's action ids that were not applied (a newer change won or the Mac skipped them; newest 200).
- `GET /v2/phone-actions`: `{ server_time, actions: [{ id, client_id, card_id, action, title, group, created, made_at }] }`.
  `POST /v2/phone-actions/ack` `{ ids?, skipped?: [{ id, reason? }] }`: skipped ones are logged and reported to the phone.
- Hourly: `board_log` rows older than 365 days are deleted.

### Sync v2 phone client (built)

- **Offline first.** The last board is kept in localStorage with the account marker (`floatboard.board`:
  `{ account, board, at }`) and shown at once on open, labelled "Last synced hh:mm" or "Offline". `/app/api/me` then
  confirms the account; if it, or a board answer, names another account, that board and the queue are dropped before
  anything is sent. A 401 goes to Sign in and drops the board; the queue stays and is sent only if the same account signs
  back in. Signing out sends what it can, then drops board and queue.
- **Queue.** Each move or add gets an id (`crypto.randomUUID`) and `made_at` when tapped, goes into `floatboard.queue`
  (`{ account, actions }`) and shows at once ("Not synced yet" on the card). Sent in batches (up to 100, under 60 KB)
  with `sent_at`; accepted, dropped and superseded ids leave the queue. Retries 5 s doubling to 5 minutes, and at once on
  `online`, on coming back to the front, on open and on the refresh button; 429 and other failures keep the queue.
  The board refreshes every 60 s while the app is in front.
- **No error pop-ups.** One status line under the title: "Synced", "Last synced 14:02", "3 changes waiting",
  "Offline, 3 changes waiting". A change the Mac overruled shows for a few seconds as "1 change was replaced by a newer
  change on your Mac" and the task snaps to its real step.
- **Push renewal.** The service worker handles `pushsubscriptionchange` (new subscription, or subscribes again with the
  key from `/app/api/push/key`) and saves it with `POST /app/api/push/subscribe`. At start, a phone that allowed
  notifications but lost its subscription subscribes again quietly; Settings shows "Notifications are off on this
  phone" with Turn on otherwise.
- **Scope.** The task sheet says "Edit details on your Mac"; Settings says in one line what is Mac only.
- Queue logic is pure functions in `src/app/sync-logic.ts`, embedded in `/app/app.js` and tested as is
  (`test/phone-sync.test.ts`). Layout checked in headless Chrome at 360, 390 and 430 px, light and dark, long, CJK and
  unbroken titles, 34 tasks in one tab (titles clamp at 3 lines on the list, full in the sheet).

## Database size: warning and archive to the Mac (built)

- **Size on the setup page** (from D1's `meta.size_after` on `SELECT 1`, else `PRAGMA page_count` * `page_size`): shown
  always ("Database: 1.4 MB of 500 MB"); above 250 MB a warning points to the Mac's archive button (D1 free limit is
  500 MB per database). `GET /v2/status` carries it as `db_size_bytes` (a number, or null when D1 doesn't say). It is the
  whole engine database, all users.
- **Archive old data to this Mac** (Mac app, Connectors tab, per connector and per user): the card shows the engine's
  database size and "Archive old data to this Mac…". The sheet offers a cut-off of 3, 6 (default) or 12 months
  (never less than 92 days back), says in two lines what happens, and shows progress and the result ("Saved 1,234
  entries to engine-email-2026-11-12.jsonl; removed from the engine."), with Show in Finder.

### Archive engine contract (built)

Migration `0030_archive.sql`: `archived_items(user_id, message_id, archived_at)` (tombstones), `board_log.client_id`
(see fixes below), indexes `board_log(user_id, id)` and `items(user_id, id)`.

- **One run** is the first 2,000 rows of this user's archivable rows, in this order: `board_log` rows with
  `received_at` before `before`, by id; then `items` rows with `created` before `before`, by id. `before` must be at least
  30 days ago (400 otherwise). Items are included only when `before` is at least 90 days ago, so items newer than 90 days
  are never archived (they stop the same email making a task twice), and an `action` item whose link is an open task on
  the Mac's board copy is kept (its done event still needs it to mark the email read).
- `GET /v2/archive?before=<ISO>&cursor=<opaque>` (user key): `{ rows: { board_log: [...], items: [...] }, cursor }`,
  pages of up to 500 rows of the run, `cursor` null after the run's last page. A cursor names its cut-off: one from
  another cut-off is refused. Rows never carry `user_id`; an `add` log row's title comes back decrypted.
- **Canonical form and hash.** Each row is an object of text, whole numbers or null (lone surrogates become U+FFFD).
  Its line is `{"row":{...},"table":"board_log"|"items"}` with keys sorted, no spaces, written as JSON.stringify writes
  it (only `"`, `\` and control characters escaped: `\b \f \n \r \t`, else `\u00xx`), ending in `\n`. The run's hash is the
  lowercase hex SHA-256 of all its lines' UTF-8 bytes in run order, which are exactly the bytes the Mac appends to its
  file. A golden row set and hash are shared by the engine test and the Mac check.
- `POST /v2/archive/confirm { before, counts: { board_log, items }, sha256 }`: the engine builds the run again and, only
  when both counts and the hash match, deletes exactly those rows (and writes a tombstone per deleted item's
  `message_id`) in one batch. Anything else is 409 and nothing is deleted. Another user's key builds that user's own
  run, so it can never match or delete someone else's rows.
- **Never a task twice:** before an email is judged, the engine checks `seen` and `archived_items`; the meeting recap
  dedupe checks `archived_items` too.

### Archive on the Mac (built)

`EngineArchive.run` (FloatBoardConnectors): for each run, page `GET /v2/archive` to the end (if any page fails, nothing
is written or deleted); append the run's canonical lines to `archives/engine-<connector>-<yyyy-MM-dd>.jsonl` beside the
`Backups/` folder (owner read/write only; a later archive the same day appends), fsync, read the file back and check it
ends with exactly those bytes; only then confirm with the counts and the SHA-256. Runs repeat until one is empty (at
most 50 rounds per press). On any failure the engine keeps the run's rows, the file is kept, and the sheet says which
(a 409 says the engine's data changed: try again). Progress and the outcome go to the Activity log.

Checks: other user's rows never returned or deleted; count or hash mismatch deletes nothing; items newer than 90 days
never archived; an archived email read again makes no task; the Mac writes the file and only then confirms; a failure
part way (a page, the folder, a mismatch, an old engine) leaves the engine's data intact; the size is shown.

### Fixes that shipped with it

- **Phone: a batch refused with 400 no longer blocks the queue.** It is sent again once as single actions; a single
  action still refused leaves the queue and the status line says "1 change couldn't be sent" for a few seconds.
  Other failures (offline, 429, 5xx) keep the queue as before. Logic in `sendBatch` (`sync-logic.ts`).
- **Engine: a resent phone action id is ignored for as long as its log row is kept.** `board_log.client_id` holds the
  phone's own action id (filled for existing rows by the migration), and dedupe checks it as well as `phone_actions`
  (whose acked rows go after 7 days). After a board log row is archived (30 days at the earliest), its id is no longer
  known.

Deploy order: migration 0030 (`npm run migrate:remote`), then the engine, then the Mac app. An older Mac ignores
`db_size_bytes`; a newer Mac against an older engine shows no size and its archive answers "Update the engine first".
