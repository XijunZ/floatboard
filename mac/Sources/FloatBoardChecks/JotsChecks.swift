import Foundation
import FloatBoardCore
import FloatBoardConnectors
import SQLite3

/// Jots (docs/superpowers/specs/2026-11-17-jots-design.md): schema 13, the Jots core (query, tags, history), task notes,
/// meeting notes matched to events, tag suggestions, cleanup guard, daily files, the daily nudge and the engine sync.
@MainActor func jotsChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-jots-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    jotsSchemaChecks(root)
}

@MainActor func jotsStore(_ root: URL, _ name: String) -> Store? {
    do { return Store(db: try DB(url: root.appendingPathComponent(name))) } catch { check(false, "jots setup \(name): \(error)"); return nil }
}

@MainActor func jotsCount(_ store: Store, _ sql: String, _ args: [Any?] = []) -> Int64 {
    ((try? store.db.query(sql, args) { DB.int($0, 0) }) ?? []).first ?? -1 // try?-ok: -1 fails the check
}

// MARK: Schema 13

/// A board at version 12 built from the v12 fixture (tables, indexes and triggers), plus `extra` SQL.
private func makeV12Board(_ url: URL, extra: String = "") -> Bool {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/schema-v12.json")
    guard let data = try? Data(contentsOf: fixture), // try?-ok: nil fails the check
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return false } // try?-ok: nil fails the check
    let order = ["table": 0, "index": 1, "trigger": 2]
    let sql = rows.filter { !($0[1] as? String ?? "").hasPrefix("sqlite_") && $0[3] is String }
        .sorted { order[$0[0] as? String ?? "", default: 3] < order[$1[0] as? String ?? "", default: 3] }
        .compactMap { $0[3] as? String }.joined(separator: ";\n")
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { return false }
    return sqlite3_exec(h, sql + ";\nPRAGMA user_version = 12;\n" + extra, nil, nil, nil) == SQLITE_OK
}

private func schemaRows(_ url: URL) -> [String] {
    var h: OpaquePointer?, st: OpaquePointer?
    defer { sqlite3_finalize(st); sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(h, "SELECT type||' '||name||' '||coalesce(sql,'') FROM sqlite_master ORDER BY type, name", -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [String] = []
    while sqlite3_step(st) == SQLITE_ROW {
        out.append(String(cString: sqlite3_column_text(st, 0)).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression))
    }
    return out
}

@MainActor private func jotsSchemaChecks(_ root: URL) {
    check(DB.schemaVersion >= 13, "jots_schema_version_is_13")
    let old = root.appendingPathComponent("v12.sqlite")
    guard makeV12Board(old, extra: """
        INSERT INTO areas(name,color,position) VALUES('Work','#0A84FF',0);
        INSERT INTO jots(id,text,kind,source,added,updated) VALUES(1,'An old jot','jot','typed',1,1);
        """) else { check(false, "v12 board setup"); return }
    guard let up = jotsStore(root, "v12.sqlite"), jotsStore(root, "fresh13.sqlite") != nil else { return }
    let upgraded = schemaRows(old), fresh = schemaRows(root.appendingPathComponent("fresh13.sqlite"))
    check(!upgraded.isEmpty && upgraded == fresh, "jots_v12_upgrade_matches_new_board")
    let tables = Set(upgraded.compactMap { $0.hasPrefix("table ") ? $0.split(separator: " ")[1].description : nil })
    check(tables.isSuperset(of: ["jot_meetings", "jot_suggestions", "jot_sync"]), "jots_tables_exist")
    check(JotStore(store: up).jot(1)?.text == "An old jot" && jotsCount(up, "SELECT count(*) FROM jots WHERE origin='' AND task_id IS NULL") == 1,
          "jots_upgrade_keeps_existing_jots")
}
