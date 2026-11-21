import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DBError: Error, CustomStringConvertible {
    case sql(String)
    case tooOld(file: String, version: Int)
    public var description: String {
        switch self {
        case .sql(let m): return m
        case .tooOld(let file, let version):
            return "\(file) is a backup from an older FloatBoard (schema version \(version); this version needs "
                + "\(DB.oldestSupportedVersion) or newer) and cannot be opened. The file was not changed."
        }
    }
}

/// Thin wrapper around the single SQLite file that holds everything.
public final class DB {
    private var handle: OpaquePointer?
    public let url: URL

    /// The board's file: FLOATBOARD_DB if set (tests), else Application Support. See `LocalData`.
    public static func defaultURL() -> URL { LocalData.database }

    public static func supportDirectory() -> URL { LocalData.supportDirectory }

    /// Kept in PRAGMA user_version. When the schema changes: bump this, update `schema`, and add an upgrade step
    /// from the previous version in `upgrade` (launch backs the file up first when its version is lower).
    public static let schemaVersion = 20
    /// The oldest board this version can open (and upgrade). Older boards and backups are refused unchanged.
    public static let oldestSupportedVersion = 7

    public convenience init() throws { try self.init(url: DB.defaultURL()) }

    /// Opens the board. An empty file gets the current schema; a board from a supported older version is upgraded in one
    /// transaction (launch has backed it up first); a board older than that is refused unchanged.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw DBError.sql("Could not open \(url.path)")
        }
        do {
            let version = try query("PRAGMA user_version") { DB.int($0, 0) }.first ?? 0
            let objects = try query("SELECT count(*) FROM sqlite_master") { DB.int($0, 0) }.first ?? 0
            if version == 0 && objects == 0 {
                try transaction { try exec(DB.schema + "PRAGMA user_version = \(DB.schemaVersion);") }
            } else if version < DB.oldestSupportedVersion {
                throw DBError.tooOld(file: url.lastPathComponent, version: Int(version))
            } else if version < DB.schemaVersion {
                if version == 11 { try addMissingV11Columns() }
                try transaction {
                    try exec(DB.upgrade(from: Int(version)) + "PRAGMA user_version = \(DB.schemaVersion);")
                    if version < 11 { try backfillDueDays() }
                    if version < 12 { try exec(DB.v12Backfill) }
                }
            } else if version == DB.schemaVersion {
                try addMissingV11Columns()
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    /// Version 11 was amended before release (Rounds 6 and 7): a board already at 11 from before then lacks `cal_series`'
    /// `master_start` and `master_zone` and `cal_events`' `original_start`. They are added when missing, without changing
    /// the version; a board that has them is not touched. ALTER puts each before the table's constraints (PRIMARY KEY,
    /// UNIQUE), so the result matches a new board. Adding `original_start` also makes the next calendar pass a full read.
    private func addMissingV11Columns() throws {
        let wanted = [("cal_series", "master_start", "REAL"), ("cal_series", "master_zone", "TEXT"), ("cal_events", "original_start", "TEXT")]
        var missing: [(String, String, String)] = []
        for table in Set(wanted.map(\.0)) {
            let have = Set(try query("PRAGMA table_info(\(table))") { DB.text($0, 1) })
            guard !have.isEmpty else { continue }
            missing += wanted.filter { $0.0 == table && !have.contains($0.1) }
        }
        guard !missing.isEmpty else { return }
        try transaction {
            for (table, column, type) in missing.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
                try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
            }
            // Cached events have no original start yet: the next pass does the daily full read of every calendar now
            // (it first takes in what changed since the last pass, keeps its bookmark, and hides or deletes nothing).
            if missing.contains(where: { $0.1 == "original_start" }) { try exec("UPDATE cal_calendars SET full_read_at=NULL;") }
        }
    }

    /// 10 -> 11: fills `due_day` / `due_has_time` for the existing tasks with the old rule (a due at 00:00 in this Mac's
    /// zone has no time), so nothing changes on screen.
    private func backfillDueDays() throws {
        let rows = try query("SELECT id, due FROM cards WHERE due IS NOT NULL") { (DB.int($0, 0), DB.date($0, 1)) }
        for (id, due) in rows {
            guard let due else { continue }
            if Due.hasTime(due) {
                try run("UPDATE cards SET due_has_time=1 WHERE id=?", [id])
            } else {
                // The day the old screen showed: read in this Mac's zone, not the app zone.
                let c = Calendar.current.dateComponents([.year, .month, .day], from: due)
                let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                try run("UPDATE cards SET due_day=?, due_has_time=0 WHERE id=?", [day, id])
            }
        }
    }

    /// The steps from `version` up to `schemaVersion`. Each only adds, so the upgraded board has exactly `schema`.
    static func upgrade(from version: Int) -> String {
        var sql = ""
        if version < 8 {
            // 7 -> 8: reply drafts.
            sql += """
            ALTER TABLE cards ADD COLUMN reply_draft_state TEXT;
            ALTER TABLE cards ADD COLUMN reply_draft_link TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN reply_draft_error TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN reply_draft_request TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN reply_draft_sent_at REAL;

            """
        }
        if version < 9 {
            // 8 -> 9: Watch (whom a task waits on, how to recognise their reply, and since when).
            sql += """
            ALTER TABLE cards ADD COLUMN watch_person TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN watch_contact TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN watch_since REAL;

            """
        }
        if version < 10 {
            // 9 -> 10: versions of your rules and of what FloatBoard learned (docs/architecture.md, C8).
            sql += """
            CREATE TABLE instructions(
                id INTEGER PRIMARY KEY AUTOINCREMENT, connector TEXT NOT NULL, part TEXT NOT NULL, text TEXT NOT NULL,
                source TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', at REAL NOT NULL
            );
            CREATE INDEX instructions_part ON instructions(connector, part, at);

            """
        }
        if version < 11 {
            // 10 -> 11: a due date keeps its day and whether it has a time, so changing time zone never moves a task.
            // The values are filled in by `backfillDueDays` right after these statements.
            sql += """
            ALTER TABLE cards ADD COLUMN due_day TEXT;
            ALTER TABLE cards ADD COLUMN due_has_time INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE cards ADD COLUMN gcal_calendar TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN gcal_synced_at REAL;
            -- A task linked to an event by version 10: what both sides held at the first sync, so that sync changes neither.
            ALTER TABLE cards ADD COLUMN gcal_baseline TEXT NOT NULL DEFAULT '';
            -- Links between items by visible id (T-142, E-37); stored once, smaller text first.
            CREATE TABLE links(
                id INTEGER PRIMARY KEY AUTOINCREMENT, from_type TEXT NOT NULL, from_id TEXT NOT NULL,
                to_type TEXT NOT NULL, to_id TEXT NOT NULL, created REAL NOT NULL, actor TEXT NOT NULL,
                UNIQUE(from_type, from_id, to_type, to_id)
            );
            CREATE INDEX links_to ON links(to_type, to_id);
            -- Google Calendar kept locally; short_id is the visible E-n and is never reused (AUTOINCREMENT).
            CREATE TABLE cal_calendars(
                account TEXT NOT NULL, calendar_id TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL,
                owned INTEGER NOT NULL, shown INTEGER NOT NULL, sync_token TEXT, synced_at REAL,
                needs_reconnect INTEGER NOT NULL DEFAULT 0, full_read_at REAL, is_primary INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(account, calendar_id)
            );
            CREATE TABLE cal_events(
                short_id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL, all_day INTEGER NOT NULL, start_day TEXT, end_day TEXT, title TEXT NOT NULL,
                location TEXT NOT NULL DEFAULT '', video_link TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
                html_link TEXT NOT NULL DEFAULT '', recurring_id TEXT, google_updated REAL NOT NULL, fb_card INTEGER,
                gone INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, own_write TEXT, original_start TEXT,
                UNIQUE(account, calendar_id, event_id)
            );
            CREATE INDEX cal_events_start ON cal_events(start);
            -- A repeating meeting's rule (Google's recurrence lines), read once per series and again at the daily full read, with
            -- the series' first start and its time zone (master_zone NULL: not read with them yet; '' none, e.g. all-day).
            CREATE TABLE cal_series(
                account TEXT NOT NULL, calendar_id TEXT NOT NULL, series_id TEXT NOT NULL, rule TEXT NOT NULL DEFAULT '',
                read_at REAL NOT NULL, master_start REAL, master_zone TEXT,
                PRIMARY KEY(account, calendar_id, series_id)
            );
            -- Changes to Google waiting to be sent (kept until sent, so nothing is lost offline or on a crash).
            -- failed_at: Google refused the change for good (it is not retried; last_error says why).
            CREATE TABLE cal_outbox(
                uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT,
                card_id INTEGER, payload_json TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                next_try REAL NOT NULL, last_error TEXT NOT NULL DEFAULT '', sent REAL, failed_at REAL,
                conflicts INTEGER NOT NULL DEFAULT 0
            );

            """
        }
        if version < 12 {
            // 11 -> 12: the assistant foundation (docs/superpowers/specs/2026-11-17-foundation-design.md). Filled in by `v12Backfill`.
            sql += """
            ALTER TABLE links ADD COLUMN kind TEXT NOT NULL DEFAULT 'related';
            ALTER TABLE links ADD COLUMN made_by TEXT NOT NULL DEFAULT 'manual';
            ALTER TABLE links ADD COLUMN subject TEXT NOT NULL DEFAULT '';
            ALTER TABLE links ADD COLUMN hidden_by TEXT NOT NULL DEFAULT '';
            ALTER TABLE cards ADD COLUMN item_source TEXT NOT NULL DEFAULT '';
            ALTER TABLE areas ADD COLUMN fixed INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE cal_events ADD COLUMN guests TEXT NOT NULL DEFAULT '[]';

            """ + v12Tables
        }
        if version < 13 {
            // 12 -> 13: Jots (docs/superpowers/specs/2026-11-17-jots-design.md). The same text builds a new board.
            sql += v13Jots
        }
        if version < 14 {
            // 13 -> 14: Circle (docs/superpowers/specs/2026-11-17-circle-design.md). New tables only.
            sql += v14Tables
        }
        if version < 15 {
            // 14 -> 15: Decisions (docs/superpowers/specs/2026-11-17-decisions-design.md). Only its own tables.
            sql += v15Tables
        }
        if version < 16 {
            // 15 -> 16: Resolutions (docs/superpowers/specs/2026-11-17-resolutions-design.md). Depends on none of the blocks above.
            sql += v16Tables
        }
        if version < 17 {
            // 16 -> 17: a write order for jots kept on this Mac (change_seq), for change detection.
            sql += v17JotSeq
        }
        if version < 18 {
            // 17 -> 18: what each connector's phone copy holds (per connector), and a screening order that tag changes don't move.
            sql += v18Tables
        }
        if version < 19 {
            // 18 -> 19: a person's own board group for their "Message <name>" tasks (nullable; nil = automatic).
            sql += v19Columns
        }
        if version < 20 {
            // 19 -> 20: a calendar change's send attempt is recorded before it goes; restoring an old task note keeps newer notes.
            sql += v20Changes
        }
        return sql
    }

    /// The tables version 15 adds (Decisions; the same text for a new board and an upgraded one).
    static let v15Tables = """
    -- Decisions (D-n): recorded from jots by the weekly screening or by hand. recorded = when the source was written (reviews
    -- count from it); decided = 'YYYY-MM-DD' only when the text says so. expected/confidence are never filled by the screening;
    -- *_added marks them added later. status: decided/tentative/reversed/superseded/maybe. not_decision: dismissed (also deleted).
    CREATE TABLE decisions(
        id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, quote TEXT NOT NULL DEFAULT '', source_item TEXT NOT NULL DEFAULT '',
        source_kind TEXT NOT NULL DEFAULT '', recorded REAL NOT NULL, decided TEXT NOT NULL DEFAULT '', why TEXT NOT NULL DEFAULT '',
        expected TEXT NOT NULL DEFAULT '', expected_added REAL, confidence TEXT NOT NULL DEFAULT '', confidence_added REAL,
        alternatives TEXT NOT NULL DEFAULT '', type TEXT NOT NULL DEFAULT 'operational', status TEXT NOT NULL DEFAULT 'decided',
        found_by TEXT NOT NULL DEFAULT 'you', source TEXT NOT NULL DEFAULT 'typed', review_state TEXT NOT NULL DEFAULT 'scheduled',
        review_due REAL, review_ask_after REAL, reviewed REAL, not_decision INTEGER NOT NULL DEFAULT 0,
        added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX decisions_recorded ON decisions(recorded);
    -- Each jot version (SHA-256 of its text, 16 hex) screened once.
    CREATE TABLE decision_screened(
        jot_id INTEGER NOT NULL, version TEXT NOT NULL, screened REAL NOT NULL, found INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(jot_id, version)
    );
    -- Suggestions on a card: supersedes D-n, tell / ask P-n (state open/accepted/dismissed; each made once).
    CREATE TABLE decision_suggestions(
        id INTEGER PRIMARY KEY AUTOINCREMENT, decision_id INTEGER NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'open', created REAL NOT NULL, UNIQUE(decision_id, kind, target)
    );
    -- "Not a decision" examples waiting for (or written into) the Decisions rulebook copy.
    CREATE TABLE decision_examples(
        id INTEGER PRIMARY KEY AUTOINCREMENT, decision_id INTEGER NOT NULL, text TEXT NOT NULL, created REAL NOT NULL, applied REAL,
        connector TEXT NOT NULL DEFAULT ''
    );

    """

    /// The tables, indexes and triggers version 12 adds (the same text for a new board and an upgraded one).
    static let v12Tables = """
    -- Tags on any item (a task's primary tag is its group, cards.area; its other tags and every tag of other items are here).
    CREATE TABLE item_tags(
        item TEXT NOT NULL, tag_id INTEGER NOT NULL, is_primary INTEGER NOT NULL DEFAULT 0, added REAL NOT NULL,
        PRIMARY KEY(item, tag_id)
    );
    CREATE INDEX item_tags_tag ON item_tags(tag_id);
    -- Jots (J-n): one saved capture each, every earlier text kept in jot_history.
    CREATE TABLE jots(
        id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'jot',
        source TEXT NOT NULL DEFAULT 'typed', added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX jots_added ON jots(added);
    CREATE TABLE jot_history(id INTEGER PRIMARY KEY AUTOINCREMENT, jot_id INTEGER NOT NULL, text TEXT NOT NULL, at REAL NOT NULL);
    CREATE INDEX jot_history_jot ON jot_history(jot_id);
    -- People (P-n); aliases is a JSON list of other names, for matching names in text by code.
    CREATE TABLE people(
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', tier TEXT NOT NULL DEFAULT 'network',
        source TEXT NOT NULL DEFAULT 'typed', added REAL NOT NULL, updated REAL NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
    );
    -- The shared reminder budget: one row per notification granted (id = kind, item and day), delivered once.
    CREATE TABLE reminders(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, item TEXT NOT NULL, text TEXT NOT NULL, day TEXT NOT NULL,
        fire_at REAL NOT NULL, granted REAL NOT NULL, delivered REAL, delivered_by TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX reminders_day ON reminders(day);
    -- A permanent minimal record of every event a link points to, kept when the event leaves the window or Google deletes it.
    CREATE TABLE cal_kept(
        short_id INTEGER PRIMARY KEY, title TEXT NOT NULL, start REAL NOT NULL, "end" REAL NOT NULL, all_day INTEGER NOT NULL,
        video_link TEXT NOT NULL DEFAULT '', kept_at REAL NOT NULL
    );
    CREATE TRIGGER links_keep_event AFTER INSERT ON links BEGIN
        INSERT OR REPLACE INTO cal_kept(short_id, title, start, "end", all_day, video_link, kept_at)
        SELECT short_id, title, start, "end", all_day, video_link, CAST(strftime('%s','now') AS REAL) FROM cal_events
        WHERE (NEW.from_type='E' AND short_id=CAST(NEW.from_id AS INTEGER)) OR (NEW.to_type='E' AND short_id=CAST(NEW.to_id AS INTEGER));
    END;
    CREATE TRIGGER cal_events_keep AFTER UPDATE ON cal_events WHEN NEW.gone=0 AND EXISTS (SELECT 1 FROM cal_kept WHERE short_id=NEW.short_id) BEGIN
        UPDATE cal_kept SET title=NEW.title, start=NEW.start, "end"=NEW."end", all_day=NEW.all_day, video_link=NEW.video_link WHERE short_id=NEW.short_id;
    END;

    """

    /// Version 13 (Jots): a task note's task, where a jot arrived from, meeting notes' Fathom details, Claude's tag
    /// suggestions, and what the engine holds of each jot.
    static let v13Jots = """
    ALTER TABLE jots ADD COLUMN task_id INTEGER;
    ALTER TABLE jots ADD COLUMN origin TEXT NOT NULL DEFAULT '';
    CREATE INDEX jots_task ON jots(task_id);
    CREATE UNIQUE INDEX jots_origin ON jots(origin) WHERE origin<>'';
    -- Meeting notes: Fathom's details of the meeting and how the notes were attached to their event (link | time | suggested | '').
    CREATE TABLE jot_meetings(
        jot_id INTEGER PRIMARY KEY, recap_key TEXT NOT NULL, fathom_url TEXT NOT NULL DEFAULT '', meeting_url TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '', scheduled_start REAL, invitees TEXT NOT NULL DEFAULT '[]',
        matched_by TEXT NOT NULL DEFAULT '', received REAL NOT NULL
    );
    -- Claude's tag suggestions per jot: open, accepted or dismissed.
    CREATE TABLE jot_suggestions(
        jot_id INTEGER NOT NULL, tag TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open', at REAL NOT NULL, PRIMARY KEY(jot_id, tag)
    );
    -- What the engine holds of each jot (the `updated` it last accepted) and whether Claude was asked for its tags.
    CREATE TABLE jot_sync(jot_id INTEGER PRIMARY KEY, pushed REAL, tags_asked INTEGER NOT NULL DEFAULT 0);
    -- A task note is the task's notes: its edits, delete and restore reach cards.notes (every write path, so none can miss it).
    CREATE TRIGGER jots_task_note_text AFTER UPDATE OF text ON jots WHEN NEW.task_id IS NOT NULL AND NEW.kind='task_note' AND NEW.deleted=0 BEGIN
        UPDATE cards SET notes=NEW.text, updated=NEW.updated WHERE id=NEW.task_id AND notes<>NEW.text;
    END;
    CREATE TRIGGER jots_task_note_deleted AFTER UPDATE OF deleted ON jots WHEN NEW.task_id IS NOT NULL AND NEW.kind='task_note' AND NEW.deleted<>OLD.deleted BEGIN
        UPDATE cards SET notes=CASE WHEN NEW.deleted=1 THEN '' ELSE NEW.text END, updated=NEW.updated WHERE id=NEW.task_id;
    END;

    """

    /// Version 20 (round 39):
    /// - `cal_outbox.attempted`: when the change was first handed to Google (set before it is sent). A delete attempted but not
    ///   confirmed may have happened, so Undo makes the event again rather than only dropping the row.
    /// - Restoring a deleted task note never overwrites the task's newer notes: with another live task note it comes back as
    ///   an ordinary jot; with newer notes of the task's own, its old text goes to its history and it takes them. Only with
    ///   no notes on the task does it become the task's notes again. One task note per task stays authoritative.
    static let v20Changes = """
    ALTER TABLE cal_outbox ADD COLUMN attempted REAL;
    DROP TRIGGER jots_task_note_deleted;
    CREATE TRIGGER jots_task_note_deleted AFTER UPDATE OF deleted ON jots WHEN NEW.task_id IS NOT NULL AND NEW.kind='task_note' AND NEW.deleted<>OLD.deleted BEGIN
        UPDATE cards SET notes='', updated=NEW.updated WHERE NEW.deleted=1 AND id=NEW.task_id;
        UPDATE jots SET kind='jot' WHERE NEW.deleted=0 AND id=NEW.id
            AND EXISTS (SELECT 1 FROM jots o WHERE o.task_id=NEW.task_id AND o.kind='task_note' AND o.deleted=0 AND o.id<>NEW.id);
        INSERT INTO jot_history(jot_id, text, at) SELECT NEW.id, NEW.text, NEW.updated
            WHERE NEW.deleted=0 AND (SELECT kind FROM jots WHERE id=NEW.id)='task_note'
            AND COALESCE((SELECT notes FROM cards WHERE id=NEW.task_id), '') NOT IN ('', NEW.text);
        UPDATE jots SET text=(SELECT notes FROM cards WHERE id=NEW.task_id) WHERE NEW.deleted=0 AND id=NEW.id AND kind='task_note'
            AND COALESCE((SELECT notes FROM cards WHERE id=NEW.task_id), '') NOT IN ('', NEW.text);
        UPDATE cards SET notes=NEW.text, updated=NEW.updated WHERE NEW.deleted=0 AND id=NEW.task_id AND notes=''
            AND (SELECT kind FROM jots WHERE id=NEW.id)='task_note';
    END;

    """

    /// Version 19: `circle_people.task_area`, the board group chosen for a person's "Message <name>" tasks (NULL: automatic:
    /// a tag that is a group, else by tier). A group that no longer exists falls back to automatic.
    static let v19Columns = """
    ALTER TABLE circle_people ADD COLUMN task_area TEXT;

    """

    /// Version 18:
    /// - `jot_pushed`: which version of each jot each connector's engine accepted (per connector: two engines never undo
    ///   each other's state). `jot_sync.pushed` is no longer used.
    /// - `jots.screen_seq`: the place in the same write order as `change_seq`, moved only by an insert or a change of text,
    ///   kind or deletion (never by tags or the linked task), so the weekly screening never re-reads an old jot for a tag.
    ///   Existing jots start at their change_seq: the screening's saved mark is a change_seq, so a jot written or edited
    ///   after the last run stays after it (a version already screened is still skipped by decision_screened).
    static let v18Tables = """
    CREATE TABLE jot_pushed (
        connector TEXT NOT NULL,
        jot_id INTEGER NOT NULL,
        pushed REAL NOT NULL,
        PRIMARY KEY (connector, jot_id)
    );
    ALTER TABLE jots ADD COLUMN screen_seq INTEGER NOT NULL DEFAULT 0;
    UPDATE jots SET screen_seq = change_seq;
    CREATE INDEX jots_screen_seq ON jots(screen_seq);
    DROP TRIGGER jots_seq_insert;
    DROP TRIGGER jots_seq_update;
    CREATE TRIGGER jots_seq_insert AFTER INSERT ON jots BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots),
                        screen_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = NEW.id;
    END;
    CREATE TRIGGER jots_seq_update AFTER UPDATE OF text, kind, deleted ON jots WHEN NEW.change_seq = OLD.change_seq BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots),
                        screen_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = NEW.id;
    END;
    CREATE TRIGGER jots_seq_task AFTER UPDATE OF task_id ON jots
        WHEN NEW.change_seq = OLD.change_seq AND NEW.text IS OLD.text AND NEW.kind IS OLD.kind AND NEW.deleted IS OLD.deleted BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = NEW.id;
    END;

    """

    /// Version 17 also keeps which phone actions (Make task, the legacy Make decision) were applied, written with what they
    /// made, so one sent again after a lost acknowledgement is not applied twice (kept 30 days).
    /// Version 17: each jot's place in this Mac's write order. Every insert, every change of its text, kind, deletion or task,
    /// and every change of its tags moves it to the end, so "changed since" never depends on the jot's own time (a phone
    /// capture made offline, an older edit arriving late). Existing jots start in id order.
    static let v17JotSeq = """
    ALTER TABLE jots ADD COLUMN change_seq INTEGER NOT NULL DEFAULT 0;
    UPDATE jots SET change_seq = id;
    CREATE INDEX jots_change_seq ON jots(change_seq);
    CREATE TRIGGER jots_seq_insert AFTER INSERT ON jots BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = NEW.id;
    END;
    CREATE TRIGGER jots_seq_update AFTER UPDATE OF text, kind, deleted, task_id ON jots WHEN NEW.change_seq = OLD.change_seq BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = NEW.id;
    END;
    CREATE TRIGGER jots_seq_tag_added AFTER INSERT ON item_tags WHEN NEW.item LIKE 'J-%' BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = CAST(substr(NEW.item, 3) AS INTEGER);
    END;
    CREATE TRIGGER jots_seq_tag_removed AFTER DELETE ON item_tags WHEN OLD.item LIKE 'J-%' BEGIN
        UPDATE jots SET change_seq = (SELECT coalesce(max(change_seq), 0) + 1 FROM jots) WHERE id = CAST(substr(OLD.item, 3) AS INTEGER);
    END;
    CREATE TABLE jot_actions_done (
        key TEXT PRIMARY KEY,
        done DATE NOT NULL
    );

    """

    /// The tables version 16 adds (Resolutions): goals and the earlier wordings of each.
    static let v16Tables = """
    -- Goals (R-n). level: five_year | year | quarter; period: '2026-2030' | '2027' | '2027-Q1'. status: active, or how its
    -- review ended (kept | changed | dropped; never edited after). carried_from: the previous period's goal it carries on.
    CREATE TABLE resolutions(
        id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT NOT NULL, period TEXT NOT NULL, title TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'active', carried_from INTEGER,
        position REAL NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'typed',
        added REAL NOT NULL, updated REAL NOT NULL, reviewed REAL, deleted INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX resolutions_period ON resolutions(level, period);
    -- Earlier wordings of a goal or of the five-year picture, oldest first.
    CREATE TABLE resolution_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT, goal_id INTEGER NOT NULL, title TEXT NOT NULL, notes TEXT NOT NULL, at REAL NOT NULL
    );
    CREATE INDEX resolution_history_goal ON resolution_history(goal_id);

    """

    /// 11 -> 12 data: existing links classified (a task and its own event: own-event, made by code; the rest stay related and
    /// manual), tasks made on the phone marked so, records kept for linked events, and all four areas switched on (the
    /// owner wants to see them; a new board starts with them off). The fixed tags are added at every start (`seedFixedTags`).
    static let v12Backfill = """
    UPDATE links SET kind='own-event', made_by='auto', subject='T-' || to_id
    WHERE from_type='E' AND to_type='T' AND EXISTS (
        SELECT 1 FROM cal_events e WHERE e.short_id=CAST(links.from_id AS INTEGER) AND (
            e.fb_card=CAST(links.to_id AS INTEGER)
            OR EXISTS (SELECT 1 FROM cards c WHERE c.id=CAST(links.to_id AS INTEGER) AND c.gcal_event<>'' AND c.gcal_event=e.event_id AND c.gcal_account=e.account)));
    UPDATE cards SET item_source='phone' WHERE id IN (SELECT card_id FROM events WHERE kind='created (from the phone)');
    INSERT OR IGNORE INTO cal_kept(short_id, title, start, "end", all_day, video_link, kept_at)
    SELECT short_id, title, start, "end", all_day, video_link, CAST(strftime('%s','now') AS REAL) FROM cal_events
    WHERE short_id IN (SELECT CAST(from_id AS INTEGER) FROM links WHERE from_type='E' UNION SELECT CAST(to_id AS INTEGER) FROM links WHERE to_type='E');
    INSERT OR REPLACE INTO meta(key, value) VALUES('modules', '["jots","circle","decisions","resolutions"]');

    """

    /// The schema at `schemaVersion`. Boards that reached this version by upgrading have exactly these tables,
    /// columns (in this order) and indexes, so a new board has the same shape. module_applied is unused but kept for that reason.
    static let schema = """
    CREATE TABLE cards(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        area TEXT NOT NULL,
        importance INTEGER NOT NULL DEFAULT 1,
        due REAL,
        status TEXT NOT NULL,
        created REAL NOT NULL,
        started REAL,
        done REAL,
        updated REAL,
        deleted INTEGER NOT NULL DEFAULT 0,
        link TEXT NOT NULL DEFAULT '',
        gcal_account TEXT NOT NULL DEFAULT '',
        gcal_event TEXT NOT NULL DEFAULT '',
        gcal_link TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '',
        external_id TEXT NOT NULL DEFAULT '',
        source_link TEXT NOT NULL DEFAULT '',
        source_meta TEXT NOT NULL DEFAULT '{}',
        imported_at REAL,
        source_mid TEXT,
        source_sent TEXT,
        withdrawn INTEGER NOT NULL DEFAULT 0,
        ai_summary TEXT NOT NULL DEFAULT '',
        connector TEXT NOT NULL DEFAULT '',
        proposal_json TEXT NOT NULL DEFAULT '',
        reply_draft_state TEXT,
        reply_draft_link TEXT NOT NULL DEFAULT '',
        reply_draft_error TEXT NOT NULL DEFAULT '',
        reply_draft_request TEXT NOT NULL DEFAULT '',
        reply_draft_sent_at REAL, watch_person TEXT NOT NULL DEFAULT '', watch_contact TEXT NOT NULL DEFAULT '', watch_since REAL, due_day TEXT, due_has_time INTEGER NOT NULL DEFAULT 0, gcal_calendar TEXT NOT NULL DEFAULT '', gcal_synced_at REAL, gcal_baseline TEXT NOT NULL DEFAULT '', item_source TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX cards_external_id ON cards(external_id);
    CREATE UNIQUE INDEX cards_source_key ON cards(connector, source_mid, source_sent)
        WHERE source_mid IS NOT NULL;
    CREATE TABLE events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id INTEGER NOT NULL REFERENCES cards(id),
        at REAL NOT NULL,
        kind TEXT NOT NULL,
        from_status TEXT,
        to_status TEXT,
        actor TEXT NOT NULL DEFAULT 'user',
        uuid TEXT
    );
    CREATE INDEX events_card ON events(card_id);
    CREATE UNIQUE INDEX events_uuid ON events(uuid);
    CREATE TABLE areas(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        color TEXT NOT NULL,
        position REAL NOT NULL, fixed INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE module_applied(external_id TEXT PRIMARY KEY, at REAL NOT NULL);
    CREATE TABLE activity(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        at REAL NOT NULL,
        component TEXT NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        detail TEXT,
        trace TEXT,
        seen INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX activity_trace ON activity(trace);
    CREATE TABLE corrections(
        uuid TEXT PRIMARY KEY, connector TEXT, source_mid TEXT, source_sent TEXT,
        proposed_json TEXT, verdict TEXT, detail TEXT, at REAL
    );
    -- detached: a change kept for the record but never sent. detach_reason is 'no_connector' (queued while no
    -- connector row existed) or 'removed' (its connector was removed later).
    CREATE TABLE outbox(
        uuid TEXT PRIMARY KEY, connector TEXT, kind TEXT, payload_json TEXT, created REAL,
        attempts INTEGER DEFAULT 0, next_try REAL, last_error TEXT, sent REAL,
        detached INTEGER NOT NULL DEFAULT 0, detach_reason TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE connectors(
        id TEXT PRIMARY KEY, name TEXT, base_url TEXT, capabilities_json TEXT, cursor TEXT,
        settings_json TEXT, settings_version INTEGER DEFAULT 0, engine_settings_version INTEGER DEFAULT 0,
        last_ok REAL, unreachable_since REAL, status_json TEXT NOT NULL DEFAULT '{}'
    );
    -- A removed connector's settings, restored when the same id is added again.
    CREATE TABLE connector_archive(
        id TEXT NOT NULL, removed_at REAL NOT NULL, name TEXT, base_url TEXT, settings_json TEXT,
        settings_version INTEGER, restored_at REAL, PRIMARY KEY(id, removed_at)
    );
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    -- Every version of your rules and of what FloatBoard learned; source: start, you, learning, restore.
    CREATE TABLE instructions(
        id INTEGER PRIMARY KEY AUTOINCREMENT, connector TEXT NOT NULL, part TEXT NOT NULL, text TEXT NOT NULL,
        source TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', at REAL NOT NULL
    );
    CREATE INDEX instructions_part ON instructions(connector, part, at);
    -- Links between items by visible id (T-142, E-37); stored once, smaller text first.
    -- kind/made_by: what the link means and who made it (§6); subject: the id the kind is said of; hidden_by: the deleted item hiding it.
    CREATE TABLE links(
        id INTEGER PRIMARY KEY AUTOINCREMENT, from_type TEXT NOT NULL, from_id TEXT NOT NULL,
        to_type TEXT NOT NULL, to_id TEXT NOT NULL, created REAL NOT NULL, actor TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'related', made_by TEXT NOT NULL DEFAULT 'manual', subject TEXT NOT NULL DEFAULT '',
        hidden_by TEXT NOT NULL DEFAULT '',
        UNIQUE(from_type, from_id, to_type, to_id)
    );
    CREATE INDEX links_to ON links(to_type, to_id);
    -- Google Calendar kept locally; short_id is the visible E-n and is never reused (AUTOINCREMENT).
    CREATE TABLE cal_calendars(
        account TEXT NOT NULL, calendar_id TEXT NOT NULL, name TEXT NOT NULL, color TEXT NOT NULL,
        owned INTEGER NOT NULL, shown INTEGER NOT NULL, sync_token TEXT, synced_at REAL,
        needs_reconnect INTEGER NOT NULL DEFAULT 0, full_read_at REAL, is_primary INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(account, calendar_id)
    );
    CREATE TABLE cal_events(
        short_id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT NOT NULL,
        start REAL NOT NULL, end REAL NOT NULL, all_day INTEGER NOT NULL, start_day TEXT, end_day TEXT, title TEXT NOT NULL,
        location TEXT NOT NULL DEFAULT '', video_link TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
        html_link TEXT NOT NULL DEFAULT '', recurring_id TEXT, google_updated REAL NOT NULL, fb_card INTEGER,
        gone INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0, own_write TEXT, original_start TEXT,
        guests TEXT NOT NULL DEFAULT '[]',
        UNIQUE(account, calendar_id, event_id)
    );
    CREATE INDEX cal_events_start ON cal_events(start);
        -- A repeating meeting's rule (Google's recurrence lines), read once per series and again at the daily full read, with
        -- the series' first start and its time zone (master_zone NULL: not read with them yet; '' none, e.g. all-day).
        CREATE TABLE cal_series(
            account TEXT NOT NULL, calendar_id TEXT NOT NULL, series_id TEXT NOT NULL, rule TEXT NOT NULL DEFAULT '',
            read_at REAL NOT NULL, master_start REAL, master_zone TEXT,
            PRIMARY KEY(account, calendar_id, series_id)
        );
        -- Changes to Google waiting to be sent (kept until sent, so nothing is lost offline or on a crash).
        -- failed_at: Google refused the change for good (it is not retried; last_error says why).
        CREATE TABLE cal_outbox(
            uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT,
            card_id INTEGER, payload_json TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            next_try REAL NOT NULL, last_error TEXT NOT NULL DEFAULT '', sent REAL, failed_at REAL,
            conflicts INTEGER NOT NULL DEFAULT 0
        );

    """ + v12Tables + v13Jots + v14Tables + v15Tables + v16Tables + v17JotSeq + v18Tables + v19Columns + v20Changes

    /// The tables Circle adds in version 14 (the same text for a new board and an upgraded one).
    static let v14Tables = """
    -- Circle's fields of a person (the core row is `people`); made on first save.
    CREATE TABLE circle_people(
        person_id INTEGER PRIMARY KEY, how_known TEXT NOT NULL DEFAULT '', company TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '',
        birthday TEXT NOT NULL DEFAULT '', language TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '',
        interval_days INTEGER, firm TEXT NOT NULL DEFAULT '', focus TEXT NOT NULL DEFAULT '', purpose TEXT NOT NULL DEFAULT '',
        stage TEXT NOT NULL DEFAULT '', stage_at REAL, snoozed_until REAL, reminded_at REAL, reminder_task INTEGER,
        updates_on INTEGER NOT NULL DEFAULT 0, news_muted INTEGER NOT NULL DEFAULT 0, feed_url TEXT NOT NULL DEFAULT '',
        officer_id TEXT NOT NULL DEFAULT '', officer_name TEXT NOT NULL DEFAULT '', officer_confirmed REAL, manual_checked REAL
    );
    -- A person's handles: phone (international digits), email (lower case), whatsapp (chat id), wechat (chat name), linkedin (profile path).
    CREATE TABLE person_handles(
        id INTEGER PRIMARY KEY AUTOINCREMENT, person_id INTEGER NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, added REAL NOT NULL,
        UNIQUE(kind, value)
    );
    CREATE INDEX person_handles_person ON person_handles(person_id);
    -- Message and meeting metadata (who, when, channel, direction), never any text: one row per handle, channel, day and direction.
    CREATE TABLE circle_exchanges(
        id INTEGER PRIMARY KEY AUTOINCREMENT, channel TEXT NOT NULL, direction TEXT NOT NULL, at REAL NOT NULL, handle_kind TEXT NOT NULL,
        handle TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', key TEXT NOT NULL UNIQUE, ref TEXT NOT NULL DEFAULT '',
        ignored INTEGER NOT NULL DEFAULT 0, added REAL NOT NULL
    );
    CREATE INDEX circle_exchanges_handle ON circle_exchanges(handle_kind, handle, at);
    -- Each reader's state: data as of, complete back to, its cursor, and what it can't see.
    CREATE TABLE circle_channels(
        channel TEXT PRIMARY KEY, as_of REAL, complete_from REAL, cursor TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT ''
    );
    -- Merges (automatic on an exact phone or email match, or by hand) and what moved, so each can be split.
    CREATE TABLE circle_merges(
        id INTEGER PRIMARY KEY AUTOINCREMENT, kept INTEGER NOT NULL, merged INTEGER NOT NULL, moved TEXT NOT NULL, auto INTEGER NOT NULL,
        at REAL NOT NULL, split REAL
    );
    -- People suggested by imports (LinkedIn, Google Contacts), never added in bulk. state: new, added, dismissed.
    CREATE TABLE circle_candidates(
        id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        handles TEXT NOT NULL DEFAULT '[]', company TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'new',
        added REAL NOT NULL
    );
    -- Suggestions the owner said no to (merge pairs, conversation handles).
    CREATE TABLE circle_dismissed(key TEXT PRIMARY KEY, at REAL NOT NULL);
    -- LinkedIn connection exports, each dated, and their rows by profile path.
    CREATE TABLE linkedin_imports(id INTEGER PRIMARY KEY AUTOINCREMENT, export_date TEXT NOT NULL, imported REAL NOT NULL, rows INTEGER NOT NULL);
    CREATE TABLE linkedin_rows(
        import_id INTEGER NOT NULL, url TEXT NOT NULL, name TEXT NOT NULL, company TEXT NOT NULL, position TEXT NOT NULL,
        PRIMARY KEY(import_id, url)
    );
    -- What's new for a person; match 'possible' or 'unlikely' (set aside by Claude); verdict '' until marked right or wrong.
    CREATE TABLE circle_updates(
        id INTEGER PRIMARY KEY AUTOINCREMENT, person_id INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
        detail TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', at REAL, found REAL NOT NULL, match TEXT NOT NULL DEFAULT 'possible',
        verdict TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX circle_updates_person ON circle_updates(person_id, found);
    -- Companies House officers that might be a person, shown until one is confirmed.
    CREATE TABLE officer_candidates(
        person_id INTEGER NOT NULL, officer_id TEXT NOT NULL, name TEXT NOT NULL, born TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
        found REAL NOT NULL, PRIMARY KEY(person_id, officer_id)
    );

    """

    func exec(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw DBError.sql(lastMessage) }
    }

    func transaction(_ work: () throws -> Void) throws {
        try exec("BEGIN")
        do { try work(); try exec("COMMIT") } catch {
            do { try exec("ROLLBACK") } catch let rollback {
                throw DBError.sql("\(error); the rollback also failed: \(rollback)")
            }
            throw error
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.sql(lastMessage) }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(row(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw DBError.sql(lastMessage) }
        }
        return out
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.sql(lastMessage)
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let arg else { sqlite3_bind_null(stmt, idx); continue }
            switch arg {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private var lastMessage: String { String(cString: sqlite3_errmsg(handle)) }

    // Column helpers
    public static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }
    public static func date(_ s: OpaquePointer, _ i: Int32) -> Date? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, i))
    }
    public static func int(_ s: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
    public static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
}
