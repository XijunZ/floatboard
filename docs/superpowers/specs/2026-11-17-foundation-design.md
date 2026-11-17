# Foundation design: the shared base for Jots, Circle, Decisions, Resolutions

Date: 17 Nov 2026 · Branch `assistant` · Status: **binding for the four area branches**

Requirements: `2026-11-17-assistant-features.md` (v5: ground rules, §6 Links, §7 AI jobs, §9 v4 rules, §10 Phone app).
This note fixes the interfaces the four areas build on. An area may **add** to them (new columns in its own schema
version, new registry entries, new files); it must not change a signature below. If one turns out wrong, raise it
instead of working around it.

## 0. Numbers (pre-allocated)

| | Foundation | Jots | Circle | Decisions | Resolutions |
|---|---|---|---|---|---|
| Mac `DB.schemaVersion` | **12** | 13 | 14 | 15 | 16 |
| Engine D1 migration | **0039** | 0040 | 0041 | 0042 | 0043 |
| Schema fixture | `mac/Tests/Fixtures/schema-v12.json` | `schema-v13.json` | … | … | … |

Each area adds one `if version < N` block to `DB.upgrade(from:)`, appends its DDL to `DB.schema`, writes
`schema-vN.json` from a board upgraded from vN-1, and adds its tables to `docs/data-model.md` (both checks read
`schema-v\(DB.schemaVersion).json`). The check `upgraded_board_matches_new_board` (FoundationChecks.swift) builds a v11 board
from `schema-v11.json` and upgrades it; an area extends `makeV11Schema`'s chain or builds its own vN-1 board the same way.
To write the fixture: run the checks with `FLOATBOARD_WRITE_SCHEMA_FIXTURE=<absolute path>`. Merge order is the numbers' order.

## 1. Files

| What | File |
|---|---|
| Ids, mentions | `mac/Sources/FloatBoardCore/Board/ShortID.swift` |
| Item standard (source, stamps, registry of item kinds) | `mac/Sources/FloatBoardCore/Items/Items.swift` |
| Links (kinds, made-by, hide on delete, undo) | `mac/Sources/FloatBoardCore/Board/Links.swift` |
| Tags (+ fixed-tag rules) | `mac/Sources/FloatBoardCore/Items/Tags.swift` |
| Jots core | `mac/Sources/FloatBoardCore/Items/JotStore.swift` |
| People core | `mac/Sources/FloatBoardCore/Items/PeopleStore.swift` |
| Modules | `mac/Sources/FloatBoardCore/Items/Modules.swift` |
| Reminder budget | `mac/Sources/FloatBoardCore/Items/ReminderBudget.swift` |
| Weekly review registry | `mac/Sources/FloatBoardCore/Items/WeeklyReview.swift` |
| Global search registry | `mac/Sources/FloatBoardCore/Items/GlobalSearch.swift` |
| Make task from a selection (core) | `mac/Sources/FloatBoardCore/Items/MakeTask.swift` |
| Calendar guests and kept records | `CalendarModels.swift`, `CalendarCache.swift` (existing files) |
| Tabs | `mac/Sources/FloatBoard/App/Panel.swift` (`UIState.Tab`) |
| Area tabs (placeholders the areas replace) | `mac/Sources/FloatBoard/Jots/JotsTab.swift`, `Circle/CircleTab.swift`, `Decisions/DecisionsTab.swift`, `Resolutions/ResolutionsTab.swift` |
| Settings › Areas | `mac/Sources/FloatBoard/Settings/AreasSection.swift` |
| Link chips, selectable text, selection menu, Make task form | `mac/Sources/FloatBoard/Items/` |
| Weekly review page | `mac/Sources/FloatBoard/Items/WeeklyReviewView.swift` |
| Global search UI | `mac/Sources/FloatBoard/Items/GlobalSearchView.swift` |
| Tag editor (task editor) | `mac/Sources/FloatBoard/Items/TagEditor.swift` |
| Engine migration | `engine/migrations/0039_assistant_foundation.sql` |
| Phone shell | `engine/src/phone/page.ts`, `engine/src/phone/files/app.client.js` |
| Checks | `mac/Sources/FloatBoardChecks/FoundationChecks.swift` (ids, schema, links), `FoundationCoreChecks.swift` (the rest); snapshots with `FLOATBOARD_FOUNDATIONSHOTS=1 … FloatBoard --snapshot <dir>` (scratch database only); `engine/test/phone/foundation.test.ts` |
| App pieces | `Items/LinkChips.swift` (`LinkChips(item:except:)`, `UndoUnlinkBar`), `Items/AreaPlaceholder.swift`, `Items/AssistantTicker.swift` (budget delivery, Sunday nudge) |

## 2. Schema v12 (Mac)

```sql
-- Links gain a kind, who made it, which end the kind is said of, and a hidden flag (deleting an item hides its links).
ALTER TABLE links ADD COLUMN kind TEXT NOT NULL DEFAULT 'related';
ALTER TABLE links ADD COLUMN made_by TEXT NOT NULL DEFAULT 'manual';
ALTER TABLE links ADD COLUMN subject TEXT NOT NULL DEFAULT '';     -- the id text the kind is said of ('' for related)
ALTER TABLE links ADD COLUMN hidden_by TEXT NOT NULL DEFAULT '';   -- '' visible; else the id text of the deleted item that hid it
-- Item standard for tasks: '' = worked out from the task (typed, or message/meeting for a connector's); 'phone' etc. when known.
ALTER TABLE cards ADD COLUMN item_source TEXT NOT NULL DEFAULT '';
-- Tags = the board's groups (`areas`). Fixed tags (Investor, Prospect) are areas rows with fixed=1.
ALTER TABLE areas ADD COLUMN fixed INTEGER NOT NULL DEFAULT 0;
CREATE TABLE item_tags(
    item TEXT NOT NULL, tag_id INTEGER NOT NULL, is_primary INTEGER NOT NULL DEFAULT 0, added REAL NOT NULL,
    PRIMARY KEY(item, tag_id)
);
CREATE INDEX item_tags_tag ON item_tags(tag_id);
CREATE TABLE jots(
    id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'jot',
    source TEXT NOT NULL DEFAULT 'typed', added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX jots_added ON jots(added);
CREATE TABLE jot_history(id INTEGER PRIMARY KEY AUTOINCREMENT, jot_id INTEGER NOT NULL, text TEXT NOT NULL, at REAL NOT NULL);
CREATE INDEX jot_history_jot ON jot_history(jot_id);
CREATE TABLE people(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', tier TEXT NOT NULL DEFAULT 'network',
    source TEXT NOT NULL DEFAULT 'typed', added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE reminders(
    id TEXT PRIMARY KEY, kind TEXT NOT NULL, item TEXT NOT NULL, text TEXT NOT NULL, day TEXT NOT NULL,
    fire_at REAL NOT NULL, granted REAL NOT NULL, delivered REAL, delivered_by TEXT NOT NULL DEFAULT ''
);
CREATE INDEX reminders_day ON reminders(day);
ALTER TABLE cal_events ADD COLUMN guests TEXT NOT NULL DEFAULT '[]';   -- [{"email":"…","status":"accepted"}]
-- A permanent minimal record of every event a link points to (kept when the event leaves the window or Google deletes it).
CREATE TABLE cal_kept(
    short_id INTEGER PRIMARY KEY, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, all_day INTEGER NOT NULL,
    video_link TEXT NOT NULL DEFAULT '', kept_at REAL NOT NULL
);
-- Kept by triggers, so no write path can miss one.
CREATE TRIGGER links_keep_event AFTER INSERT ON links BEGIN
    INSERT OR REPLACE INTO cal_kept(short_id, title, start, end, all_day, video_link, kept_at)
    SELECT short_id, title, start, end, all_day, video_link, strftime('%s','now') FROM cal_events
    WHERE (NEW.from_type='E' AND short_id=CAST(NEW.from_id AS INTEGER)) OR (NEW.to_type='E' AND short_id=CAST(NEW.to_id AS INTEGER));
END;
CREATE TRIGGER cal_events_keep AFTER UPDATE ON cal_events WHEN NEW.gone=0 AND EXISTS (SELECT 1 FROM cal_kept WHERE short_id=NEW.short_id) BEGIN
    UPDATE cal_kept SET title=NEW.title, start=NEW.start, end=NEW.end, all_day=NEW.all_day, video_link=NEW.video_link WHERE short_id=NEW.short_id;
END;
```

Upgrade 11 → 12 also: backfills link kinds (a link between a task and the event whose `fb_card` is that task, or whose
`event_id` is the task's `gcal_event`, is `own-event`/`auto` with the task as subject; every other existing row stays
`related`/`manual`); sets `item_source='phone'` on tasks whose history says "created (from the phone)"; adds the fixed
tags Investor and Prospect (`INSERT OR IGNORE`, so an existing group of that name is reused and marked fixed); fills
`cal_kept` for events already linked; and writes `meta('modules')` with all four areas **on**. A brand-new board has no
`modules` row, which reads as all **off**. One link per pair of items (the existing `UNIQUE`); pairs are stored smaller
id text first, as today.

Not done: a task's own event is still found through `cards.gcal_event` (no new link row is created for it, so the board's
meeting counts do not change); only existing rows are classified.

## 3. Swift interfaces (FloatBoardCore)

### Ids and mentions
```swift
public enum ItemKind: String, CaseIterable { case task = "T", event = "E", jot = "J", person = "P", decision = "D", resolution = "R" }
public struct ShortID: Hashable {            // unchanged: kind, number, text, parse(_:)
    public static func mentions(in text: String) -> [ShortID]   // "T-12", "j-7" as whole words; in order, each once
}
```

### Item standard
```swift
public enum ItemSource: String, CaseIterable { case typed, phone, meeting, message, claude }
public struct ItemSummary: Equatable { public let id: ShortID; public let title: String; public let added: Date?; public let updated: Date?;
                                       public let source: ItemSource?; public let deleted: Bool }
extension Card { public var itemSource: ItemSource }          // item_source if set; else connector "" → typed, a recap → meeting, else message
@MainActor public enum ItemCatalog {
    /// Each area registers its kind (D and R are registered by Decisions and Resolutions). T, E, J, P are built in.
    public static func register(_ kind: ItemKind, _ lookup: @escaping (Store, Int64) -> ItemSummary?)
}
extension Store {
    public func item(_ id: ShortID) -> ItemSummary?             // nil when unknown; deleted items come back with deleted = true
    public func itemExists(_ id: ShortID) -> Bool               // known and not deleted
}
```

### Links (§6)
```swift
public enum ItemLinkKind: String, CaseIterable { case ownEvent = "own-event", related, source, notesOf = "notes-of",
                                              reviewOf = "review-of", supersedes, serves; public var directed: Bool }
public enum LinkMaker: String, CaseIterable { case auto, suggested, manual }
public struct ItemLink: Equatable { public let other: ShortID; public let kind: ItemLinkKind; public let madeBy: LinkMaker
                                    public let isSubject: Bool; public let created: Date }   // isSubject: the asked-about item is the one the kind is said of
extension Store {
    /// `a` is the subject of a directed kind: link(task, jot, kind: .source) = "the task was made from the jot".
    /// A pair already linked keeps one row: a manual link is never downgraded by auto/suggested; otherwise kind, subject and
    /// made_by are replaced. Linking to itself, or to a deleted item, does nothing. Returns false when nothing changed.
    @discardableResult public func link(_ a: ShortID, _ b: ShortID, kind: ItemLinkKind = .related, madeBy: LinkMaker = .manual,
                                        actor: Actor, now: Date = Date()) -> Bool
    public func unlink(_ a: ShortID, _ b: ShortID)              // existing; no Undo
    public func unlinkWithUndo(_ a: ShortID, _ b: ShortID)      // the ✕ on a chip; sets lastUnlinked
    @Published public internal(set) var lastUnlinked: UnlinkedLink?   // (declared in Store) cleared by undoUnlink or the next unlink
    public func undoUnlink()
    public func links(of id: ShortID) -> [ShortID]              // existing: visible links only
    public func itemLinks(of id: ShortID) -> [ItemLink]         // visible, oldest first
    /// Deleting / restoring any item (inside a transaction). Hidden rows stay; restore un-hides those this item hid
    /// (a row whose other end is deleted meanwhile moves to that item).
    func hideLinks(of id: ShortID) throws -> Int
    func unhideLinks(of id: ShortID) throws
    /// Ids typed into a saved text: each id in `text` that was not in `previous` and exists is linked (related, manual).
    /// An id the owner unlinked with ✕ and then left in the text is not re-linked until it is typed again.
    public func linkMentions(in text: String, previous: String, from item: ShortID, now: Date = Date())
}
```
Task delete now hides its links (persisted) instead of removing them; Undo and the phone's restore un-hide them, also
after a restart. Jots and people do the same (`JotStore.delete`, `PeopleStore.delete`). Decisions and Resolutions call
`hideLinks`/`unhideLinks` inside their own delete/restore.

### Tags (§9)
```swift
public struct ItemTags: Equatable { public var primary: String?; public var others: [String]; public var all: [String] }  // all = primary first
public enum TagRules {
    public static let investor = "Investor", prospect = "Prospect"
    public static let fixed: [String]                            // [investor, prospect]
    /// Problems, worded for the owner; empty = allowed. Prospect never on Family. Used by every form, bulk edit and import.
    public static func problems(tags: [String], tier: PersonTier?) -> [String]
    /// Investor caps a person's contact interval at 3 months (Circle applies it). nil = no cap.
    public static func intervalCapMonths(tags: [String]) -> Int?
}
public enum TagFilter {
    public static func matches(_ tags: ItemTags, any selected: Set<String>) -> Bool    // empty selection matches all
    public static func counts(_ items: [ItemTags]) -> [String: Int]                     // each item counted once per tag
}
extension Store {
    @Published public private(set) var tags: [Category]        // every tag, groups and fixed ones
    // `areas` (existing) = the board's groups: non-fixed tags, plus a fixed one a live task uses as its group.
    public func itemTags(_ id: ShortID) -> ItemTags
    /// Replaces an item's tags. For a task the primary is its group (`cards.area`, via the usual edit path: history,
    /// phone, colour) and must be a group; others go to item_tags. Unknown names are refused. Returns an error text or nil.
    @discardableResult public func setTags(_ id: ShortID, primary: String?, others: [String], tier: PersonTier? = nil,
                                           now: Date = Date()) -> String?
    public func items(taggedAny tags: Set<String>, kind: ItemKind? = nil) -> [ShortID]   // each item once
    public func tagsChangedAt(_ cardID: Int64) -> Date?          // last group or tag change here (phone newest-wins)
}
```
A task's primary tag is `cards.area` (no row in `item_tags`); its other tags are `item_tags` rows with `is_primary=0`.
Every other item keeps all its tags in `item_tags` (one `is_primary=1`). Deleting a group removes its `item_tags` rows
(an item whose primary it was gets its first other tag as primary). Renaming keeps ids, so nothing else moves.

### Jots core (Jots extends; Decisions and Circle read through it)
```swift
public enum JotKind: String, CaseIterable { case jot, taskNote = "task_note", meetingNotes = "meeting_notes" }
public struct Jot: Identifiable, Equatable { public let id: Int64; public var text: String; public var kind: JotKind
    public var source: ItemSource; public var added: Date; public var updated: Date; public var deleted: Bool; public var shortID: ShortID }
public struct JotVersion: Equatable { public let text: String; public let at: Date }
@MainActor public struct JotStore {
    public init(store: Store)
    @discardableResult public func create(text: String, kind: JotKind = .jot, source: ItemSource = .typed, now: Date = Date()) -> Jot?  // nil for empty text
    @discardableResult public func update(_ id: Int64, text: String, now: Date = Date()) -> Bool   // previous text → jot_history; links typed ids
    public func delete(_ id: Int64, now: Date = Date())           // soft; hides links
    public func undoDelete(_ id: Int64, now: Date = Date())
    public func jot(_ id: Int64) -> Jot?                          // deleted too
    public func jots(addedFrom: Date, to: Date, includeDeleted: Bool = false) -> [Jot]   // newest first
    public func history(_ id: Int64) -> [JotVersion]              // oldest first, previous texts only
}
```

### People core (Circle extends)
```swift
public enum PersonTier: String, CaseIterable { case family, close, network }
public struct Person: Identifiable, Equatable { public let id: Int64; public var name: String; public var aliases: [String]
    public var tier: PersonTier; public var source: ItemSource; public var added: Date; public var updated: Date; public var deleted: Bool
    public var shortID: ShortID }
@MainActor public struct PeopleStore {
    public init(store: Store)
    @discardableResult public func create(name: String, aliases: [String] = [], tier: PersonTier = .network,
                                          source: ItemSource = .typed, now: Date = Date()) -> Person?
    @discardableResult public func update(_ p: Person, now: Date = Date()) -> Bool
    public func delete(_ id: Int64, now: Date = Date()); public func undoDelete(_ id: Int64, now: Date = Date())
    public func person(_ id: Int64) -> Person?
    public func people(includeDeleted: Bool = false) -> [Person]  // by name
    public func find(nameOrAlias: String) -> [Person]             // exact, case- and accent-insensitive, trimmed; live people only
}
```

### Modules
```swift
public enum Module: String, CaseIterable, Codable { case jots, circle, decisions, resolutions
    public var title: String; public var requires: Module? }       // decisions → jots
extension Store {
    @Published public private(set) var modules: Set<Module>      // read from meta('modules'); missing row = none on
    public func isOn(_ m: Module) -> Bool
    /// Returns the refusal text, or nil once saved: Decisions can't go on while Jots is off; Jots can't go off while Decisions is on.
    @discardableResult public func setModule(_ m: Module, on: Bool) -> String?
}
@MainActor public enum ModuleHooks {
    /// Called after a module is switched (true = on). Each area registers its background jobs' start/stop here and also
    /// checks `store.isOn(_:)` before each run. Data is never deleted.
    public static func onChange(_ m: Module, _ f: @escaping (Bool) -> Void)
}
```

### Reminder budget (§9)
```swift
public enum ReminderKind: String, CaseIterable { case circleDue = "circle_due", decisionReview = "decision_review" }
public struct ReminderSettings: Codable, Equatable { public var dailyLimit = 3; public var quietStart = 22 * 60; public var quietEnd = 8 * 60 } // minutes, app zone
public enum ReminderGrant: Equatable { case granted(id: String, fireAt: Date), deferred(until: Date), duplicate(id: String) }
public struct BudgetReminder: Equatable { public let id, kind, item, text: String; public let fireAt: Date; public let delivered: Date? }
@MainActor public struct ReminderBudget {
    public init(store: Store)
    public static let phoneGrace: TimeInterval = 10 * 60
    public var settings: ReminderSettings { get }; public func save(_ s: ReminderSettings)
    /// One notification id per (kind, item, app day). In quiet hours the fire time moves to their end. Over the day's
    /// limit: deferred to the next day's first allowed minute (ask again then). Asking twice the same day: duplicate.
    public func request(kind: ReminderKind, itemID: ShortID, text: String, now: Date = Date()) -> ReminderGrant
    public func pending() -> [BudgetReminder]                   // granted, not delivered
    public func markDelivered(_ id: String, by: String, at: Date = Date())   // "mac" | "phone"
    public func forPhone(now: Date = Date()) -> [BudgetReminder]   // pending, plus those left to the phone in the last day
    public static func macShows(_ r: BudgetReminder, now: Date) -> Bool       // fireAt ≤ now < fireAt + phoneGrace
    public static func phoneTakesOver(_ r: BudgetReminder, now: Date) -> Bool // now ≥ fireAt + phoneGrace
}
```
Delivery (review R1/R2): `ReminderDelivery(store:claim:schedule:)` runs every minute. Before showing, the Mac claims the id at
each online engine (`POST /v2/reminders/claim` → `mac` / `phone`; the same claim row the engine's own send takes), so one id is
shown once across Mac and phone even if the Mac's board update is lost; a reminder counts as delivered only after macOS
accepted it (a refusal leaves it waiting, one Activity error). Earlier wording: the app checks `pending()` every minute; it shows a Mac notification (id = reminder id) when `macShows`, and
marks `phoneTakesOver` ones delivered by "phone". The board push carries `pending()` (`reminders`); the engine sends one
by Web Push only after `fire_at + 10 min` and only while it is still in the Mac's latest copy (the Mac drops it from the
copy once shown). Claimed once in `due_alerts_sent` (`card_id 0`, `due 'budget:<id>'`).

### Weekly review (page under the bar, §9)
```swift
public struct ReviewItem: Identifiable, Equatable { public let id: String; public let item: ShortID?; public let title: String; public let detail: String }
public struct ReviewSection { public let id: String; public let title: String; public let module: Module?; public let order: Int
    public let items: @MainActor (Store, DateInterval) -> [ReviewItem] }
@MainActor public enum WeeklyReview {
    public static func register(_ s: ReviewSection)              // same id replaces
    public static func sections(store: Store, now: Date = Date()) -> [(ReviewSection, [ReviewItem])]  // modules on, non-empty, by order
    public static func week(containing: Date) -> DateInterval      // Monday 00:00 – next Monday, app zone
    public static func nudgeDue(now: Date, lastNudged: Date?) -> Bool   // Sunday from 18:00 app zone, once per week
    public static func onNudge(_ f: @escaping () -> Void)        // hooks run when the Sunday nudge fires
    public static func fireNudge()                               // called by the app's ticker
}
```
Planned sections: Decisions `decisions.recorded` (order 10), `decisions.maybe` (20), `decisions.reviews` (30); Circle
`circle.due` (40).

### Global search
```swift
public struct SearchHit: Identifiable, Equatable { public var id: ShortID; public let title: String; public let detail: String; public let date: Date? }
@MainActor public enum GlobalSearch {
    public static func register(_ kind: ItemKind, module: Module?, _ f: @escaping @MainActor (Store, String) -> [SearchHit])
    /// A typed id finds exactly that item. Otherwise every word must match. Kinds in ItemKind order; modules that are off are skipped.
    public static func run(_ query: String, store: Store, limit: Int = 20) -> [(ItemKind, [SearchHit])]
}
```
Tasks and events are registered by the foundation; Jots registers `.jot`, Circle `.person`, and so on.

### Selection → Make task / Copy id link / Make decision
```swift
// Core
public struct TaskDraft: Equatable { public var title: String; public var notes: String; public var primaryTag: String?; public var others: [String] }
public enum MakeTask { public static func draft(selection: String, sourceTags: ItemTags?, groups: [String]) -> TaskDraft }
extension Store {
    /// Creates the task (typed), its tags, and a `source` link from the task to `source` (manual). Returns the new id.
    @discardableResult public func makeTask(_ d: TaskDraft, due: Date?, dueHasTime: Bool, from source: ShortID?, now: Date = Date()) -> Int64?
}
// App (FloatBoard/Items/Selection.swift)
struct SelectionContext { let text: String; let source: ShortID? }
@MainActor enum SelectionActions {
    struct Action { let id: String; let title: String; let module: Module?; let run: @MainActor (SelectionContext) -> Void }
    static func register(_ a: Action)                     // Decisions registers id "make_decision", module .decisions
    /// "Make task", then registered actions whose module is on, then "Copy id link (X-n)" when there is a source.
    static func available(_ store: Store, ui: UIState, source: ShortID?) -> [Action]
}
@MainActor enum GlobalSearchOpen { static var handlers: [ItemKind: (ShortID) -> Void] }  // how an area opens its item from search
struct SelectableText: NSViewRepresentable            // read-only text whose right-click menu carries the actions
struct SelectableTextEditor: NSViewRepresentable      // the same for an editable text (binding)
```
Used today by the event panel's description and the task editor's AI summary; Jots (task notes, jots, meeting notes)
and Decisions (reviews) use the same views. Copy id link copies the source item's id ("J-7").

### Calendar prerequisites
```swift
public struct CalGuest: Codable, Equatable { public let email: String; public let status: String }  // needsAction|accepted|declined|tentative
extension GoogleEventChange { public var guests: [CalGuest]? }  // nil = not read; kept as before
extension CalEvent { public var guests: [CalGuest] }
public struct KeptEvent: Equatable { public let shortID: Int64; public let title: String; public let start: Date; public let end: Date
                                     public let allDay: Bool; public let videoLink: String }
extension CalendarCache { public func kept(shortID: Int64) -> KeptEvent? }   // the live event if cached, else the kept record
```

## 4. Engine (D1 0039) and phone

```sql
ALTER TABLE settings ADD COLUMN modules TEXT;            -- JSON {"jots":true,...}; NULL = not sent yet (all off)
CREATE TABLE meetings (                                  -- Fathom meeting metadata (no summary text)
  user_id TEXT NOT NULL, recap_key TEXT NOT NULL, fathom_url TEXT NOT NULL DEFAULT '', meeting_url TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '', scheduled_start TEXT, invitees TEXT NOT NULL DEFAULT '[]', received_at TEXT NOT NULL,
  PRIMARY KEY (user_id, recap_key)
);
```
- `PUT /v2/board` (Mac): optional `modules` (`{jots, circle, decisions, resolutions}` booleans) → stored in the copy and
  `settings.modules`; each card may carry `tags` (1–20 names ≤ 60 chars, primary first) and `tags_at` (ISO); optional
  `reminders` (≤ 20 `{id, title, text, fire_at}`).
- Phone action `set_tags` `{card_id, tags}`: newest wins against the card's `tags_at`; the Mac applies it unless its own
  tag change is newer. `GET /app/api/board` returns `modules`.
- `GET /v2/meetings?since=<ISO>` (Mac): Fathom metadata received since then (Jots consumes it): `{ meetings: [{ recap_key,
  fathom_url, meeting_url, title, scheduled_start, invitees: [email], received_at }] }`. Recorded by the webhook and the
  hourly catch-up (`recordMeeting(env, userId, meetingMeta(payload, message))`). Field names follow Fathom's documented
  payload (`calendar_invitees`, `scheduled_start_time`, `meeting_url`): recapture one live delivery before relying on them.
- Mac side: `BoardCard.tags` / `tagsAt`, `BoardExtras(modules:reminders:)` via `PhoneBoard.extras(store:now:)`, passed to
  `PhoneBoard.body/hash` and `ConnectorClient.putBoard(..., extras:)`; `PhoneAction.tags` for `set_tags`.
- Phone bottom bar **Board · Plan · Jots · Circle · More**; More lists Decisions, Resolutions, Settings. Jots/Circle/
  Decisions/Resolutions entries are hidden while their module is off (`visibleViews(modules)`, `moreEntries(modules)` in
  `sync.client.js`). Placeholders are the sections `#jots`, `#circle` and the More rows `#more-decisions`,
  `#more-resolutions` in `page.ts` (their clicks show a short note in `app.client.js`); each area replaces its section and
  wires its own render. Tags: `tagChoices(cards)`, `tagsAction(card, group, others, id, nowIso)`, the task sheet's "Tags".

## 5. AI jobs: where the areas plug in (no AI in the foundation)

All new jobs run in the engine (online or the Mac's local engine) through the existing `lib/llm.ts`:
- Add the job name to `Job` and `DEFAULT_MODEL` (all `"haiku"`), and map it to `null` in `COLUMN`: Haiku is fixed for the
  assistant's jobs (the owner's rule), so no new model setting is needed. Usage is metered into `llm_usage` as today.
  Names: `jot_tags`, `jot_cleanup`, `fill_form`, `decisions`, `supersedes`, `contact_form`, `news_match`, `draft_message`, `tell_ask`.
- A job with rules the owner can edit gets a rulebook file `engine/src/skills/<job>.md` and a `settings.rulebook_<job>`
  column in the area's migration, and is added to `RulebookSync.keys` on the Mac (same merge rules as email/chat).
  "Not a decision" appends an example to `rulebook_decisions` this way (no extra AI call).
- Each job checks the module flag (`settings.modules`) before it runs and is skipped while the module is off.
- Judgement-call jobs (⚑ in the features §7) record their output as such (Maybe list, "possible") — never silently.
