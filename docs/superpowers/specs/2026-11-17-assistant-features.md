# FloatBoard assistant: features per area, then links

Date: 17 Nov 2026 · Status: **draft for review** (Codex review first, then the owner)

FloatBoard is growing from a task board into a small personal assistant with four new areas:
Calendar, Jots, People and Decisions. This document defines **what each area does on its own
first** (sections 1–4). Only after that does it define **how the areas link** (section 5).
Each area still gets its own full design and build plan before it is built; this document fixes
scope so those designs don't drift.

Build order: Calendar (built on branch `calendar`, awaiting review) → Jots → People → Decisions.

## Ground rules (apply to every area)

- **The board stays home.** The bar and the board are where the owner works. Every area either
  feeds the board (suggested tasks) or hangs off it (context). No area competes to be the home screen.
- **One main trigger per area** (what makes something appear there), stated at the top of each section.
- **AI proposes, the owner confirms.** Nothing is filed, sent, merged or deleted by AI on its own.
  Every suggestion uses the existing suggestion chip (✓ / ✗), and ✗ teaches the rulebook.
- **No logging chores.** Anything that can be worked out from data FloatBoard already reads is
  worked out, not typed in.
- **Reminders are capped** (a few a day at most); blanket reminders train people to ignore the tool.
- **Visible ids everywhere:** `T-` task, `E-` event, `J-` jot, `P-` person, `D-` decision. One click
  copies; typing an id in search finds it; typing an id in any text field links it.
- **Each area is a switchable module** (Settings › Modules, like Inbox today): its own code folder
  and tables; off by default for new installs; switching off hides it and loses nothing.
- **Nothing lost:** edits have history and Undo; deletes go through the existing undo bar.
- **Settings layout:** shared sections first (Bar, Groups, Phone, Connections, AI & costs, Keys),
  then one section per area.

---

## 0. Board (exists today, for reference)

Trigger: the owner, plus suggested tasks from Gmail, Outlook, WhatsApp, WeChat and Fathom.
Tasks with groups, due dates, statuses (To do / Doing / Watch / Done), the always-visible bar,
quick add, phone app, rulebooks, history, backups. Not changed by this document except where a
link in section 5 adds something to the task editor.

---

## 1. Calendar — built, awaiting review

**Trigger:** Google Calendar (two-way mirror).
**Job:** see time; meetings and the tasks due on each day in one place.

| # | Feature | v1 |
|---|---|---|
| C1 | Day and week views mirroring every calendar of every connected Google account; each calendar has an on/off switch | ✓ built |
| C2 | Create, move, resize, rename and delete events in FloatBoard; changes go to Google | ✓ built |
| C3 | Every task with a due date shows on its day (date-only tasks in an all-day strip) | ✓ built |
| C4 | Drag a task onto a time slot, or "Add to calendar", books it in Google; nothing goes to Google otherwise | ✓ built |
| C5 | Event panel: time, calendar, guests count, Join button, "Open in Google Calendar" | ✓ built |
| C6 | Bar shows the next meeting (or the one in progress) with Join | ✓ built |
| C7 | Phone Today list: today's meetings and tasks due today | ✓ built |
| C8 | Settings: calendars, default account for new events, Reconnect, time zone (UK time default, or follow the Mac) | ✓ built |
| C9 | Works offline: changes wait and send later; never creates duplicates | ✓ built |

**Not in v1:** invitations (accept/decline), month view, editing a whole recurring series,
moving an event to another calendar, dragging all-day events, work account (later).

---

## 2. Jots — next to design

**Trigger:** the owner (typing or voice), plus meeting notes from Fathom.
**Job:** a calm place to dump thinking every day, filed into the same groups as tasks.

| # | Feature | v1 |
|---|---|---|
| J1 | **Capture window** from anywhere (⌃⌥J) and the ✎ button on the bar: a small quiet window, timestamp, ⌘↩ save, Esc close | ✓ |
| J2 | **Voice on the Mac:** the capture window accepts macOS dictation (press Fn twice); a 🎙 button starts it. No custom recording | ✓ |
| J3 | **Phone capture:** the phone app opens its Jots screen straight to a writing box; voice via the phone keyboard's microphone (native dictation, nothing to build) | ✓ |
| J4 | **Jots tab:** today at the top with a large writing box, earlier days below, search, group filter | ✓ |
| J5 | **Folders = groups,** plus a **Braindump** folder where unfiled captures land | ✓ |
| J6 | **Claude files a dump:** splits a mixed dump into parts and suggests a group for each part (✓ / ✗); the original text is kept whole | ✓ |
| J7 | **Meeting notes become jots:** each Fathom recap is saved as a jot in the meeting's group (in addition to the tasks it already suggests) | ✓ |
| J8 | **Daily nudge** at a chosen time (Mac notification + phone push), skipped on days already jotted; shows the day's finished tasks as a memory prompt | ✓ |
| J9 | **Daily file copy:** each day's jots are copied to `Resources/braindumps/daily/YYYY-MM-DD.md` (one-way; FloatBoard is the record) | ✓ |
| J10 | Edit and delete with history and Undo | ✓ |
| J11 | **Weekly review page** (Sunday): the week's done tasks, jots, meetings and decisions, with cleanup suggestions | later (see Q2) |

**Not in v1:** rich text or attachments, linking jots to each other, a jot prompt on every
ticked task (nags), notes-first daily pages.

---

## 3. People — after Jots

**Trigger:** the messages FloatBoard already reads (Gmail, Outlook, WhatsApp, WeChat) and
calendar meetings. Takes over the separate keep-in-touch project (spec 24 Oct 2026), which is retired.
**Job:** know who matters, when you last really talked, and who is due a message.

| # | Feature | v1 |
|---|---|---|
| P1 | **Profile:** name, tier, how you know them, notes, birthday, language, handles (emails, phones, WhatsApp, WeChat) | ✓ |
| P2 | **Where people come from:** offered from 1:1 two-way conversations in the channels above (✓ / ✗), plus manual add; no bulk import of everyone | ✓ |
| P3 | **Same person, many handles:** auto-merge on exact phone or email; name-only matches (including Chinese ↔ pinyin) go to a "Same person?" queue, never auto-merged | ✓ |
| P4 | **Last contact,** worked out automatically: the last real two-way exchange in any channel, or a meeting together | ✓ |
| P5 | **Tiers with default intervals,** overridable per person: Family 2 weeks, Close friend 3 weeks, Network 2–3 months, Investor quarterly; snooze | ✓ |
| P6 | **Keep-in-touch reminders arrive as suggested tasks** ("Message P-12: 5 weeks"), at most 3 a day; sending a message to them closes it automatically | ✓ |
| P7 | **Message history:** a per-person timeline (channel, date, direction) with a link that opens the thread in its app; no message text stored beyond what triage already keeps | ✓ |
| P8 | **Prospects (Network and Investor only):** stage (target → contacted → connected → follow-ups → graduated / faded) and purpose (career, investing, venture, learning) | ✓ |
| P9 | **Careful engagement:** for a prospect or a due person, Claude gives a reason to reach out now (promise made, their news, follow-up date) and a short draft in the owner's voice and language; one tap opens WhatsApp / Gmail with it; never sent automatically | ✓ |
| P10 | **Signals from messages:** promises ("I'll send you that"), follow-up dates ("back from holiday on the 3rd"), unanswered questions, life events | later |
| P11 | Suggestions of new people to meet; LinkedIn export import | later |

**Dropped from the keep-in-touch spec:** the WhatsApp self-chat digest (the bar and phone push
replace it), the separate web app and background service, its own message readers.

---

## 4. Decisions — last

**Trigger:** Claude reading jots and meeting notes.
**Job:** a log of what was decided and why, so it can be looked back on. **Read-only.**

| # | Feature | v1 |
|---|---|---|
| D1 | **Automatic extraction** from new jots and meeting notes; nothing typed by hand | ✓ |
| D2 | **Decision card:** the decision, date, exact quote, what prompted it, options and reasons **only if written down** (otherwise "not recorded"), group | ✓ |
| D3 | **Status:** decided / tentative / reversed / superseded; a superseded decision points to its replacement | ✓ |
| D4 | **Confidence:** uncertain extractions sit in a separate "Maybe" list | ✓ |
| D5 | **Owner controls on a read-only log:** "Not a decision" (removes it and teaches the rulebook) and "Wrong status"; no free editing of content | ✓ |
| D6 | **Review dates** by type: 30 days operational, 90 strategic, 6–12 months investment; at most 3 due reviews a week, each asking "what happened?" and "was the thinking sound?"; the answer is saved as a jot | ✓ |
| D7 | Search and group filter | ✓ |

**Not in v1:** decision templates, scoring or outcome statistics, extracting from email.

---

## 5. Links between the areas

Links are stored in one general `links` table (from id, to id, created, by whom), already built
with Calendar. Three ways a link is made: **auto** (certain, made by FloatBoard), **suggested**
(Claude proposes, owner confirms), **manual** (owner types or picks an id).
Default rule: deleting either side removes the link only, never the other item. The one exception
is a task's own Google event (Calendar D8: deleting the task deletes the event it booked).

| Link | How it's made | Where it shows |
|---|---|---|
| Task ↔ Event (task's own time) | auto, when a task is put on the calendar | task card time; calendar block (built) |
| Task ↔ Event (related meeting) | manual by id (built) | task editor "Meetings"; event panel "Tasks" (built) |
| Jot → Task | suggested (Claude finds an action) or manual ("Make task" on a selection) | jot shows "→ 1 task", ticked when done; task editor shows "From J-…" |
| Task → Jot | manual ("Jot about this" on a task) | task editor timeline of its jots |
| Meeting-notes jot ↔ Event | auto (Fathom recap matched to the calendar event by time and title) | event panel shows its notes; jot shows the meeting |
| Jot ↔ Person | suggested (names Claude spots) or manual (typing `P-12`) | person page "Jots"; jot shows the person chip |
| Event ↔ Person | auto (guest email matches a person's handle) | person page "Meetings"; counts as contact (P4) |
| Task ↔ Person | auto (task suggested from that person's message; keep-in-touch reminder) or manual | person page "Open tasks"; task shows the person chip |
| Decision → source Jot / Event | auto, always (every decision cites where it came from) | decision card "Source" |
| Decision ↔ Person | auto from the source (people linked to that jot or meeting) | person page "Decisions" |
| Decision ↔ Task | suggested (follow-up actions of a decision) | decision card; task editor |
| Decision → Decision | auto (superseded by) | decision card |

**The person page and the meeting panel become the two hubs:** a person page shows their
messages, meetings, jots, open tasks and decisions; a meeting shows its tasks, notes, people and
decisions.

**One meeting feeds everything:** Fathom recap → a jot (J7) linked to the event → suggested tasks,
detected decisions, and contact updates for its guests.

---

## 6. Open questions for the owner (each with a suggested default)

1. **"Reverse apply" of meeting notes to jots** — what should happen when a meeting covers
   something an earlier jot was about? *Default: Claude suggests a link between the meeting's jot
   and the earlier jot; old jots are never edited.*
2. **Weekly review:** build it with Jots, or after Decisions? *Default: after Decisions, so it can
   include decisions.*
3. **Where people come from:** only people you actually message (P2), or import Google Contacts too?
   *Default: from messages; Google Contacts only fills in names and birthdays for people already there.*
4. **Window layout:** five top tabs (Board, Calendar, Jots, People, Decisions) plus a hideable jots
   panel beside the board that follows the selected task? *Default: yes.*
5. **AI model for Decisions extraction:** the owner reads the result, so Sonnet; Haiku for Jots
   filing and People last-contact work. *Default: as stated, cost shown in Settings.*
