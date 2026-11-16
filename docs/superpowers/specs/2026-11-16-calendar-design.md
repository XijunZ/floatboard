# Calendar: design

Date: 16 Nov 2026 · Status: for review (updated after builder check) · Part 1 of 4 (Calendar → Jots → People → Decisions)

## Why

The board is where the user works. Meetings live in Google Calendar, and today FloatBoard can only *create* an event
from a task; it never shows the calendar. The user wants to see their day inside FloatBoard (meetings and every task
due that day) and act on it there, with every change landing in Google, so they rarely need to open Google Calendar.

## Goals

- A **Calendar** tab with a **day** and a **week** view that mirrors every calendar of every connected Google account.
- Create, move, resize, rename and delete events from FloatBoard; changes go to Google straight away.
- Changes made in Google appear in FloatBoard within about a minute while the app is open.
- Every task with a due date shows on its day: timed tasks at their time, date-only tasks in a strip at the top.
- A task put on the calendar and its Google event stay in step both ways (title and time).
- Every task, event (and later every jot, person and decision) has a short visible id, such as `T-142` or `E-37`,
  so the user can refer to it anywhere.
- Times are shown in one chosen time zone (Settings), so travelling never shifts tasks around.
- The bar shows the next meeting today, with **Join** when it has a video link.
- The phone app gets a read-only **Today** list: today's meetings and tasks due today.

## Non-goals

- Embedding Google Calendar itself. Google blocks its sign-in inside other apps, and its embed is read-only, single
  calendar and needs public sharing. FloatBoard draws its own simple calendar instead.
- Month view, invitations (accept/decline), guests, rooms, editing recurrence rules, reminders/notifications
  (Google already sends them). Every event has **Open in Google Calendar** for these.
- A work Google account: later. It may be blocked by the employer's Google Workspace admin; check then.
- Outlook calendars.
- Turning calendar events into tasks (events stay events; tasks stay tasks).

## Anti-goals

- A calendar change that silently deletes a task, or a task change that deletes an event the user made in Google.
- Clutter in Google: no task goes to Google unless the user puts it there.
- A second "truth" for events: Google is the truth for events; FloatBoard keeps only a cache it can rebuild.
- Breaking FloatBoard's offline promise: the board works with no network; the calendar shows the last copy and
  queues changes.

## Constraints (from the existing app)

- `board.sqlite` stays the truth for tasks; no AI involved anywhere in this feature.
- Google sign-in already exists (one Desktop OAuth client, accounts in Settings › Connections › Outputs ›
  Calendar, tokens in the private credentials file). Scope today is `calendar.events` + `openid email`.
- Listing an account's calendars (`calendarList`) needs one more scope,
  `https://www.googleapis.com/auth/calendar.calendarlist.readonly`, so each connected account reconnects once.
  The app asks for it with a clear "Reconnect to show your calendars" button; nothing else breaks before that.
- No silent failures (every error to Activity; the watchdog treats a calendar that hasn't synced in 30 minutes
  while online as a warning). No personal details in code or docs (the repo is public).

## Approaches considered

1. **Embed Google Calendar's web page.** Rejected: sign-in is blocked in embedded browsers; not dependable.
2. **Google's public embed (iframe).** Rejected: read-only, one calendar, needs public sharing.
3. **Own simple calendar over the Google Calendar API (chosen).** Day and week views, core edits, two-way sync,
   "Open in Google Calendar" for the rest. Matches the user's fallback "a simple version with the core
   functionalities".

## Decisions (made with the user)

| # | Decision |
|---|---|
| D1 | Show every calendar of every connected account, each with its own on/off switch (Settings › Calendar). Default on for calendars the user owns, off for others (holidays, subscribed). |
| D2 | Events that FloatBoard creates go to the **default account** (set in Settings › Calendar; the user's personal account), with a choice of any connected account per task. |
| D3 | Date-only tasks are not sent to Google automatically; they show only in FloatBoard's calendar. |
| D4 | If a task's event is deleted in Google, the task stays and keeps its date; only its time is removed. |
| D5 | No invitation handling in FloatBoard. |
| D6 | Day and week views only. |

## Decided after the builder check (with the user)

| # | Decision |
|---|---|
| D7 | **Only when you put it there.** A task appears on FloatBoard's calendar whenever it has a due date. It reaches Google only when the user drags it onto a time slot or uses "Add to calendar" (as today, with or without Meet). No automatic pushing, no backfill. |
| D8 | **Deleting:** deleting a task deletes the Google event FloatBoard made for it (Undo Delete recreates it). Deleting the event in Google leaves the task (D4). Nothing else deletes an event: clearing a task's due or time leaves its event in Google, still linked. |
| D9 | **Events made in Google** never create or change tasks; they just show in FloatBoard's calendar (mirror). |
| D10 | **What stays in step** between a task and its event: title and time, both ways. Event length and description live only in Google. |
| D11 | **"Add to calendar" on a date-only task** still makes an all-day event; moving it in Google changes the task's date. |
| D12 | **Time zone.** Settings › General › Time zone: *Follow this Mac* or a fixed zone. Default: fixed **Europe/London** (UK time: GMT in winter, BST in summer; literal GMT would show every meeting an hour off all summer). |
| D14 | **Linking meetings and tasks by id.** Any event (including meetings made in Google) can be linked to any number of tasks, and any task to any number of events, by typing or picking an id (`T-142` in an event's panel, `E-37` in a task's editor). This is separate from a task's own time on the calendar (D7): linking never changes times and never writes to Google. Shown both ways: a task lists its linked meetings ("E-37 · Thu 11:00 Tom / Q1 deck"); a meeting's panel lists its linked tasks with their checkboxes; the phone's Today list shows a meeting's linked tasks under it. Deleting either side removes the link only. Links are stored in one general `links` table (from type + id, to type + id, created, by whom) that jots, people and decisions reuse in parts 2–4. |
| D13 | **Visible ids.** Every task and event shows a short id: `T-<n>` for tasks (the existing card id), `E-<n>` for events (a local number given when FloatBoard first sees the event). Later parts use `J-` (jot), `P-` (person), `D-` (decision). Ids are shown on cards, in editors and panels, can be copied with one click, and typing an id in search finds the item. |

## Designer's calls (open to change in review)

- **C1. One time per task.** A task's time on the calendar *is* its due time. Dragging a task onto 15:00 Tuesday
  sets its due to Tuesday 15:00 and creates (or moves) its event; moving that event in Google moves the due.
  Chosen over a separate "booked work time" field because it adds no new concept. A booked time can be added later.
- **C2. Which calendar inside the account:** the account's main calendar, as "Add to calendar" does today.
- **C3. Done tasks:** ticking a task done leaves its event as it is (a record that the time was used).
- **C4. Which side wins:** for an event's own fields Google wins (FloatBoard re-reads after every write). For a
  linked task's title and time, the newer change wins, compared per field (Google's `updated` time against the
  time that field last changed on the board, recorded in `events`).
- **C5. Recurring events** show as their individual occurrences; moving or deleting one affects only that
  occurrence; changing the series is "Open in Google Calendar".
- **C6. A task on the calendar shows once**, as the task (checkbox, group colour), never also as an event block.
  It is not a "meeting": the bar's next meeting and the phone's meetings list skip it (it appears under "due
  today" instead). FloatBoard-made events are marked in Google with a private extended property
  (`floatboard_card` = card id) so they are recognised reliably.
- **C7. Date and time stored separately.** Today a date-only due is stored as midnight in the Mac's time zone and
  "has a time" is guessed from that, so changing time zone turns every date-only task into a timed one. This part
  stores the due date and a `due_has_time` flag separately (migration), and updates every reader: board, bar,
  reminders, phone copy, engine proposals.

## What the user sees

```
 Main window:   [ Board ]  [ Calendar ]          (Jots, People, Decisions come in parts 2–4)

 Calendar › Day                                           ‹ Today ›  [Day | Week]
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ All day: □ Renew passport (task)   ▬ Bank holiday                        │
 │ 09:00 ▬ Standup                                         (Meet: Join)     │
 │ 11:00 ▬ Tom / Q1 deck                                                    │
 │ 15:00 □ Send Tom the deck (task, due 15:00)                              │
 └──────────────────────────────────────────────────────────────────────────┘
 Bar:  3 to do · 2 doing │ ⏰ 11:00 Tom / Q1 deck  [Join]
```

- Events are coloured by their Google calendar; tasks show with a checkbox and their group colour, so they're
  never confused with events. Ticking a task's box on the calendar marks it done.
- Click empty time → quick "New event" (title, start, end, calendar). Drag an event to move it; drag its bottom
  edge to resize. Click an event → small panel: title (editable), time, calendar, video link, description,
  Delete, Open in Google Calendar.
- Each task shows `T-142`-style ids, each event `E-37`; click to copy.
- Event panel: **Linked tasks** with "Link a task…" (type an id or search titles) and each task's checkbox.
  Task editor: **Linked meetings** with "Link a meeting…" (type an id or pick from upcoming/recent events).
- Drag a task from the board's columns (with the board shown beside the calendar in Week view, or from a
  "Due soon" list in the Calendar tab's side) onto a time → C1.
- The board's task editor keeps today's "Add to calendar" (with or without Meet) and shows the linked event.
- **Bar:** the next event today that hasn't ended, shown from 60 minutes before it starts; Join when a video link
  exists (Meet, Zoom, Teams link found in the event).
- **Phone app:** a **Today** section above the board: today's events (time, title, Join) and tasks due today.
  Read-only for events in this part.

## How it works

- **Sync per calendar** with Google's incremental sync (`events.list` with `syncToken`, `singleEvents=true`), a
  window of 30 days back and 90 days ahead. Every 60 seconds while the Calendar tab or bar meeting is visible,
  every 5 minutes otherwise while awake, and once on wake. A `410 Gone` resets that calendar's sync.
- **Local cache** (new tables in `board.sqlite`, rebuildable from Google, excluded from "nothing is lost" rules
  because Google holds the truth):
  - `cal_calendars`: account, calendar id, name, colour, owned, shown, sync token, last synced.
  - `cal_events`: account, calendar id, event id, start, end, all-day, title, location, video link, description,
    html link, recurring event id, Google `updated`, status.
  - `links`: `id`, `from_type`, `from_id`, `to_type`, `to_id`, `created`, `actor` (user or connector), unique on
    the pair. Event links key on the event's short id so they survive resyncs.
  - `cal_events` also has `short_id` (the `E-<n>` number, unique, never reused).
  - Cards keep `gcal_account`, `gcal_event`, `gcal_link` (existing) and gain `gcal_calendar`, `gcal_synced_at`,
    and `due_has_time` (C7).
- **Writes** (create, move, resize, rename, delete) go through a calendar outbox (same pattern as today's outbox:
  durable, retried with backoff, shown as "waiting to send" on the event, errors in Activity). Offline edits wait
  and send on reconnect.
- **Phone:** the Mac adds today's and tomorrow's events (time, title, video link, calendar colour) to the board
  copy it already sends with `PUT /v2/board`. No calendar access on the engine.
- **Settings › Calendar** (a section under Connections › Outputs today, moving to the shared/feature layout
  later): connected accounts (with Reconnect when the new scope is missing), default account, calendars with
  switches. Settings › General gains Time zone (D12).

## Checks (tests first)

- Sync: incremental token stored and reused; `410` resets; cancelled events removed; recurring instances shown
  individually; time zones converted to the Mac's.
- Task ↔ event: drag sets due and creates event; moving the event in Google moves due; deleting it in Google keeps
  the task with date only (D4); deleting the task deletes only its FloatBoard-made event (D8); clearing a due
  leaves the event (D8); newer change wins per field (C4).
- No task reaches Google without a drag or "Add to calendar" (D7); Google-made events never touch tasks (D9).
- Time zone: a date-only task stays date-only after switching the Mac to Asia/Shanghai; fixed London shows the
  same times wherever the Mac is (C7, D12).
- Links: link and unlink both ways; linking never changes due or Google; deleting a task or a vanished event
  removes only its links; a recurring occurrence links on its own (D14).
- Ids: `E-<n>` stable across resyncs and never reused; search by `T-`/`E-` id finds the item (D13).
- Offline: edits queue and send later; nothing lost on quit.
- Fixtures captured from real Google responses (lesson from the portfolio monitor: fixtures from guesses hide
  bugs), scrubbed of personal data.

## Left to the builder

Exact layout sizes and fonts, the event panel's wording, how the "Due soon" side list is filtered, sync timer
details within the stated limits, table column types, and migration numbering.
