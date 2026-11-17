# Decisions design: recorder and screener of decisions already made

Date: 17 Nov 2026 · Branch `decisions` · Mac schema **15** · engine migration **0042**
Requirements: `2026-11-17-assistant-features.md` §4 (D1–D8), §6, §7, §9 (Decisions, Reminders and the weekly review,
Modules), §10 (More › Decisions). Interfaces: `2026-11-17-foundation-design.md` (used, not changed; extensions listed in §9).

Decisions is a **recorder**: it finds decisions already made in jots and keeps them for review. Nothing here helps make a
decision. Jots are the only source (never email); the Jots features are built on another branch, so this area reads and
writes jots only through `JotStore` and links.

## 1. Data (Mac, schema 15)

```sql
CREATE TABLE decisions(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    text TEXT NOT NULL,                       -- the decision, one line
    quote TEXT NOT NULL DEFAULT '',           -- exact words from the source; kept when the source changes or goes
    source_item TEXT NOT NULL DEFAULT '',     -- 'J-7' (or the item the selection came from); '' none
    source_kind TEXT NOT NULL DEFAULT '',     -- the jot's kind then: jot / task_note / meeting_notes ('' not a jot)
    recorded REAL NOT NULL,                   -- when the source was written (its date added); reviews count from here
    decided TEXT NOT NULL DEFAULT '',         -- 'YYYY-MM-DD' only when the text says so; '' = unknown
    why TEXT NOT NULL DEFAULT '',             -- '' = not recorded
    expected TEXT NOT NULL DEFAULT '', expected_added REAL,      -- *_added set when added after recording ("added later")
    confidence TEXT NOT NULL DEFAULT '', confidence_added REAL,  -- low / medium / high / ''
    alternatives TEXT NOT NULL DEFAULT '',
    type TEXT NOT NULL DEFAULT 'operational', -- operational / strategic / investment
    status TEXT NOT NULL DEFAULT 'decided',   -- decided / tentative / reversed / superseded / maybe
    found_by TEXT NOT NULL DEFAULT 'you',     -- you / claude
    source TEXT NOT NULL DEFAULT 'typed',     -- item standard: typed / phone / meeting / claude
    review_state TEXT NOT NULL DEFAULT 'scheduled',  -- scheduled / off / done
    review_due REAL, review_ask_after REAL, reviewed REAL,
    not_decision INTEGER NOT NULL DEFAULT 0,  -- "Not a decision" (also deleted=1)
    added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX decisions_recorded ON decisions(recorded);
-- Each jot version screened once (version = SHA-256 of the text, first 16 hex).
CREATE TABLE decision_screened(jot_id INTEGER NOT NULL, version TEXT NOT NULL, screened REAL NOT NULL,
    found INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(jot_id, version));
-- Suggestions shown on a card: supersedes D-n (Haiku ⚑, suggestion only), tell / ask P-n (Haiku, low).
CREATE TABLE decision_suggestions(id INTEGER PRIMARY KEY AUTOINCREMENT, decision_id INTEGER NOT NULL, kind TEXT NOT NULL,
    target TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open', created REAL NOT NULL,
    UNIQUE(decision_id, kind, target));
-- "Not a decision" examples waiting to go into the Decisions rulebook (applied = when written into the connector's copy).
CREATE TABLE decision_examples(id INTEGER PRIMARY KEY AUTOINCREMENT, decision_id INTEGER NOT NULL, text TEXT NOT NULL,
    created REAL NOT NULL, applied REAL, connector TEXT NOT NULL DEFAULT '');
```
Tags: `item_tags` (`D-n`), copied from the source item's tags when recorded. People and sources: `links`
(`D-n` source `J-n`, auto; `D-n` related `P-n`, auto; `J-n` review-of `D-n`, auto; `D-n` supersedes `D-m`, suggested).
`docs/data-model.md` and `Tests/Fixtures/schema-v15.json` are updated.

## 2. Core (FloatBoardCore/Decisions/)

| File | What |
|---|---|
| `DecisionStore.swift` | `Decision`, `DecisionType`, `DecisionStatus`, `Confidence`; `DecisionStore(store:)`: `record(_ draft:, now:)`, `update`, `setStatus`, `notADecision(_:)` / `undoNotADecision`, `delete` / `undoDelete` (hide/unhide links), `decision(_:)`, `decisions(filter:)`, `answerReview`, `snoozeReview`, `setReviewOn`, `register()` (ItemCatalog `.decision`, GlobalSearch `.decision`, weekly review sections) |
| `DecisionPeople.swift` | names and aliases from `PeopleStore` found in a text by code (whole words, case and accents ignored) |
| `DecisionScreening.swift` | the weekly batch: which jot versions are due, the request, applying the answer (record / Maybe / reference / skip), marking each version screened |
| `DecisionReviews.swift` | review dates (30 / 90 / 180 days from *recorded*), the budget requests, the review answer as a jot, the weekly sections |
| `DecisionRulebook.swift` | "Not a decision" examples → the Decisions rulebook copy (via `saveConnectorSettings`) |
| `DecisionPhone.swift` | the copy sent to the engine for the phone, and applying the phone's actions |

**Two dates (§9).** *recorded* = the source jot's date added (a selection with no source: now). *decided* = only what
the text says (Haiku returns it with the words that say so; code keeps it only when it is a real date not after
*recorded*), else "unknown". Reviews count from *recorded*.

**Predictions never invented (§9).** Screening never fills expected outcome or confidence. When the owner adds them to a
screened decision, `expected_added` / `confidence_added` are set and the card shows "added later". In the D2 form the
owner fills them (Haiku may prefill only from the selected text; the owner edits before saving), so they are not "later".

**Statuses (D5).** decided / tentative / reversed / superseded, set by hand; *maybe* is the screening's unsure list
(Record = decided; Not a decision = dismissed). Accepting a supersedes suggestion links `D-new supersedes D-old`
(suggested) and sets the old one to superseded.

## 3. D1 weekly screening (⚑ judgement; §7 mitigations built exactly)

- **When:** weekly batch only. Due from **Sunday 17:00** (app zone, an hour before the review nudge so the page is
  ready) once per week; a catch-up runs at the next chance if the Mac was off (timer every 10 min + the Sunday nudge
  hook + opening the weekly review). Never per jot, never on save. Builder's call: 17:00.
- **What:** live jots of any kind whose *current version* has not been screened and that were added or updated since the
  last screening (first run: the last 7 days). A version is the text's SHA-256; each `(jot, version)` is screened once
  (`decision_screened`), so repeating a run is harmless and an edit is screened as a new version.
- **References, not new decisions (§9):** a jot with a `review-of` link, or that names `D-n` ids, is sent with those
  decisions' texts as "earlier decisions: references". After the answer, code drops any found decision whose quote or
  text matches an existing decision's (normalised) or an earlier decision from the same jot. A review jot is still read
  (a review may record a genuinely new decision), but quotes of the old one are references.
- **The call:** Mac → engine `POST /v2/decisions/screen`, ≤ 10 jots / ≤ 40,000 characters per request (one Haiku call),
  sequential. Rulebook = the owner's copy `rulebook_decisions`, else the built-in `engine/src/skills/decisions.md`.
- **Recorded without confirm**, marked "found by Claude" (`found_by='claude'`, `source='claude'`). `sure=false` →
  **Maybe**. A quote that is not found word-for-word in the jot (whitespace ignored) → Maybe too (code check).
  Type (operational / strategic / investment) is Haiku's call (part of the ⚑).
- **An unreadable answer** for a jot (refusal, bad JSON) leaves that version unscreened (tried again next week) and
  writes one Activity line. No engine or no Claude key: one Activity warning, nothing marked.
- **"Not a decision"** (Mac weekly review, card, phone): the decision is dismissed (`not_decision=1, deleted=1`, links
  hidden, Undo for 8 s) and an example line is queued: `- Not a decision: "<quote, ≤ 200 chars>" (<type>)`. It is appended
  to the connector's `rulebook_decisions` copy (starting from the built-in text when the copy is empty, as RulebookSync
  stores it) under the heading `## Examples you marked`, by the existing rulebook mechanism (versioned, restorable). No AI
  call. Undo before it is written removes it.

## 4. D2 Make decision (selection hook)

`SelectionActions.register(id: "make_decision", title: "Make decision", module: .decisions)`. The form
(`MakeDecisionForm`) opens at once filled by code (decision = the selection's first line, why = "not recorded",
confidence unset, type operational), then `POST /v2/decisions/fill` (Haiku `fill_form`, low flag) fills the fields the
owner has not touched: *decision*, *why* (only from the text, else "not recorded"), *expected outcome*, *confidence*,
*type*, *alternatives* (optional). Four fields shown large; type and alternatives in a smaller row. Save records it
(found by you), links `source` to the selection's item (§9: a selection outside a jot uses its own item; none: no link),
copies that item's tags, matches people. The form works with no engine (code fill only).

## 5. D3 card, D8 Decisions tab

Tab = list on the left (search box; filters: tag, type, status, person; sort: date recorded, date updated, tag; Maybe
and dismissed are separate filters), card on the right: decision, recorded and decided dates, the quote in a box with
`J-n` (or "meeting notes" when the source was Fathom notes) and "source edited" / "source deleted" when it changed, why,
expected outcome and confidence (with "added later"), type, status, tags, people, review line (due date, Snooze 7 days,
Turn off), suggestions (supersedes ✓/✗; tell/ask ✓ makes the task / ✗), link chips, past reviews. Global search
registers `.decision` (text, quote, why); opening a hit selects it in the tab.

## 6. D4 weekly review, D6 reviews

Sections (foundation registry): `decisions.recorded` (10) "Decisions recorded this week" (each: Not a decision; screened
ones without expected outcome or confidence show "Add expected outcome and confidence" → the card), `decisions.maybe`
(20) "Maybe" (Record / Not a decision), `decisions.reviews` (30) "Decision reviews due" (Review → the review sheet).
Rows with buttons need a row view: foundation extension `WeeklyReviewRows` (§9).

**Reviews:** due = recorded + 30 / 90 / 180 days (operational / strategic / investment), once each. A 15-minute timer asks
the shared budget (`ReminderKind.decisionReview`) for each due review whose `review_ask_after` has passed: granted or
duplicate → ask again tomorrow if still unanswered; deferred → ask from `until`. Snooze = due + 7 days; Turn off per
decision. The review sheet shows the original card with its expected outcome beside it and asks **What happened?** and
**Was the thinking sound?**; the answer is saved through `JotStore.create` as a jot (`Review of D-n · <decision>` then
the two answers), linked `review-of` (auto), and the decision is marked reviewed. Text in the sheet and in saved reviews is
`SelectableText(Editor)` so right-click → Make task works (source: the decision while typing, the review jot after).
For each person linked to the decision the sheet offers **Check in with <name> about how it went** (makes a task; code).

## 7. D7 people

By code: every live person's name and aliases (`PeopleStore.people()`) looked for as whole words in the decision text,
quote and why (case and accents ignored, ≥ 2 letters). A match links `D-n related P-n` (auto). No AI.
**Tell / ask** (Haiku `tell_ask`, low): for decisions with linked people, batched after each screening run (new
decisions only) and once after Make decision. Suggestions are shown on the card (✓ makes "Tell <name>: …" / "Ask
<name> …" as a task linked to the decision and the person; ✗ dismisses). Never made automatically.

**Supersedes** (Haiku `supersedes`, ⚑ suggestion only): new decisions (this run) with the same tags as earlier live
decisions (≤ 10 most recent per new one) are sent in one batch; an answer naming an id not in the list is ignored.

## 8. Engine (migration 0042) and phone

```sql
ALTER TABLE settings ADD COLUMN rulebook_decisions TEXT;
CREATE TABLE decision_copies (user_id TEXT PRIMARY KEY, data_enc TEXT NOT NULL, updated TEXT NOT NULL);
CREATE TABLE decision_actions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, client_id TEXT NOT NULL, device_id TEXT NOT NULL,
  decision TEXT NOT NULL, action TEXT NOT NULL, payload_enc TEXT, made_at TEXT NOT NULL, created TEXT NOT NULL,
  taken INTEGER NOT NULL DEFAULT 0, UNIQUE(user_id, client_id));
```
Routes (`src/routes/decisions.ts`, `src/phone/decisions.ts`):
- `POST /v2/decisions/screen | fill | supersedes | tell-ask` (user key; Haiku, metered as jobs `decisions`, `fill_form`,
  `supersedes`, `tell_ask`, all `DEFAULT_MODEL` haiku, `COLUMN` null). Skipped (409) while `settings.modules` says
  Decisions is off. Builder's call: a `NULL` modules row (the Mac only engine never receives a board) does not block, because
  the Mac checks its own switch before asking.
- `rulebook_decisions` in `/v2/settings` and `/v2/rulebook` (key `decisions`, name "Decisions"); `RulebookSync.keys` gains it.
- `PUT /v2/decisions` (Mac): the phone's copy, encrypted, ≤ 300 decisions. `GET /v2/decision-actions`,
  `POST /v2/decision-actions/ack` (Mac).
- Phone: `GET /app/api/decisions`, `POST /app/api/decisions/action` (`review` {happened, sound} or `not_decision`; own id,
  made_at; a repeat is applied once; text encrypted at rest).
- Phone screen (More › Decisions): `files/decisions.client.js`, inserted into `app.client.js` at a marker (same pattern as
  `SYNC_JS`), pure parts tested on their own. Sections: Reviews due (Answer review → sheet with the card, expected outcome,
  two boxes), This week (Not a decision), Maybe (Not a decision), Earlier (read-only). Actions queue offline in
  localStorage and are sent when online. Shown only while Decisions is on (foundation `moreEntries`).

## 9. Foundation extensions (separate commits titled "Foundation: …")

1. `WeeklyReviewRows` (app): a section id → row view registry used by `WeeklyReviewView` (falls back to the plain row).
2. `ConnectorClient.call` made internal so area files can add engine calls in their own extension files.
3. `ConnectorSync.phoneTick` runs registered `ConnectorSync.phoneHooks` after the board push (Decisions registers its
   copy push and action pull).
4. `schema_version_is_12` check reads `>= 12`.

## 10. Left out, and why

- Outcome statistics, templates, extraction from email (features: not in v1).
- Screening per jot or on save: the owner chose a weekly batch.
- AI for people matching: code only (§9).
- Phone editing of decisions: the phone is read-only plus the two actions (§10).
