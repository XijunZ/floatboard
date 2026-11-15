import Foundation
import SQLite3

/// Verified, tiered snapshots of the board database (the user's single source of truth).
/// Works on its own SQLite connections so it can run before the app opens the database.
public struct Backups {
    public let dbURL: URL
    public let dir: URL

    public init(dbURL: URL, dir: URL) { self.dbURL = dbURL; self.dir = dir }

    /// Nil when FLOATBOARD_DB points at a scratch file without FLOATBOARD_BACKUPS: tests never back up into the real folder.
    public static func forEnvironment() -> Backups? {
        guard let dir = LocalData.backups else { return nil }
        return Backups(dbURL: LocalData.database, dir: dir)
    }

    public struct BackupError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Names

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func parse(_ file: URL) -> (date: Date, reason: String)? {
        let name = file.lastPathComponent
        guard name.hasPrefix("board-"), name.hasSuffix(".sqlite") else { return nil }
        let core = name.dropFirst(6).dropLast(7)       // yyyyMMdd-HHmmss-reason
        guard core.count > 16, let date = Backups.stamp.date(from: String(core.prefix(15))) else { return nil }
        return (date, String(core.dropFirst(16)))
    }

    /// Newest first.
    public func list() -> [(url: URL, date: Date, reason: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] // try?-ok: a missing folder simply has no backups
        return files.compactMap { u in parse(u).map { (u, $0.date, $0.reason) } }.sorted { $0.date > $1.date }
    }

    /// Backups this version can open, newest first: the Restore menu offers only these.
    public func restorable() -> [(url: URL, date: Date, reason: String)] {
        list().filter { b in
            do { return try Backups.userVersion(b.url) >= DB.oldestSupportedVersion } catch { return false }
        }
    }

    /// True when the file opens read-only, passes SQLite's integrity check and holds a board (an empty or garbage file with a
    /// backup-style name is not a backup).
    public static func isVerified(_ file: URL) -> Bool {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open_v2(file.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        func firstText(_ sql: String) -> String? {
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW,
                  let c = sqlite3_column_text(st, 0) else { return nil }
            return String(cString: c)
        }
        return firstText("PRAGMA integrity_check") == "ok" && firstText("SELECT name FROM sqlite_master WHERE name='cards'") == "cards"
    }

    // MARK: Snapshot

    @discardableResult
    public func snapshot(reason: String, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("board-\(Backups.stamp.string(from: now))-\(reason).sqlite")
        if FileManager.default.fileExists(atPath: out.path) { throw BackupError("\(out.lastPathComponent) already exists") }
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open_v2(dbURL.path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw BackupError("cannot open \(dbURL.path): \(Backups.message(h))")
        }
        sqlite3_busy_timeout(h, 5000)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "VACUUM INTO ?", -1, &st, nil) == SQLITE_OK else {
            throw BackupError("VACUUM INTO unavailable: \(Backups.message(h))")
        }
        sqlite3_bind_text(st, 1, out.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let rc = sqlite3_step(st)
        sqlite3_finalize(st)
        guard rc == SQLITE_DONE else {
            let m = Backups.message(h)
            throw BackupError("snapshot failed: \(m)" + Backups.cleanupNote(out))
        }
        if let problem = Backups.verify(out) {
            if let leftover = Backups.removeReporting(out) {
                throw BackupError("snapshot \(out.lastPathComponent) failed verification and could not be deleted (\(leftover)): \(problem)")
            }
            throw BackupError("snapshot \(out.lastPathComponent) failed verification and was deleted: \(problem)")
        }
        return out
    }

    private static func message(_ h: OpaquePointer?) -> String { h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }

    /// Deletes a file; returns nil on success, otherwise what went wrong. Callers put it in the error they throw
    /// (which ends up in the Activity log), so a leftover partial backup is never silent.
    public static func removeReporting(_ u: URL) -> String? {
        do { try FileManager.default.removeItem(at: u); return nil } catch {
            if !FileManager.default.fileExists(atPath: u.path) { return nil }   // already gone: nothing to clean up
            return "could not delete \(u.lastPathComponent): \(error)"
        }
    }

    private static func cleanupNote(_ u: URL) -> String { removeReporting(u).map { "; also " + $0 } ?? "" }

    /// Opens read-only and runs PRAGMA integrity_check; nil means fine.
    static func verify(_ file: URL) -> String? {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open_v2(file.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "cannot open: \(message(h))" }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, "PRAGMA integrity_check", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW,
              let c = sqlite3_column_text(st, 0) else { return "integrity_check did not run: \(message(h))" }
        let r = String(cString: c)
        return r == "ok" ? nil : r
    }

    // MARK: Rotation

    private var isoCalendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone.current
        return c
    }

    /// Which daily snapshots each tier keeps (newest per day / ISO week / month in its window).
    public func tierKeeps(now: Date) -> (day: Set<URL>, week: Set<URL>, month: Set<URL>) {
        let cal = isoCalendar
        let dailies = list().filter { $0.reason == "daily" }   // newest first
        func newestPer(_ since: Date, _ comps: Set<Calendar.Component>) -> Set<URL> {
            var seen = Set<DateComponents>(), keep = Set<URL>()
            for b in dailies where b.date >= since && b.date <= now {
                if seen.insert(cal.dateComponents(comps, from: b.date)).inserted { keep.insert(b.url) }
            }
            return keep
        }
        let today = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let monthStart = cal.dateInterval(of: .month, for: today)!.start
        return (
            newestPer(cal.date(byAdding: .day, value: -13, to: today)!, [.yearForWeekOfYear, .weekOfYear, .year, .month, .day]),
            newestPer(cal.date(byAdding: .weekOfYear, value: -7, to: weekStart)!, [.yearForWeekOfYear, .weekOfYear]),
            newestPer(cal.date(byAdding: .month, value: -11, to: monthStart)!, [.year, .month])
        )
    }

    public func rotate(now: Date = Date()) throws {
        let t = tierKeeps(now: now)
        let keep = t.day.union(t.week).union(t.month)
        var failures: [String] = []
        for b in list() {
            let kept = b.date > now ? true : b.reason == "daily" ? keep.contains(b.url) : now.timeIntervalSince(b.date) <= 90 * 86400
            if kept { continue }
            if let problem = Backups.removeReporting(b.url) { failures.append(problem) }
        }
        if !failures.isEmpty { throw BackupError("\(failures.count) old backup\(failures.count == 1 ? "" : "s") could not be removed: " + failures.joined(separator: "; ")) }
    }

    // MARK: Restore

    /// Snapshots the current database as `pre-restore`, then swaps the chosen backup in.
    /// The caller must not keep using any open connection afterwards (the app relaunches).
    public func restore(_ backup: URL) throws {
        if let problem = Backups.verify(backup) { throw BackupError("\(backup.lastPathComponent) is not a healthy backup: \(problem)") }
        // A backup this version cannot open would leave the app unable to start after the relaunch.
        let version = try Backups.userVersion(backup)
        if version < DB.oldestSupportedVersion { throw BackupError(DBError.tooOld(file: backup.lastPathComponent, version: version).description) }
        let fm = FileManager.default
        if fm.fileExists(atPath: dbURL.path) {
            do { try snapshot(reason: "pre-restore") } catch {
                // The current file may be corrupt (that is often why we restore): keep a raw copy instead.
                try rawCopy(reason: "pre-restore")
            }
        }
        let staged = dbURL.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString).sqlite")
        try fm.copyItem(at: backup, to: staged)
        do {
            for ext in ["-wal", "-shm", "-journal"] {
                let side = URL(fileURLWithPath: dbURL.path + ext)
                if fm.fileExists(atPath: side.path) { try fm.removeItem(at: side) }
            }
            if fm.fileExists(atPath: dbURL.path) { _ = try fm.replaceItemAt(dbURL, withItemAt: staged) }
            else { try fm.moveItem(at: staged, to: dbURL) }
        } catch {
            if let leftover = Backups.removeReporting(staged) { throw BackupError("\(error); also \(leftover)") }
            throw error
        }
    }

    /// Unverified byte copy of the database and any side files.
    @discardableResult
    func rawCopy(reason: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("board-\(Backups.stamp.string(from: now))-\(reason).sqlite")
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.copyItem(at: dbURL, to: out)
        for ext in ["-wal", "-shm", "-journal"] where fm.fileExists(atPath: dbURL.path + ext) {
            try fm.copyItem(at: URL(fileURLWithPath: dbURL.path + ext), to: URL(fileURLWithPath: out.path + ext))
        }
        return out
    }

    // MARK: Migration trigger

    /// Whether launch should back up before migrating. An existing non-empty file needs it when its
    /// user_version is below DB.schemaVersion. Any error while checking counts as "needed" (with `problem` set).
    public static func migrationCheck(_ url: URL) -> (needed: Bool, problem: String?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil // try?-ok: a missing file means a fresh install, nothing to back up
        guard let size, size > 0 else { return (false, nil) }
        do { return (try userVersion(url) < DB.schemaVersion, nil) } catch { return (true, "\(error)") }
    }

    /// The file's PRAGMA user_version, read on a read-only connection.
    static func userVersion(_ url: URL) throws -> Int {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw BackupError("cannot open: \(message(h))") }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, "PRAGMA user_version", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else {
            throw BackupError("cannot read schema version: \(message(h))")
        }
        return Int(sqlite3_column_int64(st, 0))
    }
}

extension Store {
    /// Snapshot with every failure written to the Activity log. Returns nil on failure.
    @discardableResult
    public func takeBackup(_ b: Backups, reason: String, now: Date = Date()) -> URL? {
        do { return try b.snapshot(reason: reason, now: now) } catch {
            activity("backup", .error, "Backup (\(reason)) failed", detail: "\(error)")
            return nil
        }
    }

    /// Launch and every 6 h: one daily snapshot per calendar day, then rotation.
    public func dailyBackup(_ b: Backups, now: Date = Date()) {
        let cal = Calendar.current
        if !b.list().contains(where: { $0.reason == "daily" && cal.isDate($0.date, inSameDayAs: now) }) {
            takeBackup(b, reason: "daily", now: now)
        }
        do { try b.rotate(now: now) } catch { activity("backup", .warning, "Backup rotation failed; old backups were left in place", detail: "\(error)") }
    }
}
