# Outlook on the web connector: build plan

**Goal:** a Chrome extension reads unread emails from Outlook on the web, and the engine turns the ones that need action
into FloatBoard tasks, judged the same way as Gmail.

**Why an extension:** some organisations do not allow mail API access (Microsoft Graph, EWS or MCP). The extension reads
only what Outlook shows in the user's own signed-in browser tab, like a person would.

**Architecture:** the extension (Manifest V3) parses the visible message list, queues new unread rows in
`chrome.storage.local`, and sends them with an ingest-only token to `POST /ingest/outlook`. The engine stores rows
idempotently and exposes them to the existing triage pipeline as a new `Source` (`kind='outlook_web'`), so tasks reach
the app through the existing `/v2/proposals`. The app needs no changes.

**Tech stack:** Chrome MV3, TypeScript bundled with esbuild, vitest + jsdom for the extension; Cloudflare Worker + D1 +
vitest for the engine.

## Scope

In scope: unread emails in the Inbox (and the Focused tab when present) become tasks through the engine's triage
(shared skill, the user's group notes, own rules, learned preferences, ignore/allow lists, security post-filter).
Corrections and learning work as for Gmail (the stored preview is the excerpt).

Not in scope: Graph / EWS / MCP or any token-based mail API; sending, replying, marking read on done or drafting for
Outlook emails (Draft reply stays Gmail-only); calendar, contacts, Teams; other browsers.

Never: anything that changes what the user sees in Outlook (read state, selection, open message, scroll position);
calling Outlook's internal web services with the user's session; sending email content anywhere except the user's own engine.

## Constraints

- The only connection to Outlook is this extension, reading the page DOM. No calls to Outlook's internal services.
- Never change Outlook: no clicks, no opening messages, no scrolling, no read-state change. The extension never opens a
  sign-in page and never sees or stores passwords or MFA codes; it reads only when a signed-in inbox is on screen.
- Host permissions: `https://outlook.office.com/*`, `https://outlook.office365.com/*`, `https://outlook.live.com/*`.
  The engine address is an `optional_host_permissions` runtime grant made from the options page. Nothing user-specific
  (engine address, names, mailbox) in the manifest or repo.
- Ingest auth: an ingest-only token (not the user key), sent as `Authorization: Bearer <token>`. It can only add Outlook
  rows and report problems for its one source. Stored in `chrome.storage.local`, never synced.
- Nothing lost offline: every row read goes into a queue in `chrome.storage.local` and is removed only after the engine
  acknowledges it. Back-off 30 s doubling to at most 5 minutes (plus a retry on every page read). Caps: 500 queued,
  5,000 acknowledged ids kept for 30 days; hitting a cap is shown on the badge, never silent.
- First run: unread rows received in the last 7 days; after that only new rows. Catch-up covers what Outlook shows
  without scrolling (usually the newest 20 to 50 rows); the setup page states this limit.
- Item identity: row id + received time (ISO UTC). Engine `message_id` = `owa:<rowId>:<receivedISO>`; `sentAt` = receivedISO.
  A new message in an existing thread has a new received time, so it is a new item.
- Received times shown on the page ("10:42", "Mon", "03/11/2026") are read in the browser's time zone.
- Triage text is a preview (what Outlook shows in the list, usually 100 to 250 characters). The classifier is told
  "This is the preview Outlook shows, not the full email."
- Sender: the address when the page exposes it (title, tooltip or attribute), else the display name. Ignore/allow lists
  match either.
- One mailbox per source: the extension reports the signed-in mailbox from the page header on each send; the source
  stores it on the first send. A different mailbox later is refused.
- Silence notice after 2 working days (Mon to Fri) without an ingest while the source is enabled: "Outlook hasn't
  reported for 2 working days: sign in to Outlook in Chrome, or check the FloatBoard extension."
- Signed out: badge "Sign in to Outlook to pick up new email" (neutral grey, not an error).
- Wrong mailbox: badge "This isn't the connected mailbox" + engine attention line; rows not sent.
- No em dashes in user-facing strings.

## Review focus

1. Outlook re-renders the list (virtualised rows, Focused/Other switch): rows read again queue nothing new.
   Test `rereading_same_rows_queues_nothing_new`.
2. Two Outlook tabs open at once: no double sending. Test `two_tabs_share_one_queue` (one queue owned by the service
   worker; content scripts only report rows).
3. Chrome kills the service worker mid-send: the queue survives and the row is sent once. Test
   `send_interrupted_resends_once` (engine idempotent; queue entry removed only on ack).
4. A page that isn't the inbox (settings, calendar, sign-in): nothing queued, badge says why. Test `non_inbox_pages_read_nothing`.
5. A leaked token can't read anything from the engine. Test `ingest_token_cannot_read_proposals_or_status`.

---

### Task 1: Extension skeleton, page parser and sample capture

**Files:** `connectors/outlook-web/` with `manifest.json`, `package.json` (esbuild, vitest, jsdom, typescript),
`tsconfig.json`, `build.mjs` (bundles to `dist/`, copies the manifest and options page), `src/selectors.ts`,
`src/parse.ts`, `src/scrub.ts`, `src/content.ts`, `test/parse.test.ts`, `test/scrub.test.ts`,
`test/samples/guess-inbox.html` (a hand-made sample of a typical Outlook message list), `README.md` (load unpacked from
`dist/`, capture samples).

**Interfaces:**
- `type Row = { rowId: string; fromName: string; fromAddr?: string; subject: string; preview: string; received: string /* ISO UTC */; unread: boolean }`
- `type PageRead = { kind: "inbox"; mailbox?: string; rows: Row[] } | { kind: "signedOut" } | { kind: "notInbox" } | { kind: "unrecognised"; reason: string }`
- `readPage(doc: Document, now: Date): PageRead`
- `scrubSample(doc: Document): string`: the HTML with every text node, every attribute value that looks like a name,
  address or id, and every title replaced by placeholders; structure and class names kept.

- [ ] Failing tests: `parses_unread_rows_from_sample` (sample with N unread and M read rows: only unread returned, all
  fields filled), `received_time_parsed_to_iso` (today "10:42", weekday "Mon", date "03/11/2026"; in a fixed test zone),
  `rereading_same_rows_queues_nothing_new` (helper `newRows(rows, sentIds)`), `non_inbox_pages_read_nothing`,
  `signed_out_page_detected`, `scrub_removes_all_personal_text` (no original text node or email-like attribute survives;
  element count unchanged).
- [ ] Implement with all selectors in `selectors.ts`, so a page change is a one-file fix. The content script reads on
  load, on debounced (30 s) mutations, and when asked by the service worker; it only posts `PageRead` to the service worker.
- [ ] Options page has **Save page sample**: runs `scrubSample` on the active Outlook tab and downloads
  `outlook-sample-<date>.html`.
- [ ] `cd connectors/outlook-web && npm install && npx vitest run && npx tsc --noEmit && node build.mjs`: green, `dist/manifest.json` exists.

### Task 2: Queue, sender, badge and options

**Files:** `src/background.ts` (service worker), `src/queue.ts`, `src/options.html`, `src/options.ts`, `test/queue.test.ts`.

**Interfaces:** `Queue` over a storage adapter (`get`/`set` of `chrome.storage.local`, faked in tests):
`add(rows: Row[], now): number` (skips acknowledged ids, and rows older than 7 days on the first run), `takeBatch(max = 50)`,
`ack(ids)`, `fail(now)` (back-off), `status(): { waiting: number; lastOk?: string; problem?: string }`.
Badge: green dot when idle and fine, a number when rows are waiting, grey "!" when signed out, red "!" for problems with
the reason in the tooltip ("Outlook page not recognised", "Engine unreachable", "Key rejected").

- [ ] Failing tests: `first_run_takes_last_7_days_only`, `ack_removes_and_remembers`, `backoff_doubles_to_5_minutes`,
  `two_tabs_share_one_queue`, `send_interrupted_resends_once`, `caps_are_reported_not_silent`, `wrong_mailbox_rows_not_sent`.
- [ ] Options page: engine address (requests the optional host permission for exactly that origin), ingest token
  (password field), **Test connection** (sends an empty batch; shows OK / key rejected / unreachable), Save page sample.
- [ ] Sender: `POST <engine>/ingest/outlook` with `{ mailbox, items: Row[] }` and the Bearer token; a `{ problem }` body
  reports page or mailbox problems. `chrome.alarms` every 5 minutes asks the Outlook tab to read and flushes the queue.
- [ ] Tests + build green.

### Task 3: Engine ingest

**Files:** `connectors/email/migrations/<next>_outlook.sql`, `connectors/email/src/outlook.ts`,
`connectors/email/src/index.ts` (route `POST /ingest/outlook`), `connectors/email/src/routes/setup.ts` +
`src/setup/page.ts` (section "Outlook (Chrome extension)": create the source, show or rotate the token, how to load the
extension, the 20 to 50 visible rows limit), `connectors/email/test/outlook-ingest.test.ts`.

**Interfaces:** table `outlook_rows(user_id, source_id, row_key TEXT /* owa:<rowId>:<receivedISO> */, from_name, from_addr,
subject, preview, received, processed INTEGER DEFAULT 0, created, PRIMARY KEY(user_id, row_key))`, pruned 30 days after
processing. `sources` row with `kind='outlook_web'`, `address` = mailbox (empty until the first ingest), `hook_id` =
SHA-256 of the token (the token is shown once at creation or rotation and stored only hashed), `last_run` = last ingest.

- [ ] Failing tests: `ingest_is_idempotent`, `ingest_requires_token_and_only_writes_its_source`,
  `ingest_token_cannot_read_proposals_or_status`, `first_ingest_sets_mailbox_then_other_mailboxes_refused` (refusal
  recorded as `last_error`, shown in needs_attention as "This isn't the connected Outlook mailbox"),
  `problem_reports_show_in_needs_attention`, `empty_batch_is_a_connection_test`, `setup_creates_source_and_shows_token_once`,
  `rows_pruned_30_days_after_processing`.
- [ ] `cd connectors/email && npx vitest run && npx tsc --noEmit -p .` green. Update `docs/data-model.md` with the new table.

### Task 4: Engine triage of Outlook rows

**Files:** `connectors/email/src/sources/outlook.ts` (`OutlookSource implements Source`), `connectors/email/src/run.ts`
(source query includes `outlook_web`; the factory picks Gmail or Outlook), `connectors/email/src/classify.ts` (preview
note), `connectors/email/src/routes/v2.ts` (silence notice in status), `connectors/email/test/outlook-triage.test.ts`.

**Interfaces:** `OutlookSource.fetchBatch` returns unprocessed `outlook_rows` as `Message` (`messageId` = row_key,
`sentAt` = received, `text` = preview, `labels` = `["UNREAD"]`, `link` = `https://outlook.office.com/mail/inbox/id/<rowId>`
when the row id looks like an Outlook item id, else `https://outlook.office.com/mail/search?q=<subject>`), and marks rows
processed after the run stores the decision. Mark-read-on-done is a no-op for Outlook items (their done events finish
without a mail call). Rows are processed right after ingest via `ctx.waitUntil` (at most 5), with the scheduled run as
the second layer.

- [ ] Failing tests: `outlook_rows_become_tasks_through_triage` (stub Claude says action: `/v2/proposals` has a task with
  source_key `owa:...` and the link), `classifier_told_text_is_a_preview`, `done_on_outlook_task_makes_no_mail_call`,
  `silence_after_two_working_days_only` (last ingest Fri 17:00: no notice Mon 16:00, notice Tue 17:01),
  `gmail_triage_unchanged` (existing suite green), `outlook_rows_never_drafted` (Draft reply refuses Outlook items with
  "Draft reply works for Gmail emails only for now"; the app shows the error).
- [ ] Full suite + tsc + shared fixture `cmp` green.

### Task 5: Verify against a real Outlook page

- [ ] Apply the migration and deploy the engine. On the setup page create the Outlook source and copy its token.
- [ ] Build `dist/` (`npm install && node build.mjs` in `connectors/outlook-web`), then Chrome > Extensions > Developer
  mode > Load unpacked > `dist/`. Paste the engine address and token in the options page; Test connection.
- [ ] Sign in to Outlook, use **Save page sample**, add the scrubbed sample under `test/samples/`, adjust `selectors.ts`
  until `parses_unread_rows_from_sample` passes on it, rebuild and reload the extension.
- [ ] Confirm: unread emails needing action appear as tasks on the board; nothing in Outlook changed state; going
  offline queues rows and sends them later.

## Open risks

- Outlook's page structure changes without notice; the parser is the part most likely to break. The badge and the
  attention line make that visible the same day; the sample tests make the fix quick.
- Preview-only judging misses detail that lives deeper in an email.
