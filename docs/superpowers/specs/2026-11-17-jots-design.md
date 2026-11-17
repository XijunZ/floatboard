# Jots: design (J1–J14, §9 Jots rules, phone Jots screen, share target, icon shortcuts)

Date: 17 Nov 2026 · Branch `jots` (from `assistant` f79f463) · Mac schema **13** · engine migration **0040**

Requirements: `2026-11-17-assistant-features.md` §2 (J1–J14), §6 (links), §7 (AI jobs), §9 (Jots rules), §10 (phone).
Shared base: `2026-11-17-foundation-design.md` (used as is; the one extension is listed in §8 below).

## 1. Data

### Mac, schema 13 (`DB.upgrade` block `if version < 13`, also run on a new board after the v12 tables)

```sql
ALTER TABLE jots ADD COLUMN task_id INTEGER;                  -- a task note: its task (kept when the task is deleted)
ALTER TABLE jots ADD COLUMN origin TEXT NOT NULL DEFAULT '';   -- the engine key it arrived with ('phone:<uuid>', 'fathom:<key>'); '' typed here
CREATE INDEX jots_task ON jots(task_id);
CREATE UNIQUE INDEX jots_origin ON jots(origin) WHERE origin<>'';
-- Meeting notes: what Fathom said about the meeting, and how the notes were attached to their calendar event.
CREATE TABLE jot_meetings(
    jot_id INTEGER PRIMARY KEY, recap_key TEXT NOT NULL, fathom_url TEXT NOT NULL DEFAULT '', meeting_url TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '', scheduled_start REAL, invitees TEXT NOT NULL DEFAULT '[]',
    matched_by TEXT NOT NULL DEFAULT '', tries INTEGER NOT NULL DEFAULT 0   -- link | time | suggested | '' (not yet)
);
-- Claude's tag suggestions per jot (open / accepted / dismissed).
CREATE TABLE jot_suggestions(jot_id INTEGER NOT NULL, tag TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open', at REAL NOT NULL,
    PRIMARY KEY(jot_id, tag));
-- What the engine holds of each jot: the `updated` it last accepted, and whether Claude was asked for tags.
CREATE TABLE jot_sync(jot_id INTEGER PRIMARY KEY, pushed REAL, tags_asked INTEGER NOT NULL DEFAULT 0);
```
Settings in `meta`: `jot_nudge` (JSON `{on, minutes}`; default on, 21:00 app zone), `jot_nudged_day` (last day the Mac
showed it), `jot_daily_files` (JSON `{on, folder}`; default on, `~/Code/Resources/braindumps/daily`), `jot_files_at` (last
rewrite pass), `jots_pull_at`.

No backfill (builder's call): existing task notes become task-note jots the next time they are edited, so the Jots tab
is not flooded with years of old notes on day one.

### Engine, migration 0040

```sql
CREATE TABLE jot_copies (           -- the 30-day online copy (J13) and captures waiting for the Mac
  user_id TEXT NOT NULL, key TEXT NOT NULL,      -- 'J-<n>' (Mac), 'phone:<uuid>' (phone capture), 'fathom:<…>' (meeting notes)
  mac_id INTEGER,                                -- the Mac's J-n once it has the jot
  text_enc TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'jot', source TEXT NOT NULL DEFAULT 'typed', tags TEXT NOT NULL DEFAULT '[]',
  added TEXT NOT NULL, updated TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  mac_saved_at TEXT,                             -- engine time the Mac last saved this jot's latest version (NULL: never)
  waiting INTEGER NOT NULL DEFAULT 0,            -- 1: a capture, edit, delete or meeting notes the Mac has not saved
  rev INTEGER NOT NULL DEFAULT 0, recap_key TEXT,
  PRIMARY KEY (user_id, key));
CREATE UNIQUE INDEX jot_copies_mac ON jot_copies(user_id, mac_id) WHERE mac_id IS NOT NULL;
CREATE TABLE jot_actions_seen (user_id TEXT NOT NULL, id TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (user_id, id));
CREATE TABLE jot_nudges (user_id TEXT PRIMARY KEY, minutes INTEGER, zone TEXT NOT NULL DEFAULT 'Europe/London',
  shown_day TEXT, jotted_day TEXT, done_today TEXT NOT NULL DEFAULT '[]', updated TEXT NOT NULL);
```
Text is encrypted like the board copy (`lib/crypto`). Prune (hourly): `waiting=0 AND mac_saved_at < now − 30 days`. A row
the Mac has not saved (`waiting=1` or `mac_saved_at IS NULL`) is never removed (§9).

## 2. Features

**J1 Capture window.** `Jots/CaptureWindow.swift`: one small floating `NSPanel` (420×190, rounded, no title bar) opened
by ⌃⌥J (`HotKeys` id 3) or ✎ on the bar (`BannerViews`, shown while Jots is on). An NSTextView (plain text) plus one
quiet line: "⌘↩ save · Esc close". ⌘↩ saves through `JotStore.create` (source typed) and closes; Esc closes and keeps
the draft (`meta`-free: `UserDefaults` key `jotDraft`, restored next time). With a linked task (J8) the line shows
"About T-12 · <title>" and the saved jot gets that task's tags and a `related` manual link.

**J2 Voice.** Nothing custom: the capture window is a normal text view, so macOS dictation (fn fn / Edit › Start
Dictation) works; the phone's writing box is a `<textarea>`, so the keyboard microphone works. The hint line says so once.

**J3 Phone.** See §5.

**J4 Jots tab.** `Jots/JotsTab.swift` replaces the placeholder: left a list (search field, kind and tag filter menus,
sort menu: Added / Updated / Tag), right the selected jot. Newest first, grouped by day ("Today", "Yesterday",
"Mon 10 Nov"); **today's meetings** (calendar, today, not all-day) sit at the top of Today, each showing its meeting
notes jot when there is one, else "No notes yet". Untagged jots show "untagged". Query by code
(`JotQuery` in core): every search word in the text (case and accents ignored) or a typed `J-n`; tag filter = any.

**J5 Tags.** A jot's tags live in `item_tags` (foundation). Editing: the detail pane's tag row (menu of all tags; the first
chosen is primary). After a save, the Mac batches new untagged jots (≤ 20, oldest first, once each: `jot_sync.tags_asked`)
to the engine job `jot_tags` (Haiku): only existing tag names come back (code filter); each becomes a ✓/✗ chip. ✓ adds the
tag (primary if none); ✗ dismisses it. Not suggested again for that jot.

**J6 Claude cleanup.** Button "Clean up" in the detail pane → engine job `jot_cleanup` (Haiku: grammar and structure only,
keep every fact, name, number, id and link, same language). A sheet shows **before and after side by side**; "Use cleaned"
saves it as an edit (the original goes to the jot's history), "Keep mine" closes. A code check (`CleanupGuard.missing`)
lists ids, links, numbers and @/# words of the original that the cleaned text lacks, shown in red above the buttons.

**J7 Make task / Make decision.** The jot editor and every jot text use the foundation's `SelectableTextEditor` /
`SelectableText` with the jot as source, so right-click shows Make task (foundation form), Make decision (registered by
Decisions; hidden while it is off) and Copy id link. The form fills the **due date when the selection mentions one**
(code: `MakeTask.dueMentioned`, NSDataDetector, app zone) and, when an engine is connected and Jots is on, asks the engine
job `fill_form` (Haiku) for a shorter title and the due date; Claude's values replace the code's only while the owner has
not typed in those fields, and the form says "Filled in by Claude". The tags come from the jot (foundation).

**J8 "Jot about this".** A button in the task editor opens the capture window linked to the task (above).

**J9 Meeting notes.** Engine: the Fathom webhook and the hourly catch-up, after `recordMeeting`, store the meeting's full
Fathom text (summary, action items, link) as a `jot_copies` row `fathom:<recap key>`, kind meeting_notes, source meeting,
`waiting=1` (once per meeting; skipped while Jots is off). The Mac takes it in (§4) and attaches it by **code**
(`MeetingMatch.find`):
1. a meeting link is present: the event in the window ±1 day of the scheduled start (or of receipt) whose video link is
   the same call (scheme, `www.`, query, fragment and trailing `/` ignored; Meet codes compared case-blind) →
   `notes-of` **auto**;
2. else a scheduled start: events starting within 10 minutes of it that share at least one invitee address with the
   event's guests → exactly one: `notes-of` **auto**; several, or start-only matches → the closest as a `notes-of`
   **suggested** link (Confirm / ✕ in the jot pane);
3. nothing: no link; tried again on the next passes for 2 days (the event may sync later), then left for the owner
   (type `E-n` in the jot).
Tags: the tags of the tasks linked to that event (related links, plus the task whose own event it is), else Claude's
suggestions (J5). Tasks linked to that event show the notes read-only in their editor ("Meeting notes" section, selectable).
Fathom's suggested tasks keep coming only from the existing recap path; nothing in Jots suggests tasks from them.

**J10 Task notes are jots.** `Store.update` (task editor) calls `saveTaskNotesRow` in the same transaction: no note jot
and notes ≥ 10 characters → a task_note jot (`task_id`, the task's tags, `notes-of` auto link jot→task); a note jot →
`JotStore`-style update (history). Editing the note jot in the Jots tab writes `cards.notes` too (one record, one
history). Deleting the task keeps the jot ("task deleted" in its pane); deleting the note jot empties `cards.notes`; Undo
restores either. The task editor's Notes field becomes `SelectableTextEditor` (source = the note jot when there is one,
else the task) so right-click works there too. Tasks made by "Make task" keep the selection as notes without a new jot
(it is a quote of its source, already linked; builder's call).

**J11 Daily nudge.** `JotNudge` (core): on/off and time (Settings › Areas › Jots). Once a minute (`JotsTicker`): at or after
the time, not shown today, and no jot of source typed or phone added today (app zone) → a Mac notification "Anything to
jot today?" with the day's finished tasks ("Done today: A, B, C") → `jot_nudged_day`. The engine gets
`{minutes, zone, shown_day, jotted_day, done_today}` with each jots push and sends one Web Push at time + 10 minutes when
the Mac has not shown it, nobody jotted today (Mac's jotted day and the phone captures in `jot_copies`), claimed once in
`due_alerts_sent` (`jotnudge:<day>`). Builder's call: shown once across Mac and phone, like the budget reminders.

**J12 Daily files.** `DailyFiles` (core, pure render + atomic write): `<folder>/YYYY-MM-DD.md` per app-zone day of `added`,
all kinds, oldest first: `## 09:12 · J-14 · Meeting notes · Work, Investor` then the text. After any jot change
(debounced 5 s, and at launch) the days of jots changed since the last pass are rewritten whole (temp file + replace);
a day with no jots left loses its file only if FloatBoard wrote it (first line marker). Folder and on/off in Settings.

**J13 Online copy.** §4. **J14 Edit/delete.** Editing saves on pause (1 s) and when leaving the jot; every save keeps the
previous text in history. "History" lists versions with "Restore" (restoring is an edit, so it can be undone the same
way). Delete shows "Deleted J-14 · Undo" (8 s).

## 3. AI jobs (engine, Haiku, `lib/llm.ts`: added to `Job`, `DEFAULT_MODEL` haiku, `COLUMN` null)

| Job | Route | Input | Output | Notes |
|---|---|---|---|---|
| `jot_tags` | `POST /v2/jots/tags` | ≤ 20 `{id, text ≤ 4000}` + tag names | `{suggestions:[{id, tags}]}` | one call per batch; unknown names dropped |
| `jot_cleanup` | `POST /v2/jots/cleanup` (Mac), `POST /app/api/jots/cleanup` (phone) | one text ≤ 20 000 | `{cleaned}` | before/after confirm |
| `fill_form` | `POST /v2/jots/fill` | selection ≤ 4000, jot text ≤ 4000, today, zone | `{title, due, has_time}` | owner edits the form |
Each checks `settings.modules.jots` (409 `jots_off`) and the Claude key (409 `no_claude_key`); usage metered as today.
No new judgement calls: these are the three §7 rows marked low. Matching meeting notes, nudge, files, buffer: code.

## 4. Sync (Mac ⇄ engine ⇄ phone)

- `PUT /v2/jots` (Mac, user key): `{jots:[{id, text, kind, source, tags, added, updated, deleted}], nudge?}`. Sent: jots
  added in the last 30 days whose `updated` is newer than `jot_sync.pushed` (≤ 200 per call). Engine upserts by `mac_id`
  (a phone capture's row keeps its key); a row with a newer phone change waiting keeps the phone's text (newest wins).
  Sets `mac_saved_at`. Answers `{accepted:[id]}`; the Mac stores `pushed`.
- `GET /v2/jots/waiting` (Mac): rows with `waiting=1` (≤ 100) with text, `rev`, and for meeting notes the Fathom metadata
  from `meetings`. The Mac applies: a new key → `JotStore.create` with `origin`=key (unique: a repeat never makes two);
  an edit/delete/restore of a known jot → applied only when its time is newer than the jot's `updated`, else skipped
  (the Mac's next push overwrites the copy). Then `POST /v2/jots/ack {items:[{key, rev, mac_id}]}` clears `waiting` only
  for the same `rev` (a newer phone change stays waiting).
- Phone: `GET /app/api/jots` (session): jots added in the last 30 days, not deleted, newest first; `POST /app/api/jots`
  `{sent_at, actions:[{id, op: add|edit|delete|make_task|make_decision, key?, text?, title?, made_at}]}`: times corrected
  by `received − sent_at`; each id applied once (`jot_actions_seen`). `make_task` / `make_decision` are kept as waiting
  rows of kind `action:*`: the Mac makes the task (`Store.makeTask`, source link to the jot) or hands the text to the
  Decisions hook (`JotActions.makeDecision`, registered by Decisions; while none is registered the action waits).
- Runs in `ConnectorRunner.phoneTick` (every 2 minutes and 10 s after local changes) for engines with the phone app.

## 5. Phone

`engine/src/phone/files/jots.client.js` (logic + screen, bundled at `/*@JOTS_JS@*/`; pure functions tested in vitest like
`sync.client.js`): the **Jots** screen: writing box on top (Save; Clean up when online), then the last 30 days
(newest first, day headers), a search box and a tag filter. Offline captures go to their own queue
(`floatboard.jotqueue`) and are sent with the next sync ("2 jots waiting"); the list is cached (`floatboard.jots`), both
dropped at sign-out with the rest of the account's data. Tapping a jot opens a sheet: text (selectable), Edit, Clean up
(before/after, Use cleaned / Keep mine), Delete (Undo), and **Make task / Make decision** acting on the text selected in
it (whole text when nothing is selected; Make decision only while Decisions is on).
**Android:** manifest `shortcuts` "New jot" (`/app/?go=jot`, opens on the writing box) and "Plan" (`/app/?go=plan`);
`share_target` (GET `/app/?share=1&title&text&url`): the app opens a sheet "Save as jot" / "Save as task".

## 6. Files

Core `mac/Sources/FloatBoardCore/Jots/`: `JotsCore.swift` (query, tags, origin, history restore), `TaskNotes.swift`,
`MeetingMatch.swift`, `JotSuggestions.swift`, `CleanupGuard.swift`, `DailyFiles.swift`, `JotNudge.swift`,
`JotsSyncCore.swift` (payloads and applying engine rows; no network), `JotsRegistry.swift` (search). Connectors:
`FloatBoardConnectors/Jots/JotsClient.swift`, `JotsSync.swift`. App `mac/Sources/FloatBoard/Jots/`: `JotsTab.swift`,
`JotDetail.swift`, `CaptureWindow.swift`, `JotsTicker.swift`, `JotsSettings.swift`, `TaskMeetingNotes.swift`.
Checks `FloatBoardChecks/JotsChecks.swift`. Engine `src/jots/{copies,app,ai,nudge}.ts`, `src/phone/jots-logic.ts`,
`src/phone/files/jots.client.js`, `test/jots/*.test.ts`.

## 7. Left out (and why)

Rich text, attachments, prompts on ticked tasks, task suggestions from ordinary jots (not in v1). Meeting notes from the
recap **email** path (it has no meeting metadata to attach by; the webhook and catch-up carry it). Phone editing of
tags on jots (Mac only, like other setup). Old task notes are not back-filled (see §1).

## 8. Foundation extensions (separate commits titled "Foundation: …")

- `MakeTask.dueMentioned(in:now:)` and the Make task form's due date and Claude fill (J7).
- `JotActions.makeDecision` hook in core (phone "Make decision" → the Decisions area; nil until Decisions registers it).
