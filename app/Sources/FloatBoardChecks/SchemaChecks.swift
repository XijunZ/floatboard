import Foundation
import FloatBoardCore
import SQLite3

/// Reads rows straight from SQLite on a read-only connection, bypassing DB (which may refuse the file).
private func rawRows(_ url: URL, _ sql: String) -> [[String?]] {
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    var st: OpaquePointer?
    defer { sqlite3_finalize(st) }
    guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [[String?]] = []
    while sqlite3_step(st) == SQLITE_ROW {
        out.append((0..<sqlite3_column_count(st)).map { i in sqlite3_column_text(st, i).map { String(cString: $0) } })
    }
    return out
}

private func rawExec(_ url: URL, _ sql: String) -> Bool {
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    return sqlite3_open(url.path, &h) == SQLITE_OK && sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK
}

/// Stored CREATE statements differ only in layout between a new board and an upgraded one (ALTER TABLE ADD COLUMN
/// appends ", col ..." to the stored text), so whitespace is collapsed and dropped around brackets and commas.
private func normalized(_ rows: [[String?]]) -> [[String?]] {
    rows.map { $0.map { $0.map { s in
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    } } }
}

@MainActor func schemaChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-schema-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? fm.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let masterSQL = "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"

    // A new board gets exactly the schema of the real board, which reached version 8 by upgrading from 7.
    let fresh = root.appendingPathComponent("fresh.sqlite")
    do { _ = try DB(url: fresh) } catch { check(false, "new_board_opens: \(error)") }
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/schema-v9.json")
    var expected: [[String?]] = []
    do {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[Any]] ?? []
        expected = rows.map { $0.map { $0 as? String } }
    } catch { check(false, "schema fixture: \(error)") }
    let actual = rawRows(fresh, masterSQL)
    check(!expected.isEmpty && normalized(actual) == normalized(expected), "new_board_schema_matches_upgraded_board")
    check(rawRows(fresh, "PRAGMA user_version") == [[String(DB.schemaVersion)]] && !Backups.migrationCheck(fresh).needed,
          "new_board_is_current_version")
    do { _ = try DB(url: fresh) } catch { check(false, "current_board_reopens: \(error)") }
    check(rawRows(fresh, masterSQL) == actual, "reopening_current_board_changes_nothing")

    // A board from an older version (an old backup copied back by hand) is refused with a clear message and left as it was.
    for version in [0, 6] {
        let old = root.appendingPathComponent("v\(version).sqlite")
        let name = "old_board_v\(version)_refused_unchanged"
        guard (try? fm.copyItem(at: fresh, to: old)) != nil, rawExec(old, "PRAGMA user_version = \(version)"), // try?-ok: failure fails the check
              let before = try? Data(contentsOf: old) else { check(false, name + ": setup"); continue } // try?-ok: failure fails the check
        var thrown: Error?
        do { _ = try DB(url: old) } catch { thrown = error }
        var tooOld = false
        if let e = thrown as? DBError, case .tooOld = e { tooOld = true }
        let message = thrown.map { "\($0)" } ?? ""
        let after = try? Data(contentsOf: old) // try?-ok: nil fails the check
        let sideFiles = ["-journal", "-wal", "-shm"].filter { fm.fileExists(atPath: old.path + $0) }
        check(tooOld && message.contains("backup from an older FloatBoard") && message.contains("cannot be opened")
              && !message.contains("\u{2014}") && after == before && sideFiles.isEmpty, name)
        check(Backups.migrationCheck(old).needed, "old_board_v\(version)_counts_as_needing_migration")
    }

    // Restoring such a backup is refused before anything is touched (the app could not start on it).
    do {
        let current = root.appendingPathComponent("current.sqlite")
        try fm.copyItem(at: fresh, to: current)
        do { try DB(url: current).run("INSERT INTO areas(name,color,position) VALUES('Mine','#000000',1)") }
        let before = try Data(contentsOf: current)
        let b = Backups(dbURL: current, dir: root.appendingPathComponent("bk"))
        var message = ""
        do { try b.restore(root.appendingPathComponent("v6.sqlite")) } catch { message = "\(error)" }
        let after = try Data(contentsOf: current)
        check(message.contains("backup from an older FloatBoard") && after == before && b.list().isEmpty,
              "restore_refuses_backup_from_older_version")
    } catch { check(false, "restore_refuses_backup_from_older_version: \(error)") }

    // The Restore menu only offers backups this version can open.
    do {
        let bk = root.appendingPathComponent("bk-list")
        try fm.createDirectory(at: bk, withIntermediateDirectories: true)
        try fm.copyItem(at: root.appendingPathComponent("v6.sqlite"), to: bk.appendingPathComponent("board-20261101-090000-daily.sqlite"))
        try fm.copyItem(at: fresh, to: bk.appendingPathComponent("board-20261102-090000-daily.sqlite"))
        let b = Backups(dbURL: root.appendingPathComponent("current.sqlite"), dir: bk)
        let offered = b.restorable().map { $0.url.lastPathComponent }
        check(b.list().count == 2 && offered == ["board-20261102-090000-daily.sqlite"], "restore_menu_hides_backups_from_older_versions")
    } catch { check(false, "restore_menu_hides_backups_from_older_versions: \(error)") }
}
