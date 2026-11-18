# Circle design: who matters, when you last talked, who is due

Date: 17 Nov 2026 · Branch `circle` · Mac schema **14** · engine migration **0041**
Requirements: `2026-11-17-assistant-features.md` §3 (P1–P13), §6, §7, §9 (Circle; reminders and weekly review), §10
(phone Circle screen, Plan's due people, "Contacted"/"Snooze" buttons, badge). Shared interfaces: `2026-11-17-foundation-design.md`
(used as they are; extensions listed in §9 below). Research: `docs/superpowers/research/2026-11-17-people-intelligence.md`.

Decisions taken here without the owner are marked **builder's call**.

## 1. Where things live

| Part | Where | Why |
|---|---|---|
| People, details, handles, clocks, due list, merges, imports, updates shown | Mac `board.sqlite` (schema 14) | the Mac is the record |
| WhatsApp, WeChat and calendar metadata readers | Mac (`FloatBoardConnectors/Circle/`) | the data is on the Mac (same access as the task connectors) |
| Gmail (inbox + Sent) and Outlook metadata readers | engine (`src/circle/`) | Gmail tokens and the Outlook extension live there |
| Companies House, news and blog feeds, `news_match` | engine hourly, for the people the Mac lists | keys and background runs live there; Mac pulls results |
| `contact_form`, `draft_message` | engine, on request | AI jobs run in the engine (foundation §5) |
| Phone Circle screen | engine copy (`PUT /v2/circle`, encrypted) + `files/circle.client.js` | phone features need Always-on mode |

FloatBoardCore stays offline: everything with a network call is in FloatBoardConnectors or the engine.

## 2. Mac schema 14

```sql
-- Circle's fields of a person (the core row is `people`, foundation). One row per person, made on first save.
CREATE TABLE circle_people(
    person_id INTEGER PRIMARY KEY, how_known TEXT NOT NULL DEFAULT '', company TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '',
    birthday TEXT NOT NULL DEFAULT '', language TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '',
    interval_days INTEGER, firm TEXT NOT NULL DEFAULT '', focus TEXT NOT NULL DEFAULT '', purpose TEXT NOT NULL DEFAULT '',
    stage TEXT NOT NULL DEFAULT '', stage_at REAL, snoozed_until REAL, reminded_at REAL, reminder_task INTEGER,
    updates_on INTEGER NOT NULL DEFAULT 0, news_muted INTEGER NOT NULL DEFAULT 0, feed_url TEXT NOT NULL DEFAULT '',
    officer_id TEXT NOT NULL DEFAULT '', officer_name TEXT NOT NULL DEFAULT '', officer_confirmed REAL, manual_checked REAL
);
-- Handles: phone (digits, international), email (lower case), whatsapp (chat id), wechat (chat name), linkedin (profile path).
CREATE TABLE person_handles(
    id INTEGER PRIMARY KEY AUTOINCREMENT, person_id INTEGER NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, added REAL NOT NULL,
    UNIQUE(kind, value)
);
CREATE INDEX person_handles_person ON person_handles(person_id);
-- Message and meeting metadata: who (handle), when, channel, direction. Never any text. One row per handle, channel, day and
-- direction (the day's latest time), so twelve months stay small. `name` is the display name from the header (for suggestions).
CREATE TABLE circle_exchanges(
    id INTEGER PRIMARY KEY AUTOINCREMENT, channel TEXT NOT NULL, direction TEXT NOT NULL, at REAL NOT NULL, handle_kind TEXT NOT NULL,
    handle TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', key TEXT NOT NULL UNIQUE, ref TEXT NOT NULL DEFAULT '', ignored INTEGER NOT NULL DEFAULT 0,
    added REAL NOT NULL
);
CREATE INDEX circle_exchanges_handle ON circle_exchanges(handle_kind, handle, at);
-- Per reader ("whatsapp", "wechat", "calendar", "gmail:<address>", "outlook"): data as of, complete back to, cursor, what it can't see.
CREATE TABLE circle_channels(channel TEXT PRIMARY KEY, as_of REAL, complete_from REAL, cursor TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '');
-- Merges (automatic on an exact phone/email match, or by hand), with what moved, so each can be split.
CREATE TABLE circle_merges(
    id INTEGER PRIMARY KEY AUTOINCREMENT, kept INTEGER NOT NULL, merged INTEGER NOT NULL, moved TEXT NOT NULL, auto INTEGER NOT NULL,
    at REAL NOT NULL, split REAL
);
-- Suggested people from imports (LinkedIn, Google Contacts); never added in bulk. state: new | added | dismissed.
CREATE TABLE circle_candidates(
    id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL, handles TEXT NOT NULL DEFAULT '[]',
    company TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'new', added REAL NOT NULL
);
-- Suggestions said no to (merge pairs, conversation handles).
CREATE TABLE circle_dismissed(key TEXT PRIMARY KEY, at REAL NOT NULL);
-- LinkedIn Connections.csv imports, each dated; rows by profile path.
CREATE TABLE linkedin_imports(id INTEGER PRIMARY KEY AUTOINCREMENT, export_date TEXT NOT NULL, imported REAL NOT NULL, rows INTEGER NOT NULL);
CREATE TABLE linkedin_rows(
    import_id INTEGER NOT NULL, url TEXT NOT NULL, name TEXT NOT NULL, company TEXT NOT NULL, position TEXT NOT NULL,
    PRIMARY KEY(import_id, url)
);
-- "What's new": kind linkedin | appointment | resignation | directorship | news_person | news_firm | post.
-- match: 'possible' (shown), 'unlikely' (set aside by Claude, shown on request); verdict: '' | right | wrong (news only).
CREATE TABLE circle_updates(
    id INTEGER PRIMARY KEY AUTOINCREMENT, person_id INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', at REAL, found REAL NOT NULL, match TEXT NOT NULL DEFAULT 'possible',
    verdict TEXT NOT NULL DEFAULT ''
);
CREATE INDEX circle_updates_person ON circle_updates(person_id, found);
-- Companies House officers that might be this person, until one is confirmed.
CREATE TABLE officer_candidates(
    person_id INTEGER NOT NULL, officer_id TEXT NOT NULL, name TEXT NOT NULL, born TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
    found REAL NOT NULL, PRIMARY KEY(person_id, officer_id)
);
```

Settings in `meta`: `circle_backfill_months` (default 12), `circle_engine_cursor` (exchanges), `circle_updates_cursor`,
`circle_phone_hash`, `circle_watch_hash`, `circle_linkedin_nudged`.

## 3. Core (FloatBoardCore/Circle/)

- `CircleModels.swift`: `CircleDetails`, `Handle` (+ `HandleKind`, normalisers: phone digits with UK `0` → `44` (**builder's
  call**: default country UK), email lower case, LinkedIn → `linkedin.com/in/<slug>`), `Exchange`, `Clocks`, `DueEntry`,
  `ProspectStage`, `ProspectPurpose`, `CircleUpdate`.
- `CircleStore.swift` (`@MainActor struct CircleStore { init(store:) }`): details read/save (checks `TagRules.problems` and
  the 5-active-prospects cap), handles add/remove (adding an email/phone another person has = **automatic merge**, any other
  kind = refused with the other person named), exchanges upsert, channels, contacted / talked / snooze / correct a meeting,
  bulk tier/tags, merge and split, suggestions, candidates, updates (mark right/wrong, mute), officer binding.
- `CircleClock.swift` (pure): the three clocks and due date (§9):
  - *last conversation* = latest exchange that has one of the other direction within 14 days (any channels), or a met meeting,
    or a manual "We talked" (**builder's call**: a second button next to "I contacted them" for calls and in person, so a call
    can count as a conversation; the one-tap "I contacted them" stays outreach, as §9 says);
  - *last heard from* = latest incoming; *last outreach* = latest outgoing or "I contacted them";
  - interval = per-person days, else tier default (Family 1 month, Close friend 2 weeks, Friend 6 weeks, Network 3 months, by calendar
    months), capped at 3 months by Investor (`TagRules.intervalCapMonths`);
  - due date = last conversation (else date added) + interval; **due** = due date ≤ now, not snoozed, no outreach in the last
    7 days. Snooze or ✗ = snoozed until now + one interval.
- `CircleDue.swift`: `dueThisWeek(now:)` (due by the end of this week, oldest first, with context lines: birthday within 7
  days, "you meet on Tue (E-41)" from upcoming events with their address); budget requests (one per person per week while due,
  most overdue first, skipped when an open reminder task exists or a meeting is within 7 days; birthday on the day);
  `makeReminderTask` ("Message <name>", tags = person's, linked `related`/auto, recorded so no second one); weekly review
  section `circle.due` (order 40); search `.person`.
- `CircleLinker.swift`: auto links (§6): event ↔ person when a guest's email matches one person exactly; task ↔ person when
  the task's sender or watched contact is one of their handles; jot ↔ person **suggested** when a jot names a person (code
  match on whole names and aliases, two-word names or longer, or an exact alias).
- `CircleImports.swift`: LinkedIn `Connections.csv` (skips the "Notes:" preamble; profile URL key; the import's date is the
  file's export date when given, else today) and Google Contacts CSV (**builder's call**: the contacts.google.com export
  instead of the People API, so no new Google permission). Both become candidates (exact email/phone match to a person =
  attached as handles there, nothing created). LinkedIn change detection: by profile path between the two latest imports that
  hold it: "Now <position> at <company> (was …) · changed since the export of 3 Nov"; missing from the latest = "not in the
  export of 3 Nov", never a change. Monthly nudge when the last import is over 30 days old (outside the budget, once a month).
- `CircleTimeline.swift`: per person: exchanges (channel, date, direction), meetings, linked jots, tasks, decisions; newest first.
- `CircleCopy.swift`: the phone copy (due list + up to 300 people, 12 timeline rows each, open tasks, what's new) and the
  watch list for the engine (eligible people only: Investor or Prospect and not Family, or turned on by request; name, firm,
  company, confirmed officer id, birth month/year, feed URL, mute).

## 4. Readers (FloatBoardConnectors/Circle/, engine src/circle/)

| Channel | Reads | Direction | Backfill | Can't see (shown on the card) |
|---|---|---|---|---|
| WhatsApp | `ChatStorage.sqlite` copy: 1:1 chats only (`ZSESSIONTYPE=0`), `ZISFROMME`, `ZMESSAGEDATE`; never `ZTEXT` | in/out | 12 months, then from the cursor | groups |
| WeChat | macOS notification history: 1:1 chats only (no sender in the note) | in | what macOS still holds | outgoing; muted chats; cleared notifications |
| Calendar | `cal_events` past, not cancelled: guests who accepted, the owner accepted or organised | met | the calendar's cached window (30 days back) | older meetings |
| Gmail | `messages.list` + `format=metadata` (From, To, Cc, Date, List-Unsubscribe); inbox (no bulk categories, no list mail) and **Sent** (≤ 5 recipients) | in/out | 12 months, newest first, a few calls per run | — |
| Outlook | the extension's rows (sender, time) as they arrive | in | none | outgoing; mail already read when the extension saw it |

Each reader records `circle_channels` (data as of; complete back to). The card shows a "Data as of" line per channel and
says "Outlook and WeChat show incoming only" instead of guessing. Readers run only while Circle is on (module flag).

Engine: `GET /v2/circle/exchanges?after=<seq>` (user key) gives the Gmail/Outlook rows (`seq, key, channel, direction, at,
handle, name`) and each reader's status. Rows are kept encrypted (handle, name) and purged 30 days after they were received.

## 5. Updates (P11–P13)

- **LinkedIn**: §3 imports. **P12**: card links to the profile and reminds to turn on LinkedIn's bell for Investor/Prospect people.
- **Companies House** (engine, key `companies_house_key` via `PUT /v2/keys`): without a confirmed officer, `search/officers?q=<name>`
  → candidates (name, birth month/year, address snippet, appointments count); those whose birth month/year matches the
  person's birthday are listed first as "born <month year> matches" but never linked. Once the owner confirms one, its
  `officers/<id>/appointments` is read at most weekly: the first read records current directorships ("directorship"); later
  reads add new appointments ("appointment") and resignations ("resignation") as separate kinds.
- **News** (engine, at most weekly per person): Google News RSS, person (`"Name"` plus firm/company when known) and firm
  (`"Firm"`) as separate searches and kinds; duplicates merged by normalised title (also across the two kinds: person wins);
  ⚑ `news_match` (Haiku, one batch per run) answers per headline `about_them` / `unlikely`. Mitigations as §7/§9: everything
  is stored; `unlikely` is set aside, never dropped ("2 set aside · Show"); every item stays **possible** until the owner
  marks it Right or Wrong (opening doesn't count); mute per person; person and firm news separate. Without a Claude key all
  items are "possible".
- **Blog / Substack / company news page**: the person's feed URL (RSS or Atom), at most weekly, kind "post".
- **P13 Chinese contacts**: language Chinese or a WeChat handle → card shows "Last checked <date>" with "Checked today" and
  search links (Baidu, Qichacha). No automatic source.
- Mac pulls `GET /v2/circle/updates?after=<seq>`; the watch list is sent with `PUT /v2/circle/watch` when it changes.

## 6. AI jobs (engine, Haiku, registered per foundation §5)

| Job | Endpoint | Input | Output | Flag |
|---|---|---|---|---|
| `contact_form` | `POST /v2/circle/fill` | header names, addresses, phone numbers only (no bodies, no signatures) | name, emails, phones, company guess from the domain | low: the owner confirms the form |
| `news_match` | hourly run | headline, source, person's name and firm | about_them / unlikely | ⚑ mitigations §5 |
| `draft_message` | `POST /v2/circle/draft` (Mac), `POST /app/api/circle/draft` (phone) | name, language, notes, how they know them, ≤ 5 last messages (WhatsApp text given by the Mac on request; Gmail fetched by the engine) | a short draft | low: never sent; nothing kept |

Each checks `settings.modules.circle`; no key → a clear "add your Claude key" answer. No rulebooks (nothing for the owner to edit).

## 7. Mac UI (FloatBoard/Circle/)

- **CircleTab**: left a list (search; tier and tag filters; sort name / last talked / due date; multi-select → "Change
  tier", "Tags", "Merge" (two)); top strip "Due this week (n)"; a "Suggestions" button (from conversations, imports, merges,
  Companies House candidates). Right: the person card.
- **Person card**: header (name, P-n, tier, tags, Edit, Draft, Delete); three clocks + "Due <date>"/"Snoozed until";
  buttons "I contacted them", "We talked", "Snooze", "Make task" (+ "with a calendar slot"); "Data as of" per channel;
  prospect block (purpose, stage, open tasks from their messages); What's new (possible/right/wrong, set-aside, mute);
  Companies House (candidates → Confirm; bound officer; Unlink); LinkedIn profile + bell reminder; Chinese contacts' manual
  check; timeline. Merges show "Merged from … · Split".
- **Add / edit form** (P2): the fields of §3 P2; Investor → firm and focus; Prospect → purpose and stage; "Fill from
  messages" (contact_form) fills only empty fields, shown for confirmation. Right-click selected text → **Add to Circle**
  opens it with the name.
- Settings › Areas › Circle: backfill months, LinkedIn import, Google Contacts import (**builder's call**: placed on the Circle
  tab's Suggestions sheet instead, where they are used).

## 8. Phone (§10)

- `PUT /v2/circle` (Mac, hash-gated): the copy (§3). `GET /app/api/circle` returns it; `POST /app/api/circle/action`
  `{actions:[{id, person, action: contacted|talked|snooze, made_at}]}` queues them; Mac `GET /v2/circle/actions`, applies
  (contacted = outreach at made_at, newest wins; snooze = made_at + interval), acks `POST /v2/circle/actions/ack`.
- `files/circle.client.js` (inserted at `/*@CIRCLE_JS@*/`): the Circle screen (due this week, search, person cards with
  last talked, what's new, open tasks, timeline; buttons "I contacted them", "Snooze", "Draft" → opens WhatsApp `wa.me` or
  Gmail compose with the draft); Plan gets "Due to contact" with "I contacted them"; queue offline like the board's; cleared
  on sign-out.
- Notification buttons: the push for a `circle_due` budget reminder carries `circle: "P-n"`; the service worker adds
  **Contacted** and **Snooze**; tapping one posts the action (opens the app to finish it when offline).
- Badge: `navigator.setAppBadge(overdue tasks + due people)`.

## 9. Foundation extensions (separate commits titled "Foundation: …")

- `check(DB.schemaVersion == 12)` → `>= 12` (each area raises the version).
- `PushPayload` gains optional `circle` (the person id) so the service worker can add buttons; `AlertItem` likewise.
- `GmailSource.metaPage(q, pageToken, max)` (headers-only page) for Circle's reader.
- `/*@CIRCLE_JS@*/` marker in `app.client.js` and `circleHooks` (render, Plan block, badge, sign-out) — small, marked.

## 10. Left out (and why)

- Group chats (features: not in v1); WeChat outgoing (no source); Outlook Sent (the extension sees the inbox only).
- Reading LinkedIn posts (P12: against LinkedIn's terms); paid enrichment; X.
- Google Contacts by API (needs a new permission and a reconnect): the CSV export does the same job.
- Live Companies House and news calls, a live Gmail metadata pass: built and tested with fixtures only (live steps in the report).
