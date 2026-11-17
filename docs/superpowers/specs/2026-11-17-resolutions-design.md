# Resolutions: design

Date: 17 Nov 2026 · Branch `resolutions` · Status: built on the branch, for review
Requirements: `2026-11-17-assistant-features.md` §5 (R1–R5), §6 Links (`serves`, `review-of`), §9 Resolutions and
Reminders rules, §10 Phone (More › Resolutions). Interfaces used: `2026-11-17-foundation-design.md`.
Numbers: Mac `DB.schemaVersion` **16**, engine migration **0043 (not needed, not written: see §6)**.

Plain words: a **goal** is one line of direction, `R-n`. There are three **levels**: the **five-year picture** (a few lines
of text), **yearly** goals (up to 5 per year) and **quarterly** goals (up to 3 per quarter). Each goal belongs to one
**period** (Q1 2027, 2027, 2026–2030). Work (tasks, jots, decisions) is linked to a goal with a `serves` link.

## 1. Data (schema 16)

```sql
-- Goals (R-n). level: five_year | year | quarter. period: '2026-2030' | '2027' | '2027-Q1'.
-- status: active, or how its review ended: kept | changed | dropped (a reviewed goal is never edited again).
-- carried_from: the goal of the previous period this one continues (a kept or changed goal at rollover).
CREATE TABLE resolutions(
    id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, period TEXT NOT NULL, title TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'active', carried_from INTEGER,
    position REAL NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'typed',
    added REAL NOT NULL, updated REAL NOT NULL, reviewed REAL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX resolutions_period ON resolutions(level, period);
-- Earlier wordings of a goal or of the five-year picture (edits while active), oldest first.
CREATE TABLE resolution_history(id INTEGER PRIMARY KEY AUTOINCREMENT, goal_id INTEGER NOT NULL, title TEXT NOT NULL,
    notes TEXT NOT NULL, at REAL NOT NULL);
CREATE INDEX resolution_history_goal ON resolution_history(goal_id);
```

No new link table: every relation uses the foundation's `links`:
- **Work → goal**: `serves`, subject = the task / jot / decision (`T-12 serves R-3`), made manual.
- **Goal → parent goal**: `serves`, subject = the child (`R-3 serves R-1`). One parent per goal.
- **Review note → goal**: `review-of`, subject = the jot, made auto.
- Tags: the foundation's `item_tags` (`R-n` rows, one primary).

`resolution_history` is the one table beyond `resolutions` (builder's call: the five-year picture is edited in place at
the yearly review and its earlier text must not be lost; ordinary goals use the same table for edits made while active).

## 2. Rules (core, `FloatBoardCore/Items/Resolutions.swift`)

| Rule | How |
|---|---|
| Level + period per goal (§9) | `GoalLevel` + `GoalPeriod` (key, title, `DateInterval` in `AppTime`). `GoalPeriod.current(level, now)`, `.next`, `.contains(_:)`. |
| Limits (R1) | Live goals in one period, any status: five-year 1, year 5, quarter 3. Over the limit: refused with a sentence. Builder's call: reviewed (kept/changed/dropped) goals of the period count, because a period's set of goals is what was reviewed. |
| Five-year picture | One `five_year` goal; its period is the five calendar years from the year it is written (`2026-2030`). Its text is `title` (a few lines). Builder's call: it is edited in place (old text to history), never rolled over; a new picture can be written only after the old one's period ends. |
| Parent links (R2, §9) | `setParent(child, parent)`: quarter → year, year → five-year only; the parent's period must contain the child's; one parent (old `serves` to another goal removed); **no loops** (walking up from the parent must never reach the child — the level rule already forbids it, the walk guards the table against links made elsewhere). Refusals are sentences. |
| Work links (R2) | `linkWork(item, goal)`: item is T, J or D (D by id, so it works once Decisions merges); goal is a live, **active** yearly or quarterly goal. Typed `R-n` in a task's notes, a jot or (later) a decision's text links `serves` instead of `related` (§4 Foundation extension). Unlink: the chip's ✕ (Undo) as for every link. |
| Progress (R3) | `progress(goal)`: tasks done / open (live, not withdrawn), recent jots (newest first, at most 5) and decisions, all from `serves` links. **A yearly goal counts its own and its quarterly goals' (any status) items, each once** (set union by id). No percentages. |
| Rollover (R4, §9) | `review(goal, outcome, note, newTitle)`: the goal gets `status` kept / changed / dropped and `reviewed`; it is never edited after (edits refused). **Kept** → a new goal for the next period with the same title, notes and tags; **changed** → the same with the new title; **dropped** → nothing new. The new goal has `carried_from` = old id. Parent: the old parent if it still covers the new period, else the old parent's own continuation if that does, else none (builder's call). Open tasks that served the old goal also serve the new one (auto); done tasks, jots and decisions stay with the reviewed version only, which "stays as it was". |
| Review note (R4) | A non-empty note is saved as a jot through `JotStore.create` (kind jot, source typed), text "Review of “<title>” (Q4 2026): kept" + the note, then linked `review-of` (auto) to the goal. The id is not written in the text (a typed id would make a manual link first, which an auto link never replaces). |
| Delete | Soft; `hideLinks` / `unhideLinks` inside the same transaction (foundation rule). A deleted parent leaves its children without a parent until Undo. |

## 3. Nudges (R4, §9 "outside the budget, at most one per period")

`ResolutionNudges.due(store, now)` → the reviews due now: a **quarter** review when the current time is in the last 7 days
of a quarter or the first 21 days of the next (builder's call), and the ending quarter has an active goal. The **yearly**
review the same for the year (with the year's active goals, or the five-year picture's period ending). Each kind fires at
most once per period: the period key is saved in `meta` (`resolutions_nudged_quarter` / `_year`). Not inside quiet hours
(the budget's settings; the nudge waits for their end) and not while the module is off. Q4 = year end: one notification
covers both ("Quarter and year review"). Shown by the app's existing minute ticker (`AssistantTicker` calls
`ResolutionNudges` through a hook registered by the area: `ResolutionsTicker`), as a Mac notification; the Resolutions tab
shows a "Review Q4 2026" banner while a review is open. Builder's call: Mac only (reviews are done on the Mac, §10).

## 4. Foundation extension (separate commit "Foundation: …")

`MentionKinds.register(_ target: ItemKind, _ f: (Store, ShortID, ShortID) -> ItemLinkKind?)` in `Board/Links.swift`:
`linkMentionsRow` asks the registered rule for the target's kind and falls back to `related`. Resolutions registers
`.resolution`: a T/J/D typing an active yearly or quarterly `R-n` → `serves`; anything else → `related`. No signature
changes; with nothing registered the behaviour is exactly as before.

`BoardExtras` gains `goals: [BoardGoal]?` (default nil, so other callers compile unchanged) and the body key `goals`.

## 5. Mac app

**Resolutions tab** (`FloatBoard/Resolutions/`): one scrolling page.

```
┌ Five-year picture · 2026–2030 · R-1 ──────────── [Edit] ┐
│ Run a small, profitable studio; live half the year near family … │
└───────────────────────────────────────────────────────────┘
 2026 · yearly goals (2 of 5)                         [+ Add]
  R-2  Ship the assistant                 under R-1   ▸
       4 done · 2 open · 1 jot · 1 decision   [Show on board]
 ‹ Q4 2026 › · quarterly goals (1 of 3)               [+ Add]
  R-5  Jots and Circle live               under R-2   ▸
       2 done · 1 open                         [Show on board]
 [Review Q4 2026]  ← banner while a review is due
```

A goal row expands to: notes, tags (chips + menu), parent menu, its linked items (the foundation's `LinkChips` with ✕ /
Undo), recent jots and decisions, and "Link work" (type `T-12`, `J-7` or `D-3`). Reviewed goals show their outcome
("kept → R-9") and are read-only. The quarter stepper ‹ › moves between quarters (next quarter to set goals ahead).

**Review sheet**: each active goal of the ending period: Kept / Changed / Dropped, a new wording when Changed, a short
note. "Save review" applies them all; then the next period's goals are shown with "+ Add" (set next quarter's goals).
The yearly review also shows the five-year picture with Edit.

**Goal picker** (`GoalPicker(item:)`): a "Serves a goal" menu of active yearly and quarterly goals (this and next
period), shown in the task editor under the links; Jots and Decisions can drop the same view into their editors.

**Board filter (R5)**: `UIState.goalFilter`; "Show on board" sets it and opens the Board. The columns then show only the
goal's tasks (for a yearly goal also its quarterly goals' tasks, each once); a chip above the columns says
"Tasks of R-2 · Ship the assistant ✕". Board search still works inside the filter.

**Search and ids**: `ItemCatalog.register(.resolution)` (title, dates, deleted), `GlobalSearch.register(.resolution,
module: .resolutions)` (title and notes), `GlobalSearchOpen.handlers[.resolution]` opens the tab.

## 6. Phone (§10 More › Resolutions) and engine

The Mac adds `goals` to the board copy while the module is on: this quarter's goals (at most 3), each
`{id, title, period, parent, done, open, tasks}` (`tasks` = ids of its open tasks, at most 50). The engine validates them
(`parseGoals`, strict like `reminders`), keeps them in the encrypted board copy (no D1 column needed, so **no migration
0043** — builder's call) and returns them from `GET /app/api/board`. The phone's More › Resolutions opens a screen with the
quarter's title and one card per goal: id, title, "under R-1 …", "2 done · 3 open" and the open tasks' titles from the
board. Read-only (setting goals stays on the Mac). Code in `files/resolutions.client.js` (pure functions, tested in
vitest), inserted at a `/*@RESOLUTIONS_JS@*/` marker; the screen is a `<main id="goals">` in `page.ts`.

## 7. AI jobs

None. Everything here is counting and linking by code. ⚑ None found that would need Haiku.

## 8. Left out (and why)

- OKR scores, habit tracking, life-area wheels (features §5 "Not in v1").
- Phone editing of goals or reviews (§10: setting things up stays on the Mac).
- A phone push for the review nudge (builder's call: the review is done on the Mac; the nudge is a Mac notification).
- Weekly review section for goals (not asked for; the quarter/year reviews are their own).
