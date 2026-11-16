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
    public static let schemaVersion = 11
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
                try transaction {
                    try exec(DB.upgrade(from: Int(version)) + "PRAGMA user_version = \(DB.schemaVersion);")
                    if version < 11 { try backfillDueDays() }
                }
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

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
                needs_reconnect INTEGER NOT NULL DEFAULT 0, full_read_at REAL,
                PRIMARY KEY(account, calendar_id)
            );
            CREATE TABLE cal_events(
                short_id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL, all_day INTEGER NOT NULL, start_day TEXT, end_day TEXT, title TEXT NOT NULL,
                location TEXT NOT NULL DEFAULT '', video_link TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
                html_link TEXT NOT NULL DEFAULT '', recurring_id TEXT, google_updated REAL NOT NULL, fb_card INTEGER,
                gone INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0,
                UNIQUE(account, calendar_id, event_id)
            );
            CREATE INDEX cal_events_start ON cal_events(start);
            -- Changes to Google waiting to be sent (kept until sent, so nothing is lost offline or on a crash).
            CREATE TABLE cal_outbox(
                uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT,
                card_id INTEGER, payload_json TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                next_try REAL NOT NULL, last_error TEXT NOT NULL DEFAULT '', sent REAL
            );

            """
        }
        return sql
    }

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
        reply_draft_sent_at REAL, watch_person TEXT NOT NULL DEFAULT '', watch_contact TEXT NOT NULL DEFAULT '', watch_since REAL, due_day TEXT, due_has_time INTEGER NOT NULL DEFAULT 0, gcal_calendar TEXT NOT NULL DEFAULT '', gcal_synced_at REAL
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
        position REAL NOT NULL
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
        needs_reconnect INTEGER NOT NULL DEFAULT 0, full_read_at REAL,
        PRIMARY KEY(account, calendar_id)
    );
    CREATE TABLE cal_events(
        short_id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT NOT NULL,
        start REAL NOT NULL, end REAL NOT NULL, all_day INTEGER NOT NULL, start_day TEXT, end_day TEXT, title TEXT NOT NULL,
        location TEXT NOT NULL DEFAULT '', video_link TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
        html_link TEXT NOT NULL DEFAULT '', recurring_id TEXT, google_updated REAL NOT NULL, fb_card INTEGER,
        gone INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0,
        UNIQUE(account, calendar_id, event_id)
    );
    CREATE INDEX cal_events_start ON cal_events(start);
        -- Changes to Google waiting to be sent (kept until sent, so nothing is lost offline or on a crash).
        CREATE TABLE cal_outbox(
            uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, account TEXT NOT NULL, calendar_id TEXT NOT NULL, event_id TEXT,
            card_id INTEGER, payload_json TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            next_try REAL NOT NULL, last_error TEXT NOT NULL DEFAULT '', sent REAL
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
