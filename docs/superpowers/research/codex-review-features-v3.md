Reviewed v3, both research notes, architecture, and relevant code. Section 8 decisions treated as fixed. No files changed.

**Critical**

- **J10, J14, §6 — Task notes have two writable representations.** Editing the jot, shortening below 10 characters, deleting either item, and concurrent phone edits have undefined effects. **Fix:** one canonical text/revision, one task-note jot per task, both editors using the same write path; make 10 characters a creation threshold only. Define deletion, tag propagation, migration, and conflict handling. Keep displayed meeting notes separate.

- **J3, J13 — Receipt of an item is insufficient for safe expiry.** A phone edit arriving near day 30 could be deleted after the Mac acknowledged an earlier revision. “Last 30 days” also differs from 30 days after receipt. **Fix:** acknowledge durably saved revisions; never purge pending edits/deletions; specify when expiry restarts, phone-cache eviction, and re-upload of edited archived jots. Unreceived captures can remain online indefinitely—state that consequence explicitly.

- **Ground rules privacy, P2, §7 — The privacy promise contradicts contact autofill.** Signatures are message text, yet autofill sends them to Claude outside the two stated exceptions. Existing task screening also uploads/stores message text. **Fix:** explicitly scope the promise to Circle; remove signature input or document an additional exception. Specify transient handling, logging, retained extracted signals, and what happens when a Prospect becomes inactive.

**Important**

- **§0, J5, §9.1 — Multiple tags change more than colour.** Board placement, ordering, filtering, totals, connector proposals, and phone payloads currently assume one group. **Fix:** define tag membership plus explicit primary tag; migrate existing groups; specify deduplicated counts and filter semantics. Give Investor/Prospect stable identities and enforce their constraints across bulk edits, imports, and suggestions.

- **C1–C9, §6, J9 — “Built” dependencies are not present in this checkout.** The current code lacks the described general links/calendar-cache schema; the Calendar design’s links table also lacks `kind`. **Fix:** identify the prerequisite Calendar build and required migration. Move guest retention, stable event records, and Fathom meeting metadata into explicit prerequisites for Jots/Circle.

- **§6 versus D2, R2, ground rules — Link contracts are incomplete.** Goal-parent links are missing from the feature mapping; “selection anywhere” cannot always supply the mandatory source jot; typed IDs have no kind-selection rule. **Fix:** add those mappings, create a source jot for non-jot selections, and distinguish suggested links from accepted links. Preserve merge provenance for splitting, and suppress automatic recreation after explicit unlinking.

- **P5, P6, §6 “one meeting, one pass” — Contact clocks disagree.** “Last talked” requires two-way contact, but one outgoing message clears the reminder; the closing flow implies meetings count only after Fathom processing. **Fix:** separate last conversation, last outreach, and snoozed-until; define the two-way window. Process accepted past meetings independently of Fathom, label them as inferred contact, and permit correction.

- **P3–P5, P9–P10 — Existing screening inputs cannot establish complete contact history.** Gmail screening filters mail; WhatsApp screening focuses on unread messages. Requested drafts/signals also lack a per-channel retrieval contract. **Fix:** add independent metadata cursors, explicit backfill coverage and freshness, and define which channels can supply recent text. Show unavailable/stale context rather than implying complete knowledge.

- **P11 / LinkedIn — Snapshot changes lack identity and timing rules.** Reimports, missing rows, blanks, and out-of-order exports could produce false job changes. **Fix:** persist export date and baseline, match canonical profile URLs, make imports idempotent, and distinguish disappearance from employment change. Report “changed since previous export,” with no invented change date.

- **P11, §7 / Companies House — Matching requires data and durable bindings not specified in P2.** Name plus birth month/year is not sufficient as an unexplained automatic identity rule. **Fix:** bind each person to a confirmed officer identifier, retain appointment identifiers and provenance, and leave unresolved candidates unlinked. Show resignations separately from new appointments; record polling failures.

- **P11, §7 / News and feeds — Opening an article does not verify identity.** “Possible until opened” can silently promote a wrong match. **Fix:** keep uncertainty until explicitly resolved; distinguish person news from firm news. Store feed/query, article identity, publication/fetch dates and match evidence; deduplicate across feeds, limit frequency, and provide mute. Specify a fallback for pages without feeds.

- **§7 — Missing AI jobs and judgement flags.** Omitted: jot/person association, decision/person disambiguation, D7 task suggestions, and rulebook learning from “Not a decision.” Tags, cleanup fidelity, form extraction, contact autofill, and drafting also involve judgement despite confirmation. **Fix:** add every job’s trigger, inputs, location, retained output and judgement flag; keep confirmation as a separate mitigation. Include tag vocabulary and relevant identities in the stated inputs.

- **D1, D4, J13 — Weekly screening has no durable processing contract.** Retries, edited jots, delayed uploads and review jots quoting old decisions can create duplicates or omissions. **Fix:** track processed jot revisions, catch up by receipt, retain rejection/extraction identity, and distinguish new decisions from repeated quotations. Apply engine results idempotently through the Mac reconciler; automatic recording remains unchanged.

- **D2–D3, D6 — Capture date is not decision date; missing predictions invite fabrication.** Retrospective notes and meeting summaries may misdate decisions, while prefilled confidence/outcome can appear contemporaneous. **Fix:** separate recorded date from stated decision date; permit unknown dates, outcome and confidence. Preserve source revision/quote, label later-added predictions, and define which date starts reviews.

- **Ground rules, P6–P7, D4, R4, §8.2 — Reminder and review behaviour is incomplete.** D4 omits the owner-approved Circle due list; resolution/import nudges sit outside the stated budget. Creating a task may duplicate an existing Circle reminder. **Fix:** include Circle in D4; specify budget membership, prioritisation, deduplication and completion semantics. Use shared notification identity and delivery ownership; define offline fallback for “once across Mac and phone.”

- **Ground rules, J3, J10, D4 — Independent modules and navigation conflict.** Disabling Jots affects task notes and Decisions; disabling Decisions removes Circle’s weekly review home. Phone “opens to writing” conflicts with board-home wording. **Fix:** distinguish disabling a tab from stopping capture/jobs, state dependencies, hide disabled tabs, and define Mac/phone entry points. Make the weekly review reachable without visiting each area.

- **R1–R5 — Goals lack period and rollover semantics.** Editing a goal next quarter could rewrite history; yearly progress may omit quarterly tasks or double-count them. **Fix:** store level, period and lifecycle; create successor goals on rollover, preserve reviewed versions, enforce acyclic parent links, and define deduplicated descendant progress/filtering.

**Minor**

- **C7 — Cached recurrence labels can contradict actual occurrences.** **Fix:** refresh changed masters and summarize only surviving instances in each block, exposing moved/cancelled exceptions. Extend the phone snapshot through next week and show its freshness.

- **J11 — Automatic jots may suppress the reflection nudge.** Fathom imports or task-note changes could count as “already jotted.” **Fix:** define qualifying owner captures and the timezone used for the daily check.

- **J12, J14 — Daily exports have undefined rewrite/deletion behaviour.** **Fix:** specify whether files belong entirely to FloatBoard, use atomic writes, and propagate jot edits/deletions to the original dated file. Explain that history and decision quotes may retain deleted text.

Codex session ID: 01a1e88b-f968-7bc3-bd26-87c9c37007c3
Resume in Codex: codex resume 01a1e88b-f968-7bc3-bd26-87c9c37007c3
