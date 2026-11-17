# FloatBoard assistant: features per area, then links

Date: 17 Nov 2026 · Status: **draft v3** (owner's 28 comments + market research folded in; Codex review next, then owner)
Research behind it: `docs/superpowers/research/2026-11-17-market-research.md`,
`docs/superpowers/research/2026-11-17-people-intelligence.md`.

FloatBoard grows from a task board into a small personal assistant: **Calendar, Jots, Circle,
Decisions, Resolutions**. Sections 1–5 define what each area does on its own. Section 6 defines only
how they link. Section 7 lists every AI job (all Haiku) and flags the ones that are judgement calls.
Each area still gets its own full design and build plan; this document fixes scope.

Build order: Calendar (built, in review) → Jots → Circle → Decisions → Resolutions.

## Ground rules

- **The board stays home.** The app opens on the board; the bar is always visible. Tabs:
  Board · Calendar · Jots · Circle · Decisions · Resolutions. Each area is a module that can be
  switched off (nothing deleted; off by default for new installs).
- **One shared standard for items.** Tasks, jots, people, decisions and resolutions all have: a
  visible id (`T- E- J- P- D- R-`), date added, date updated, source (typed / phone / meeting /
  message / Claude), and **tags**. Tags are the board's groups; any item can carry several. One
  search covers everything; every list sorts by date added, date updated or tag.
- **Claude proposes, the owner confirms**, except where the owner chose otherwise (Decisions is a
  recorder, see 4). The owner's own words are never replaced without a before/after confirm.
- **No logging chores.** Dates, matches and changes are computed by code, not AI.
- **Select text → right-click** works the same everywhere text is shown (jots, task notes, decision
  reviews, meeting notes): **Make task**, **Make decision**, **Copy id link**.
- **One reminder budget:** Circle reminders and decision reviews share one daily limit (default 3)
  with quiet hours, shown once across Mac and phone. The daily jot nudge is separate. Task due
  alerts are unchanged.
- **Ids link:** typing an id in a jot, task note or event panel links it when saved. Unlinking is
  an explicit ✕ on the link chip.
- **Where things live:** the Mac database is the record. The online engine (Always-on mode, the
  owner's mode) holds what the phone needs and runs Claude's background jobs. Phone features need
  Always-on mode.
- **Privacy:** Circle uses message metadata (who, when, channel, direction) and never stores message
  text. Message text reaches Claude only for a draft the owner asks for, or for Prospect signals
  (5 people at most, see 3).

---

## 0. Board (exists)

Unchanged, except: tasks can carry several tags (today one group, which becomes the first tag), and
the task's **notes** become a jot (J10).

---

## 1. Calendar — built, in review

**Trigger:** Google Calendar, two-way. **Authoritative spec:** `2026-11-16-calendar-design.md`.

| # | Feature |
|---|---|
| C1 | Day and week views mirroring every calendar of every connected account; on/off per calendar |
| C2 | Create, move, resize, rename, delete events in FloatBoard; changes go to Google |
| C3 | Tasks with a due date show on their day; a task and its own event stay in step (title, time) |
| C4 | A task reaches Google only when dragged onto a slot or "Add to calendar" |
| C5 | Event panel with Join and Open in Google; deleting a task deletes its own event, not vice versa |
| C6 | Bar shows the next or current meeting with Join |
| C7 | **Phone: planning summary** (changed, see below) |
| C8 | Settings: calendars, default account, time zone; main calendar works without reconnecting |
| C9 | Safety, always on (not a setting): offline edits wait and send later; a delete waits 10 s so Undo never touches Google; retries keep their order; an edit never overwrites a newer change made in Google |

**C7 (changed on the owner's request).** The phone does not repeat Google Calendar's day view (the
Pixel's own calendar does that). It shows a **planning summary** in three blocks: **Today**,
**Rest of this week**, **Next week**. Each block lists meetings and tasks due, one line each.
A recurring meeting appears **once per block** with a short label instead of every instance:
"Standup · weekdays 09:00", "1:1 · weekly Tue", "Board · monthly". The label is read once per series
from Google (the series' repeat rule) and cached.

**Later (needed by other areas, not built):** keep each event's guest list (email, reply status) and
meeting link; keep a small permanent record of events that a jot or decision links to.
**Not in v1:** invitations, month view, whole-series edits, moving events between calendars,
a "pause Google sync" switch (offer if wanted).

---

## 2. Jots — next

**Trigger:** the owner (typing or voice), task notes, and Fathom meeting recaps.
**Job:** one place for all thinking, findable by tags and search. **No folders.**
**Unit:** one saved capture = one jot (`J-n`) with text, tags, kind (**jot**, **task note**,
**meeting notes**), date added and updated, source.

| # | Feature |
|---|---|
| J1 | **Capture window** from anywhere (⌃⌥J) and ✎ on the bar: small and quiet, ⌘↩ saves, Esc closes and keeps the draft |
| J2 | **Voice:** on the Mac, macOS dictation in the capture window; on the phone, the keyboard's microphone. Nothing custom to build |
| J3 | **Phone:** opens to a writing box; captures made offline are kept and sent later; the **last 30 days of jots** can be read and searched on the phone |
| J4 | **Jots tab:** one list, newest first, today's meetings shown at the top of today; search; filter and sort by tag, kind, date added, date updated |
| J5 | **Tags:** the board's groups. Claude suggests tags after you save (✓/✗); an untagged jot shows as "untagged" |
| J6 | **Claude cleanup** (button on a jot): fixes grammar and structure only, never changes or removes substance. Shows **before and after** side by side; you choose "Use cleaned" or "Keep mine". The original is always kept in the jot's history |
| J7 | **Select text → right-click → Make task / Make decision**: opens the task or decision form already filled in from the selection (title, due date if mentioned, tags from the jot). Links back to the jot |
| J8 | **"Jot about this"** on a task opens the capture window linked to that task, with the task's tags |
| J9 | **Meeting notes:** every Fathom recap is saved automatically as a *meeting notes* jot holding Fathom's full summary and link, attached to its calendar event (`E-n`) by the meeting link and start time (code, not AI), with the tags of the tasks linked to that event (else suggested). Tasks linked to that meeting show these notes in their notes section. Fathom's suggested tasks are not suggested a second time |
| J10 | **Task notes are jots:** when a task's notes reach 10 characters, they are saved as a *task note* jot with the task's tags, linked to the task; later edits update that same jot (with history). Under 10 characters: no jot |
| J11 | **Daily nudge** at a chosen time (Mac notification and phone push), skipped on days already jotted; shows the day's finished tasks as a prompt |
| J12 | **Daily file copy** to `~/Code/Resources/braindumps/daily/YYYY-MM-DD.md` (folder in Settings), dated by the app's time zone, rewritten when that day's jots change |
| J13 | **Online copy, 30-day buffer:** the engine keeps each jot for the phone for 30 days **counted from when the Mac has saved it**. A jot the Mac hasn't taken in yet is never removed, however long the Mac is off. The Mac keeps everything forever |
| J14 | Edit and delete with history and Undo |

**Not in v1:** rich text, attachments, a prompt on every ticked task, automatic task suggestions
from ordinary jots (the owner makes tasks by right-click; Fathom's own suggestions stay).

---

## 3. Circle — after Jots (replaces the keep-in-touch project)

**Trigger:** who you exchange messages and meetings with, plus people you add.
**Job:** know who matters, when you last really talked, who is due, and what changed for them.

**Tiers** (one per person) and **default intervals**, changeable per person:
**Family 1 month · Close friend 2 weeks · Network 3 months.**
**Tags** (any number): **Investor** (on Family, Close friend or Network; sets the interval to at most
3 months) and **Prospect** (on Close friend or Network, never Family; someone being tested as a
closer relationship). Plus the shared tags.

**Every channel is checked** for "last talked":

| Channel | Incoming | Outgoing | How |
|---|---|---|---|
| WhatsApp | ✓ | ✓ | the Mac app's database (1:1 chats) |
| Gmail | ✓ | ✓ | inbox plus **Sent folder** (who and when only; owner approved) |
| Outlook | ✓ | ✗ | extension sees incoming only → "heard from" |
| WeChat | ✓ | ✗ | notifications only → "heard from" |
| Calendar | — | — | a past meeting both accepted counts as talked |
| Manual | | | one tap **"I contacted them"** for calls, in person, or channels without outgoing |

| # | Feature |
|---|---|
| P1 | **Contacts manager** (the Circle tab): everyone in one list; search; filter by tier and tag; sort by name, last talked, due date; select several to change tier or tags at once; merge two people, or split a wrong merge |
| P2 | **Add a contact** (button, or right-click a name in a jot or task): a short form — name, tier, tags, how you know them, company and role, handles (phones, emails, WhatsApp, WeChat, LinkedIn URL), birthday, language, notes; plus *firm and focus* when tagged Investor and *purpose and stage* when tagged Prospect. Filled in as far as possible from messages, email signatures and the LinkedIn export; you confirm |
| P3 | **Where people come from:** manual add; suggested from 1:1 conversations with replies both ways; suggested from Google Contacts and the LinkedIn connections export (import as suggestions, never in bulk) |
| P4 | **Same person, many handles:** merged automatically only on an exact phone or email match; anything else is a suggestion. Every merge can be split |
| P5 | **Contact dates** (code): *last talked* (two-way or a meeting together) and *last heard from* (incoming only) |
| P6 | **Due this week:** one list of people past their interval, inside the shared reminder budget. Each due person can become a task ("Message P-n") and, optionally, a short calendar slot to do it. ✗ or snooze pushes them back one interval. It clears itself when an outgoing message, a meeting or "I contacted them" is seen |
| P7 | **Context nudges:** birthday; "you meet P-n next week" |
| P8 | **Timeline:** per person, recent exchanges (channel, date, direction), meetings, jots, tasks and decisions, each opening its source. No message text stored |
| P9 | **Draft a message** (on request): a short draft in the owner's voice and usual language, from notes and the last few messages; never invents a reason; one tap opens WhatsApp or Gmail with it. Never sent automatically |
| P10 | **Active prospects (at most 5 at a time):** a purpose (career, investing, venture, learning) and a stage moved by hand (*want to meet → in touch → regular*, or *dropped*). Only for these, Claude also spots **promises and follow-up dates** in your messages with them, and shows them on the card |
| P11 | **Updates (people intelligence)** for Investor- and Prospect-tagged people (others on request): job and title changes from the **LinkedIn connections export** (you download it monthly; FloatBoard reminds you and compares); **UK Companies House** directorships and resignations; **news** for that person or firm (Google News feed); posts from their **blog / Substack / company news** page if they have one. Shown on the card as "What's new" |
| P12 | **LinkedIn posts:** not read automatically (it breaks LinkedIn's terms and risks your account). The card links to their profile and reminds you to turn on LinkedIn's own "notify me about posts" for the people you most want to follow |
| P13 | **Chinese contacts:** no automatic sources exist that can be used safely from the UK; the card keeps a "last checked" date and links for a manual look |

**Not in v1:** paid enrichment services, X/Twitter, scoring relationships, pipelines beyond the
prospect stages, group chats.

---

## 4. Decisions — after Circle

**Trigger:** jots only (including meeting notes and task notes). Never email.
**Job:** a **recorder and screener** of decisions already made, so they can be reviewed. It is not
a tool for making decisions.
**What counts:** a commitment to a course of action by the owner or a group the owner is in. Not
intentions or to-dos.

| # | Feature |
|---|---|
| D1 | **Weekly screening** (Sunday, with the weekly review): Claude reads the week's new and edited jots once and **records** the decisions it finds directly (no confirm step), each marked "found by Claude"; unsure ones go to **Maybe** |
| D2 | **Make decision by hand:** select text anywhere → right-click → **Make decision** opens a 4-field form already filled in: *decision*, *why* (only from the text, otherwise "not recorded"), *expected outcome*, *confidence* (low/medium/high); alternatives optional |
| D3 | **Card:** decision, date it was made (the source's date), exact quote and source `J-n` (labelled "meeting notes" when it came from Fathom), why, expected outcome, confidence, type (operational / strategic / investment), tags, people involved. The quote is kept even if the source is later edited or deleted |
| D4 | **Weekly review page:** this week's recorded decisions (each with "Not a decision" and, for screened ones, a one-line prompt to add expected outcome and confidence), Maybe items, and due reviews |
| D5 | **Status:** decided / tentative / reversed / superseded; a decision that seems to replace an earlier one is suggested as superseding it |
| D6 | **Reviews:** 30 days (operational), 90 (strategic), 180 (investment), once each, inside the reminder budget. The review shows the original card with its expected outcome beside it and asks "what happened?" and "was the thinking sound?". The answer is saved as a jot linked to the decision; right-click in it → Make task. Snooze or turn off per decision |
| D7 | **Decisions → people:** a decision that names someone in Circle links to them (their card shows it); it can suggest a "tell P-n" or "ask P-n" task; a review can suggest "check in with P-n about how it went" |
| D8 | Search and filters (tag, type, status, person) |

**Not in v1:** templates, outcome statistics, extraction from email.

---

## 5. Resolutions — last

**Trigger:** the owner.
**Job:** longer-term direction: a **5-year** picture, **yearly** goals and **quarterly** goals, kept
light so it doesn't become a heavy planning system.

| # | Feature |
|---|---|
| R1 | **Three levels:** 5-year (a few lines of text), this year (up to 5 goals), this quarter (up to 3 goals). Each goal is an item `R-n` with tags |
| R2 | **Link work to goals:** a task, jot or decision can be linked to a quarterly or yearly goal (picker, or type `R-n`). A quarterly goal can sit under a yearly goal, and a yearly goal under the 5-year picture |
| R3 | **Progress without scoring:** each goal shows its linked tasks done / open, recent jots and decisions. No percentages, no points |
| R4 | **Quarterly review** (nudge at quarter end): for each goal, "kept / changed / dropped" and a short note (saved as a jot); then set next quarter's goals. **Yearly review** at year end the same way, and a look at the 5-year picture |
| R5 | The board can be filtered by a goal (shows only its tasks) |

**Not in v1:** OKR scores, habit tracking, life-area wheels.

---

## 6. Links between the areas

All links live in the one general `links` table (built with Calendar). Each link has a **kind** and
records who made it (auto / suggested / manual).

| Kind | Meaning | Example |
|---|---|---|
| `own-event` | a task's own Google event | T-12 → E-40 (built) |
| `related` | about the same thing | T-12 ↔ E-41, J-7 ↔ P-3 |
| `source` | made from | T-15 from J-7; D-2 from J-9 |
| `notes-of` | notes belong to | J-9 → E-41; J-20 → T-12 (task note) |
| `review-of` | a review of a decision or goal | J-30 → D-2; J-44 → R-3 |
| `supersedes` | replaces | D-5 → D-2 |
| `serves` | work towards a goal | T-12 → R-3; R-3 → R-1 |

| Link | Kind | Made |
|---|---|---|
| Task ↔ its own event | own-event | auto (built) |
| Task ↔ meeting | related | manual by id (built) |
| Meeting notes → event | notes-of | auto by meeting link + start time; otherwise suggested; changeable |
| Task note → task | notes-of | auto (J10) |
| Selection → task / decision | source | manual (right-click) |
| Jot ↔ task ("Jot about this") | related | manual |
| Jot ↔ person | related | suggested when a jot names a known person; manual by `P-n` |
| Event ↔ person | related | auto when a guest's email matches one person exactly |
| Task ↔ person | related | auto when the task came from their message or is a Circle reminder; manual otherwise |
| Decision → jot | source | auto, always |
| Decision ↔ person | related | auto when the decision names a Circle person; suggested otherwise |
| Review jot → decision / goal | review-of | auto |
| Decision → decision | supersedes | suggested |
| Task / jot / decision → goal | serves | manual |

Unlinking is manual and undoable. Deleting an item hides its links (Undo restores them) and never
deletes the other item, except a task's `own-event`. Merging two people moves their links.

**Hubs:** a person card and a meeting panel each show everything linked to them.
**One meeting, one pass:** Fathom recap → meeting notes jot on the event → shown in linked tasks →
screened for decisions that week → guests' "last talked" updated.

---

## 7. AI jobs (all Haiku) and judgement-call flags

The owner's rule: Haiku only, used efficiently (new items only, batched); anything Haiku must judge
probabilistically is flagged here for the owner.

| Job | Area | Input | Flag |
|---|---|---|---|
| Suggest tags after a jot is saved | Jots | one jot | low (✓/✗) |
| Cleanup: grammar and structure only | Jots | one jot, on request | low (before/after confirm) |
| Fill the task / decision form from a selection | Jots, Decisions | the selection + its jot | low (owner edits the form) |
| **Find decisions in the week's jots** | Decisions | new/edited jots, weekly batch | **⚑ judgement: what counts as a decision, and its type; recorded without confirm, so mistakes show up as noise. Mitigations: Maybe list, "Not a decision" teaches the rulebook, weekly batch only** |
| Suggest "supersedes" | Decisions | new decision + same-tag earlier ones | **⚑ judgement; suggestion only** |
| Fill the add-contact form | Circle | that person's recent message headers and signatures | low (owner confirms) |
| **Spot promises and follow-up dates** | Circle | message text, **5 active prospects only** | **⚑ judgement and message text leaves the Mac; limited to 5 people** |
| **Is this news about this person?** | Circle | news headline + person's name, firm | **⚑ same-name confusion; shown as "possible" until opened** |
| Draft a message | Circle | notes + last few messages, on request | low (never sent automatically); note: user-facing text on Haiku by owner's choice |

Done by code, not AI: last-contact dates, intervals and due lists, matching meeting notes to events,
matching guests and handles to people, exact-match merges, LinkedIn export changes, Companies House
appointments (matched by name plus birth month/year; uncertain matches are suggestions), recurring
meeting labels, the 30-day buffer.

---

## 8. Owner answers recorded (17 Nov 2026)

1. Decisions are recorded without confirmation; jots are the only source; screening is weekly.
2. Weekly review: yes, as the Decisions screening page (D4), also listing Circle's due list.
3. Gmail Sent folder: yes.
4. Meeting notes link to their meeting by id and appear in the linked tasks' notes (J9).
5. Investor and Prospect are tags, not tiers (Investor allowed on Family; Prospect not).
Also: Circle (not People); phone shows a planning summary; no folders in Jots; Resolutions added;
Haiku only.

## 9. Open questions (each with a suggested default)

1. **Several tags per task** (needed for "same standard as jots"): today a task has one group.
   *Default: allow several; the first one keeps the card's colour.*
2. **Six tabs** is a lot next to the board. *Default: keep six; Resolutions is a quiet tab you open
   at review time.*
3. **Prospect signals send message text to Claude** for up to 5 people. *Default: yes, only for
   active prospects, and the card says so.*
4. **News watch per person** costs nothing but can be noisy. *Default: on for Investor and Prospect
   tags only.*
