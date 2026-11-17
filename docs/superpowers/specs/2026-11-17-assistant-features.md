# FloatBoard assistant: features per area, then links

Date: 17 Nov 2026 · Status: **draft v2 for owner review** (v1 reviewed by Codex; its findings are folded in, see the end)

FloatBoard is growing from a task board into a small personal assistant with four new areas:
Calendar, Jots, People and Decisions. Sections 1–4 define **what each area does on its own**, each
complete without the others. Section 5 defines **only how links between areas are made and shown**.
Each area still gets its own full design and build plan before it is built; this document fixes scope.

Build order: Calendar (built on branch `calendar`, awaiting review) → Jots → People → Decisions.

## Ground rules (apply to every area)

- **The board stays home.** The app opens on the board; the bar is always visible. New areas are tabs
  next to it. No area competes to be the home screen.
- **One main trigger per area**, stated at the top of each section.
- **Claude proposes, the owner confirms** anything that files, merges, sends or changes meaning.
  Importing source material (a meeting recap, a message timestamp) is automatic; interpreting it
  (which group, which person, is this a decision) is a suggestion until confirmed. ✗ teaches the rulebook.
- **No logging chores.** What FloatBoard can work out from data it already reads is worked out.
  Plain facts (dates, who sent what when) are computed by code, not AI.
- **One reminder budget.** All assistant reminders (People, Decision reviews) share one daily limit
  (default 3), with quiet hours, de-duplicated across Mac and phone. The daily jot nudge is separate
  (one a day, skippable). Existing task due alerts are unchanged.
- **Visible ids:** `T-` task, `E-` event, `J-` jot, `P-` person, `D-` decision. One click copies;
  typing an id in search finds it; typing an id in a **jot, task note or event panel** (not search,
  drafts or imported text) links it when saved. Removing the id text does not unlink; unlinking is
  an explicit ✕ on the link chip.
- **Each area is a switchable module** (Settings › Modules): own code folder and tables, off by
  default for new installs. Switching off hides the tab and its links; nothing is deleted; switching
  on brings it all back.
- **Nothing lost:** edits keep history; deletes go through the undo bar.
- **Where things live:** the Mac's database is the record (as for tasks today). The phone writes to
  the engine and the Mac takes the change in (as phone task edits do today); Claude's background work
  runs where email triage runs (the engine, in Always-on mode). **Phone features need Always-on mode**
  (the owner's current mode); in Mac-only mode they are Mac-only.
- **Privacy:** see the per-area "Data" lines. The general rule: People uses message **metadata only**
  (who, when, channel, direction); message text goes to Claude only when the owner asks for a draft,
  and only the last few messages with that person. Nothing new is shown in notification previews
  beyond what tasks show today.

---

## 0. Board (exists today, for reference)

Trigger: the owner, plus suggested tasks from Gmail, Outlook, WhatsApp, WeChat and Fathom. Tasks with
groups, due dates, statuses, the bar, quick add, phone app, rulebooks, history, backups. Unchanged,
except that task editors gain link chips (section 5).

---

## 1. Calendar — built, awaiting review

**Trigger:** Google Calendar (two-way). **Authoritative spec:** `2026-11-16-calendar-design.md`
(decisions D1–D14). Summary:

| # | Feature |
|---|---|
| C1 | Day and week views mirroring every calendar of every connected account; on/off per calendar |
| C2 | Create, move, resize, rename, delete events in FloatBoard; changes go to Google |
| C3 | Tasks with a due date show on their day; title and time stay in step with their own event both ways |
| C4 | A task reaches Google only when dragged onto a slot or "Add to calendar" (date-only → all-day event) |
| C5 | Event panel: time, calendar, Join, Open in Google; deleting a task deletes its own event, not vice versa |
| C6 | Bar shows the next or current meeting with Join |
| C7 | Phone Today list (as fresh as the Mac's last sync) |
| C8 | Settings: calendars, default account, time zone; existing accounts show their main calendar at once and "Show all calendars…" (one click) for the rest |
| C9 | Offline changes wait and send later; Undo within 10 s never touches Google |

**Needed later by People/Jots (an extension, not built):** keep each event's guest list (email + reply
status) in the cache, and keep a small permanent record for events that a jot or decision links to,
so links survive the cache's 30-day/90-day window.

**Not in v1:** invitations, month view, whole-series edits, moving events between calendars.

---

## 2. Jots — next to design

**Trigger:** the owner (typing or voice), plus meeting recaps from Fathom.
**Job:** a calm place to dump thinking every day, filed into the same groups as tasks.
**Unit:** one saved capture = one jot (`J-n`), with a timestamp, text, a folder, and its source
(typed / phone / meeting).

| # | Feature |
|---|---|
| J1 | **Capture window** from anywhere (⌃⌥J) and ✎ on the bar: small, quiet, ⌘↩ saves, Esc closes and **keeps the draft** for next time |
| J2 | **Voice on the Mac:** the capture window works with macOS dictation as configured in System Settings (no custom recording; a 🎙 button only if it can reliably start dictation) |
| J3 | **Phone capture:** the phone Jots screen opens to a writing box; voice via the phone keyboard's microphone. Captures made offline are kept on the phone and sent when back online |
| J4 | **Jots tab:** today on top with a writing box, earlier days below, search, folder filter |
| J5 | **Folders = the board's groups**, plus **Braindump** (where every new jot lands) and **Unfiled**. Renaming a group renames its folder; deleting a group moves its jots to Unfiled |
| J6 | **Sorting a braindump:** Claude suggests splitting a mixed jot into parts, each with a group. Accepting a part creates a new jot in that folder marked "from J-n"; parts can be accepted one by one; the original stays whole and is marked "sorted" when all parts are handled. Editing the original later does not change the parts |
| J7 | **Actions in a jot → suggested tasks:** Claude suggests tasks from a jot (✓/✗, the existing chip); "Make task" on selected text does it by hand. The jot shows "→ 1 task" |
| J8 | **"Jot about this"** on a task opens the capture window already linked to that task |
| J9 | **Meeting recaps become jots:** each Fathom meeting is saved once as a meeting jot holding Fathom's **full** summary (not the 600-character board summary) plus the link to full notes; its folder is suggested (Unfiled until confirmed). The tasks Fathom already suggests are **not** suggested again from this jot |
| J10 | **Daily nudge** at a chosen time (Mac notification and phone push), skipped on days already jotted; shows the day's finished tasks as a prompt |
| J11 | **Daily file copy** to `~/Code/Resources/braindumps/daily/YYYY-MM-DD.md` (folder set in Settings), dated by the app's time zone, rewritten whenever that day's jots change (including late phone captures and deletes); a failed write is shown in Activity and retried |
| J12 | Edit and delete with history and Undo |

**Data:** jot text is stored in the Mac database and the engine (needed for phone and Claude); sent
to Claude for J6/J7 only when the Jots rulebook allows.
**Not in v1:** rich text, attachments, a prompt on every ticked task, weekly review (see Q2).

---

## 3. People — after Jots

**Trigger:** who you exchange messages and meetings with. Replaces the separate keep-in-touch
project (spec 24 Oct 2026), which is retired.
**Job:** know who matters, when you last really talked, and who is due a message.

**What each channel can tell FloatBoard** (decides what "last contact" means):

| Channel | Incoming | Outgoing | Notes |
|---|---|---|---|
| WhatsApp (Mac app's database) | ✓ | ✓ | full two-way, 1:1 chats only |
| Gmail | ✓ | needs a new read of **Sent** (who and when only, no text) | see Q3 |
| Outlook (extension) | unread only | ✗ | "heard from" only |
| WeChat (notifications) | ✓ | ✗ | "heard from" only |
| Calendar | — | — | a past meeting both of you accepted |

| # | Feature |
|---|---|
| P1 | **Profile:** name, tier, how you know them, notes, birthday, language, handles (emails, phones, WhatsApp, WeChat) |
| P2 | **Where people come from:** suggested from 1:1 conversations with replies in both directions (✓/✗), plus manual add. No address-book import in v1 |
| P3 | **Same person, many handles:** merged automatically only on an exact phone or email match; anything else ("same name?", Chinese ↔ pinyin) is a suggestion. Every merge can be undone (split) |
| P4 | **Contact dates, computed by code:** *last talked* (a two-way exchange or an accepted meeting together) and *last heard from* (incoming only). Channels that can't see outgoing messages say so on the profile |
| P5 | **Tiers and default intervals** (from *last talked*), changeable per person: Family 14 days, Close friend 21, Network 70, Investor 91 |
| P6 | **Keep-in-touch reminder** when a person passes their interval: a suggested task "Message P-n", inside the shared reminder budget, at most one open per person. ✗ snoozes that person one interval; it closes itself when an outgoing message to them is seen |
| P7 | **Timeline:** per person, a list of channel, date and direction of recent exchanges, each opening the conversation in its app. No message text stored |
| P8 | **Draft a message** (on request, from the profile or a reminder): Claude writes a short draft in the owner's voice and the language usually used with them, from the profile notes and the last few messages only; it never invents a reason. One tap opens WhatsApp or Gmail with it, otherwise copies it. Never sent automatically |
| P9 | **Prospects** (Network and Investor only): a purpose (career, investing, venture, learning) and a stage the owner moves by hand: *want to meet → in touch → regular* (or *dropped*). Prospects get the same reminders and drafts |

**Data:** profiles and metadata live on the Mac (engine copy for the phone). Message text never
leaves its app except the few messages sent to Claude for a requested draft.
**Later:** promises and follow-up dates spotted in messages, life events, suggested new people,
LinkedIn export, address-book import.

---

## 4. Decisions — last

**Trigger:** Claude reading jots and meeting jots.
**Job:** a log of what the owner decided and why, to look back on. **Read-only** (the owner never
types decisions; corrections below).
**What counts:** a commitment to a course of action by the owner, or a group the owner is part of
("we'll start the cohort in January"). Not intentions or to-dos ("I should…", "maybe…").

| # | Feature |
|---|---|
| D1 | **Extraction:** each new or edited jot and meeting jot is read once per version; found decisions appear in the log marked "found by Claude", uncertain ones in a separate **Maybe** list |
| D2 | **Card:** the decision in one line; the date it was made (the source's date, not the extraction date); the exact quote with its source (`J-n`, labelled "from meeting summary" for meeting jots); what prompted it, options and reasons **only if written** (otherwise "not recorded"); group; type (operational / strategic / investment) |
| D3 | **The quote is kept** with the decision, so deleting or editing the source later doesn't erase the evidence (the card then says "source changed" or "source deleted") |
| D4 | **Status:** decided / tentative / reversed / superseded. A later decision that seems to replace an earlier one is **suggested** as superseding it; the owner confirms |
| D5 | **Corrections:** "Not a decision" (removes it, teaches the rulebook), "Wrong status", "Wrong type", "Re-read source" (extract again). No free editing of text |
| D6 | **Reviews:** only for decisions in the main log (not Maybe), after 30 days (operational), 90 (strategic) or 180 (investment), once each, inside the shared reminder budget. Asks "what happened?" and "was the thinking sound?"; the answer is saved as a jot linked to the decision. Each review can be snoozed or turned off per decision |
| D7 | Search and filters (group, type, status) |

**Data:** reads jots only (not email). Uses Sonnet, because the owner reads the output.
**Not in v1:** decision templates, outcome statistics, extraction from email.

---

## 5. Links between the areas

Links are stored in the one general `links` table already built with Calendar. Each link has a
**kind** and records who made it:

| Kind | Meaning | Example |
|---|---|---|
| `own-event` | a task's own Google event | T-12 → E-40 (built) |
| `related` | two items are about the same thing | T-12 ↔ E-41, J-7 ↔ P-3 |
| `source` | an item was made from another | T-15 from J-7; D-2 from J-9 |
| `notes-of` | a meeting jot belongs to an event | J-9 → E-41 |
| `review-of` | a review jot reviews a decision | J-30 → D-2 |
| `supersedes` | a decision replaces another | D-5 → D-2 |

Made **auto** (certain), **suggested** (Claude proposes, owner confirms) or **manual** (owner picks
or types an id). Unlinking is always manual and undoable. Deleting an item hides its links (restored
by Undo); it never deletes the other item, except a task's `own-event` (Calendar D8). Merging two
people moves all links to the merged person.

| Link | Kind | How it's made |
|---|---|---|
| Task ↔ its own Google event | own-event | auto (built) |
| Task ↔ meeting | related | manual by id (built) |
| Jot → Task (J7) | source | suggested or manual |
| Task → Jot (J8) | related | manual ("Jot about this") |
| Meeting jot → Event | notes-of | auto only when exactly one event of the owner's overlaps the meeting time; otherwise suggested candidates; unmatched is fine; can be changed |
| Jot ↔ Person | related | suggested when a jot names a known person; manual by `P-n` |
| Event ↔ Person | related | auto when a guest's email exactly matches one person's handle; a past meeting counts as *last talked* only if both accepted |
| Task ↔ Person | related | auto when the task was suggested from that person's message (labelled "from their message"); manual otherwise |
| Decision → Jot | source | auto, always |
| Review jot → Decision | review-of | auto (D6) |
| Decision → Decision | supersedes | suggested (D4) |
| Decision ↔ Person / Task | related | suggested only; people at a meeting are shown as "at the meeting", not as involved |

**Hubs:** a person page shows timeline, meetings, jots, open tasks and decisions linked to them; a
meeting panel shows its tasks, notes, people and decisions. **One meeting, one pass:** a Fathom
recap makes one meeting jot (J9), its existing suggested tasks, and decisions read from that jot once.

---

## 6. Questions for the owner (each with a suggested default)

1. **Decisions confirmation.** You asked for a read-only tab that finds decisions by itself. Codex
   argues every decision should wait for your ✓ first. *Default: show found decisions directly (as you
   asked), uncertain ones in Maybe, supersession only suggested.* Alternative: everything waits for ✓.
2. **Weekly review:** with Jots, or after Decisions? *Default: after Decisions, so it can include them.*
3. **Gmail Sent folder.** To know you replied by email, FloatBoard must read who you emailed and when
   from Sent (no text). *Default: yes.* Without it, email counts only as "heard from".
4. **"Reverse apply" of meeting notes to jots** — what did you mean? *Default: Claude suggests a
   `related` link between a new meeting jot and an earlier jot on the same topic; old jots are never
   edited.*
5. **Prospect stages** (P9): keep the simple hand-moved stages in v1, or leave prospects to tiers
   only for now? *Default: keep, hand-moved only.*

---

## Changes from v1 (Codex review, 17 Nov 2026)

- Each area now owns all its features (jot → task, "Jot about this" moved into Jots; Calendar
  extension named); section 5 is only link kinds and how links are made.
- Added: where data lives and phone/offline behaviour; per-channel table for People; privacy lines.
- Interpretation is suggested, not automatic (meeting jot folder, person merges, supersession,
  meeting-event matching); plain dates computed by code, not AI.
- Evidence kept: decisions keep their quote; meeting jots keep Fathom's full summary; linked events
  kept beyond the cache window.
- Defined: what a jot is, how splitting works, draft kept on Esc, group rename/delete, exact People
  intervals, one reminder per person, a shared reminder budget, decision definition and dates,
  review eligibility, link kinds, unlink and merge rules, daily-file location and rewrite rules.
- Removed from v1: address-book import, AI for contact dates, drafts based on unbuilt signals,
  duplicate task suggestions from meeting jots. Board stays the launch tab.
- Not adopted: making every decision wait for ✓ (asked as Q1, because it reverses what the owner asked for).
