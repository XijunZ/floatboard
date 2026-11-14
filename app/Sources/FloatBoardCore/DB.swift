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
    public static let schemaVersion = 9
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
                try transaction { try exec(DB.upgrade(from: Int(version)) + "PRAGMA user_version = \(DB.schemaVersion);") }
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

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
        reply_draft_sent_at REAL, watch_person TEXT NOT NULL DEFAULT '', watch_contact TEXT NOT NULL DEFAULT '', watch_since REAL
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
}
