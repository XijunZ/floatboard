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
- Alerts carry only the task title, due and a link; never email text.
- Tests first (vitest for the engine, FloatBoardChecks for the app). No AI attribution in commits.

## Decisions

1. **Sign-in: passkey + device session.** The Mac's Connectors tab shows "Pair a phone": a QR code of
   `<engine>/app/#pair=<code>` (random 32 bytes, valid 10 minutes, one use, stored hashed). The phone opens it, the user
   taps "Set up this phone", and a passkey is created (WebAuthn, resident key, user verification required, attestation
   "none"). The engine then sets a session cookie `fb_session` (random 32 bytes, stored hashed; HttpOnly, Secure,
   SameSite=Strict, Path=/app, Max-Age 90 days, renewed on use when more than a day old). A phone whose session ended
   signs in again with its passkey (no code). The setup page lists phones with Remove (ends sessions, deletes passkey and
   push subscription).
2. **WebAuthn on the server:** `@simplewebauthn/server` (runs on Workers with WebCrypto). Challenges are stored with a
   5-minute expiry and used once. The browser side is plain `navigator.credentials` calls (no library).
3. **Board mirror:** the Mac `PUT /v2/board` with its open tasks plus tasks done today (id, title, group, group colour,
   importance, due, has_time, status, link), at most 500, after each local change (debounced 10 s) and on every sync.
4. **Phone actions:** `POST /app/api/action` `{card_id, action: todo|doing|watch|done}` or `{action: add, title, group}`.
   Queued in `phone_actions` and also applied to the stored copy so the phone shows it at once. The Mac polls
   `GET /v2/phone-actions` every 2 minutes (and on each sync), applies them (as the user, so connector "done" events
   still go to the engine) and acks with `POST /v2/phone-actions/ack`. Unknown or deleted card ids are acked and logged.
5. **Web Push:** RFC 8291 (aes128gcm) + RFC 8292 (VAPID, ES256) written with WebCrypto, tested against RFC 8291's
   example vector. Subscriptions per device. 404/410 from the push service deletes the subscription. Payload:
   `{title, body, url}`; the service worker shows it and opens the app (or the link) on tap. TTL 1 day, Urgency high.
6. **ntfy (optional):** the setup page turns on "Phone alerts with the ntfy app": creates a random 24-character topic,
   shows the subscribe address. Alerts POST to `https://ntfy.sh/<topic>` with Title, Priority 5 for urgent, Click link.
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
