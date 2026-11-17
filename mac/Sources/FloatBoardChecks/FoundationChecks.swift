import Foundation
import FloatBoardCore
import SQLite3

/// The assistant foundation (docs/superpowers/specs/2026-11-17-foundation-design.md): ids, schema 12, links with kinds,
/// tags, jots and people cores, modules, the reminder budget, the weekly review and search registries.
@MainActor func foundationChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-foundation-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    foundationIDChecks()
    foundationSchemaChecks(root)
    foundationLinkChecks(root)
}

/// Opens a scratch board in `root`.
@MainActor func foundationStore(_ root: URL, _ name: String) -> Store? {
    do { return Store(db: try DB(url: root.appendingPathComponent(name))) } catch { check(false, "foundation setup \(name): \(error)"); return nil }
}

@MainActor private func count(_ store: Store, _ sql: String, _ args: [Any?] = []) -> Int64 {
    ((try? store.db.query(sql, args) { DB.int($0, 0) }) ?? []).first ?? -1 // try?-ok: -1 fails the check
}

// MARK: 2. Ids

@MainActor private func foundationIDChecks() {
    let all: [(String, ItemKind)] = [("T-1", .task), ("E-2", .event), ("J-3", .jot), ("P-4", .person), ("D-5", .decision), ("R-6", .resolution)]
    check(all.allSatisfy { ShortID.parse($0.0)?.kind == $0.1 && ShortID.parse($0.0)?.text == $0.0 } && ShortID.parse("j-12")?.text == "J-12"
          && ShortID.parse("X-1") == nil && ShortID.parse("J-0") == nil && ShortID.parse("P-") == nil, "ids_parse_all_six_kinds")
    let text = "Follow up on t-12 and J-7 (see P-3, D-4; R-5). Not X-1, not AT-9, not T-12b, again T-12, and e-40."
    check(ShortID.mentions(in: text).map(\.text) == ["T-12", "J-7", "P-3", "D-4", "R-5", "E-40"], "mentions_found_in_order_once")
    check(ShortID.mentions(in: "no ids here; T-0 and J- and 12-T").isEmpty, "mentions_ignore_non_ids")
}

// MARK: 1. Schema 12

/// A board at version 11 built from the v11 fixture (its tables and indexes, nothing else), plus `extra` SQL.
func makeV11Schema(_ url: URL, extra: String = "") -> Bool {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/schema-v11.json")
    guard let data = try? Data(contentsOf: fixture), // try?-ok: nil fails the check
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return false } // try?-ok: nil fails the check
    // Tables first, then indexes (they need their tables).
    let sql = rows.filter { !($0[1] as? String ?? "").hasPrefix("sqlite_") }
        .sorted { ($0[0] as? String ?? "") > ($1[0] as? String ?? "") }.compactMap { $0[3] as? String }.joined(separator: ";\n")
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { return false }
    return sqlite3_exec(h, sql + ";\nPRAGMA user_version = 11;\n" + extra, nil, nil, nil) == SQLITE_OK
}

/// A board at version 11 with a task, its own event, a meeting link and a task made on the phone.
private func makeV11Board(_ url: URL) -> Bool {
    makeV11Schema(url, extra: """
        INSERT INTO areas(name,color,position) VALUES('Work','#0A84FF',0),('Personal','#30D158',1);
        INSERT INTO cards(id,title,area,status,created,gcal_account,gcal_calendar,gcal_event) VALUES(1,'Own event','Work','todo',1,'a@x','a@x','ev1');
        INSERT INTO cards(id,title,area,status,created) VALUES(2,'Meeting prep','Work','todo',1);
        INSERT INTO cards(id,title,area,status,created) VALUES(3,'From the phone','Personal','todo',1);
        INSERT INTO events(card_id,at,kind,actor,uuid) VALUES(3,1,'created (from the phone)','user','u3');
        INSERT INTO cal_events(short_id,account,calendar_id,event_id,start,end,all_day,title,google_updated) VALUES(10,'a@x','a@x','ev1',100,200,0,'Own event',1);
        INSERT INTO cal_events(short_id,account,calendar_id,event_id,start,end,all_day,title,google_updated,video_link) VALUES(11,'a@x','a@x','ev2',300,400,0,'Weekly sync',1,'https://meet.example.com/x');
        INSERT INTO links(from_type,from_id,to_type,to_id,created,actor) VALUES('E','10','T','1',1,'user'),('E','11','T','2',1,'user');
        """)
}

/// A table's column names, read without opening the board through DB (which would upgrade it).
func rawColumns(_ url: URL, _ table: String) -> [String] {
    var h: OpaquePointer?, st: OpaquePointer?
    defer { sqlite3_finalize(st); sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(h, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [String] = []
    while sqlite3_step(st) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(st, 1))) }
    return out
}

private func masterRows(_ url: URL) -> [[String?]] {
    var h: OpaquePointer?, st: OpaquePointer?
    defer { sqlite3_finalize(st); sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(h, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name", -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [[String?]] = []
    while sqlite3_step(st) == SQLITE_ROW { out.append((0..<4).map { i in sqlite3_column_text(st, Int32(i)).map { String(cString: $0) } }) }
    return out
}

private func normalizedSQL(_ rows: [[String?]]) -> [[String?]] {
    rows.map { $0.map { $0.map { s in
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    } } }
}

@MainActor private func foundationSchemaChecks(_ root: URL) {
    check(DB.schemaVersion == 12, "schema_version_is_12")
    let old = root.appendingPathComponent("v11.sqlite"), fresh = root.appendingPathComponent("fresh12.sqlite")
    guard makeV11Board(old) else { check(false, "v11 board setup"); return }
    guard let up = foundationStore(root, "v11.sqlite"), foundationStore(root, "fresh12.sqlite") != nil else { return }
    let upgraded = masterRows(old)
    check(!upgraded.isEmpty && normalizedSQL(upgraded) == normalizedSQL(masterRows(fresh)), "upgraded_board_matches_new_board")
    if let out = ProcessInfo.processInfo.environment["FLOATBOARD_WRITE_SCHEMA_FIXTURE"],
       let json = try? JSONSerialization.data(withJSONObject: upgraded.map { $0.map { $0.map { $0 as Any } ?? NSNull() as Any } }, options: [.prettyPrinted]) { // try?-ok: dev aid only
        do { try json.write(to: URL(fileURLWithPath: out)) } catch { check(false, "write schema fixture: \(error)") }
    }
    // Backfills: own event, phone task, fixed tags, kept events, modules on for an upgraded board.
    let kinds = (try? up.db.query("SELECT from_id, to_id, kind, made_by, subject FROM links ORDER BY from_id") { // try?-ok: empty fails the check
        "\(DB.text($0, 0))>\(DB.text($0, 1)):\(DB.text($0, 2))/\(DB.text($0, 3))/\(DB.text($0, 4))" }) ?? []
    check(kinds == ["10>1:own-event/auto/T-1", "11>2:related/manual/"], "upgrade_classifies_existing_links")
    check(up.card(3)?.itemSource == .phone && up.card(2)?.itemSource == .typed, "upgrade_marks_tasks_made_on_the_phone")
    check(count(up, "SELECT count(*) FROM areas WHERE fixed=1 AND name IN ('Investor','Prospect')") == 2
          && up.areas.map(\.name) == ["Work", "Personal"] && Set(up.tags.map(\.name)) == ["Work", "Personal", "Investor", "Prospect"],
          "fixed_tags_exist_but_are_not_board_groups")
    check(count(up, "SELECT count(*) FROM cal_kept WHERE short_id IN (10,11)") == 2, "upgrade_keeps_records_of_linked_events")
    check(up.modules == Set(Module.allCases), "upgraded_board_starts_with_all_areas_on")
    if let f = foundationStore(root, "fresh12.sqlite") {
        check(f.modules.isEmpty && f.areas.map(\.name) == ["Work", "Personal"], "new_board_starts_with_areas_off")
    }
}

// MARK: 1. Links

@MainActor private func foundationLinkChecks(_ root: URL) {
    guard let store = foundationStore(root, "links.sqlite") else { return }
    store.add(title: "Write the memo", area: "Personal", importance: .medium, due: nil)
    store.add(title: "Second task", area: "Personal", importance: .medium, due: nil)
    guard let a = store.cards.first(where: { $0.title == "Write the memo" }), let b = store.cards.first(where: { $0.title == "Second task" }) else {
        check(false, "links setup"); return
    }
    let t = ShortID(kind: .task, number: a.id), t2 = ShortID(kind: .task, number: b.id)
    guard let jot = JotStore(store: store).create(text: "Idea for the memo") else { check(false, "links setup: jot"); return }
    let j = jot.shortID

    check(store.link(t, j, kind: .source, madeBy: .manual, actor: .user), "link_with_kind_is_added")
    let fromTask = store.itemLinks(of: t).first, fromJot = store.itemLinks(of: j).first
    check(fromTask?.other == j && fromTask?.kind == .source && fromTask?.madeBy == .manual && fromTask?.isSubject == true
          && fromJot?.other == t && fromJot?.isSubject == false, "link_kind_direction_and_maker_read_back")
    // A manual link is never downgraded; an auto one is replaced by a manual one.
    check(!store.link(t, j, kind: .related, madeBy: .auto, actor: .user) && store.itemLinks(of: t).first?.kind == .source, "manual_link_not_downgraded")
    store.link(t2, j, kind: .related, madeBy: .suggested, actor: .user)
    store.link(j, t2, kind: .notesOf, madeBy: .manual, actor: .user)
    let n = store.itemLinks(of: j).first { $0.other == t2 }
    check(n?.kind == .notesOf && n?.madeBy == .manual && n?.isSubject == true && count(store, "SELECT count(*) FROM links") == 2,
          "one_row_per_pair_kind_replaced")

    // ✕ with Undo.
    store.unlinkWithUndo(t, j)
    check(store.links(of: t).isEmpty && store.lastUnlinked != nil, "unlink_with_undo_removes")
    store.undoUnlink()
    check(store.itemLinks(of: t).first?.kind == .source && store.lastUnlinked == nil, "undo_unlink_restores_kind")

    // Deleting an item hides its links (kept across a restart); Undo restores; the other item is never deleted.
    store.link(t, t2, actor: .user)
    store.delete(a)
    store.undoDelete()
    check(Set(store.links(of: t)) == [j, t2], "undo_delete_unhides_links")
    // Deleted on the phone; restored on the phone after the Mac restarted (no memory of the delete).
    _ = store.applyPhoneActions([PhoneAction(id: "fd1", clientID: "found-delete-1", cardID: a.id, action: "delete", madeAt: Date())],
                                connector: "ph", now: Date())
    check(store.links(of: t2) == [j] && store.links(of: j) == [t2] && count(store, "SELECT count(*) FROM links WHERE hidden_by=?", [t.text]) == 2
          && store.card(b.id) != nil, "delete_hides_links_keeps_other_items")
    guard let reopened = foundationStore(root, "links.sqlite") else { return }
    // The phone's restore (no memory of the delete after a restart).
    _ = reopened.applyPhoneActions([PhoneAction(id: "fr1", clientID: "found-restore-1", cardID: a.id, action: "restore",
                                                madeAt: Date().addingTimeInterval(1))], connector: "ph", now: Date().addingTimeInterval(1))
    check(Set(reopened.links(of: t)) == [j, t2] && reopened.itemLinks(of: t).first { $0.other == j }?.kind == .source,
          "restore_after_restart_unhides_links")
    // A jot deleted while the task is deleted: restoring the task leaves the jot's link hidden.
    JotStore(store: reopened).delete(jot.id)
    check(!reopened.links(of: t).contains(j) && reopened.links(of: t) == [t2], "deleted_jot_hides_its_links")
    JotStore(store: reopened).undoDelete(jot.id)
    check(reopened.links(of: t).contains(j), "jot_undo_restores_links")

    // Typing ids into a saved text links them (new ids only; unknown and self ignored).
    let s = reopened
    guard let memo = s.card(a.id) else { check(false, "mentions setup"); return }
    s.unlink(t, t2)
    var edited = memo; edited.notes = "See \(t2.text), \(t.text) and T-99999"
    s.update(edited)
    check(s.links(of: t).contains(t2) && s.itemLinks(of: t).first { $0.other == t2 }?.kind == .related
          && !s.links(of: t).contains(ShortID(kind: .task, number: 99999)), "typed_id_in_task_notes_links_it")
    s.unlinkWithUndo(t, t2)
    var again = s.card(a.id)!; again.notes += " more words"
    s.update(again)
    check(!s.links(of: t).contains(t2), "unlinked_id_left_in_text_is_not_relinked")
    // Store.item / itemExists for the built-in kinds.
    check(s.item(t)?.title == "Write the memo" && s.item(j)?.title == "Idea for the memo" && s.itemExists(t)
          && !s.itemExists(ShortID(kind: .decision, number: 1)), "item_catalog_knows_builtin_kinds")
}
