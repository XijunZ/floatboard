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
    jotsCoreChecks(root)
    taskNoteChecks(root)
    suggestionChecks(root)
    cleanupGuardChecks()
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

// MARK: J4, J5, J14 core

@MainActor private func jotsCoreChecks(_ root: URL) {
    guard let store = jotsStore(root, "core.sqlite") else { return }
    store.addArea("Health")
    let js = JotStore(store: store)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    guard let a = js.add("Budget: send the revised numbers", tags: ["Work", "nope", "health"], now: t0),
          let b = js.add("Run before work", now: t0.addingTimeInterval(60)),
          let c = js.add("Meeting notes for the budget review", kind: .meetingNotes, source: .meeting, origin: "fathom:abc", now: t0.addingTimeInterval(120)) else {
        check(false, "jots core setup"); return
    }
    check(store.itemTags(a.shortID) == ItemTags(primary: "Work", others: ["Health"]), "jot_add_keeps_known_tags_primary_first")
    check(js.add("again", origin: "fathom:abc")?.id == c.id && jotsCount(store, "SELECT count(*) FROM jots WHERE origin='fathom:abc'") == 1,
          "jot_origin_is_saved_once")
    check(js.list(JotQuery()).map(\.id) == [c.id, b.id, a.id], "jot_list_newest_first")
    check(js.list(JotQuery(text: "BUDGET")).map(\.id) == [c.id, a.id] && js.list(JotQuery(text: "budget work")).isEmpty == false
          && js.list(JotQuery(text: "budget run")).isEmpty, "jot_search_every_word")
    check(js.list(JotQuery(text: b.shortID.text)).map(\.id) == [b.id], "jot_search_by_id")
    check(js.list(JotQuery(tags: ["health"])).map(\.id) == [a.id], "jot_filter_by_any_tag")
    check(js.list(JotQuery(kinds: [.meetingNotes])).map(\.id) == [c.id], "jot_filter_by_kind")
    check(js.list(JotQuery()).first { $0.id == b.id }?.untagged == true, "untagged_jot_is_marked")
    js.update(a.id, text: "Budget: send the revised numbers to Ann", now: t0.addingTimeInterval(500))
    check(js.list(JotQuery(sort: .updated)).first?.id == a.id, "jot_sort_by_updated")
    check(js.list(JotQuery(sort: .tag)).map(\.id) == [a.id, c.id, b.id], "jot_sort_by_tag_untagged_last")
    // J14: history and restore.
    if let v = js.history(a.id).first {
        js.restore(a.id, to: v, now: t0.addingTimeInterval(600))
        check(js.jot(a.id)?.text == "Budget: send the revised numbers" && js.history(a.id).count == 2, "jot_restore_version_is_an_edit")
    } else { check(false, "jot_restore_version_is_an_edit") }
    js.delete(b.id, now: t0.addingTimeInterval(700))
    check(!js.list(JotQuery()).contains { $0.id == b.id }, "deleted_jot_leaves_the_list")
    js.undoDelete(b.id, now: t0.addingTimeInterval(800))
    check(js.list(JotQuery()).contains { $0.id == b.id }, "undo_delete_brings_jot_back")
    check(js.changed(since: t0.addingTimeInterval(650)).map(\.id) == [b.id], "jots_changed_since")
    check(js.setTags(b.id, ["Nope"]) != nil && js.setTags(b.id, ["Health", "Work"]) == nil
          && store.itemTags(b.shortID) == ItemTags(primary: "Health", others: ["Work"]), "jot_tags_set_first_primary")
    // Own jots today (for the nudge): typed or phone jots only, by the app's day.
    let now = Date()
    check(!js.ownJotAdded(on: now), "no_own_jot_today_yet")
    js.add("Task note text here", kind: .taskNote, now: now)
    js.add("Meeting", kind: .meetingNotes, source: .meeting, now: now)
    check(!js.ownJotAdded(on: now), "task_and_meeting_notes_do_not_count_as_jotted")
    js.add("From the phone", source: .phone, now: now)
    check(js.ownJotAdded(on: now), "phone_jot_counts_as_jotted")
}

// MARK: J10 task notes

@MainActor private func taskNoteChecks(_ root: URL) {
    guard let store = jotsStore(root, "notes.sqlite") else { return }
    store.add(title: "Prepare the offsite", area: "Work", importance: .medium, due: nil)
    guard var card = store.cards.first else { check(false, "task notes setup"); return }
    let js = JotStore(store: store)
    store.setTags(ShortID(kind: .task, number: card.id), primary: "Work", others: ["Personal"])
    card = store.card(card.id) ?? card
    card.notes = "Short"
    store.update(card)
    check(js.taskNote(forTask: card.id) == nil, "short_task_notes_make_no_jot")
    card.notes = "Book the venue and the train"
    store.update(card)
    guard let note = js.taskNote(forTask: card.id) else { check(false, "task_notes_from_10_chars_make_a_jot"); return }
    check(note.kind == .taskNote && note.text == "Book the venue and the train", "task_notes_from_10_chars_make_a_jot")
    check(store.itemTags(note.shortID).all == ["Work", "Personal"], "task_note_jot_has_the_tasks_tags")
    let link = store.itemLinks(of: note.shortID).first { $0.other == ShortID(kind: .task, number: card.id) }
    check(link?.kind == .notesOf && link?.madeBy == .auto && link?.isSubject == true, "task_note_jot_is_notes_of_the_task")
    card = store.card(card.id) ?? card
    card.notes = "Book the venue, the train and dinner"
    store.update(card)
    check(js.jot(note.id)?.text == card.notes && js.history(note.id).map(\.text) == ["Book the venue and the train"]
          && jotsCount(store, "SELECT count(*) FROM jots WHERE task_id=?", [card.id]) == 1, "task_editor_edit_updates_the_same_jot")
    // Editing the jot in the Jots tab changes the task's notes (one record).
    js.update(note.id, text: "Venue booked; train next")
    check(store.card(card.id)?.notes == "Venue booked; train next", "editing_note_jot_changes_task_notes")
    // Deleting the note jot empties the task's notes; Undo brings them back.
    js.delete(note.id)
    check(store.card(card.id)?.notes == "", "deleting_note_jot_empties_task_notes")
    js.undoDelete(note.id)
    check(store.card(card.id)?.notes == "Venue booked; train next", "undo_note_jot_delete_restores_notes")
    // Deleting the task keeps the note jot (it can tell its task was deleted).
    if let c = store.card(card.id) { store.deleteCard(c, verdict: nil) }
    check(js.jot(note.id)?.deleted == false && js.taskID(ofNote: note.id) == card.id
          && store.item(ShortID(kind: .task, number: card.id))?.deleted == true, "deleting_task_keeps_note_jot")
    store.undoDelete()
    check(store.card(card.id)?.notes == "Venue booked; train next", "task_undo_keeps_notes")
}

// MARK: J5 tag suggestions

@MainActor private func suggestionChecks(_ root: URL) {
    guard let store = jotsStore(root, "suggest.sqlite") else { return }
    let js = JotStore(store: store), sg = JotSuggestions(store: store)
    guard let a = js.add("Gym three times"), let b = js.add("Tagged one", tags: ["Work"]), let c = js.add("Quarter plan") else {
        check(false, "suggestions setup"); return
    }
    check(sg.toAsk().map(\.id) == [a.id, c.id], "untagged_new_jots_are_asked_about")
    sg.record(asked: [a.id, c.id], suggestions: [a.id: ["Personal", "Unknown"], c.id: ["Work", "Personal"]])
    check(sg.toAsk().isEmpty, "a_jot_is_asked_about_once")
    check(sg.open(a.id) == ["Personal"] && sg.open(c.id) == ["Work", "Personal"], "only_known_tags_are_suggested")
    sg.accept(c.id, "Work")
    sg.dismiss(c.id, "Personal")
    check(store.itemTags(c.shortID) == ItemTags(primary: "Work", others: []) && sg.open(c.id).isEmpty, "accept_adds_tag_dismiss_hides")
    _ = b
}

// MARK: J6 cleanup guard

private func cleanupGuardChecks() {
    let original = "Call Ann re T-12 about £4,500 by 14:30 on 3/12; see https://example.com/doc and @sam #budget"
    check(CleanupGuard.missing(original: original, cleaned: original.replacingOccurrences(of: "re", with: "about")).isEmpty, "cleanup_guard_passes_kept_substance")
    check(CleanupGuard.missing(original: original, cleaned: "Call Ann about the budget, see the doc").sorted()
          == ["#budget", "14:30", "3/12", "4,500", "@sam", "T-12", "https://example.com/doc"].sorted(), "cleanup_guard_lists_dropped_substance")
}
