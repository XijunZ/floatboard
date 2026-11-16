import Foundation
import SQLite3
import FloatBoardCore

/// A due date stores its day and whether it has a time, so changing the time zone never moves a task or turns a
/// date-only task into a timed one; and a board from before that keeps what each task meant.
@MainActor func dueStorageChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-due-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let savedZone = AppTime.zone
    defer { AppTime.zone = savedZone }
    AppTime.zone = TimeZone(identifier: "Europe/London")!
    let cal = AppTime.calendar
    func day(_ d: Date?) -> Int? { d.map { cal.component(.day, from: $0) } }

    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "due storage setup: \(error)"); return }
    func card(_ title: String) -> Card? { store.cards.last { $0.title == title } }
    let nov20 = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
    let nov20at15 = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
    let nov20at0 = nov20

    store.add(title: "Date only", area: "Personal", importance: .medium, due: nov20)
    store.add(title: "Timed", area: "Personal", importance: .medium, due: nov20at15, dueHasTime: true)
    store.add(title: "Midnight timed", area: "Personal", importance: .medium, due: nov20at0, dueHasTime: true)
    store.reload()
    check(card("Date only").map { !$0.dueHasTime && day($0.due) == 20 && $0.due == nov20 } ?? false, "due_date_only_round_trips")
    check(card("Timed").map { $0.dueHasTime && $0.due == nov20at15 } ?? false, "due_timed_round_trips")
    check(card("Midnight timed").map { $0.dueHasTime && $0.due == nov20at0 } ?? false, "due_midnight_can_be_timed")

    let flags = (try? store.db.query("SELECT due_has_time FROM cards ORDER BY id") { DB.int($0, 0) }) ?? [] // try?-ok: a failed query makes the check fail
    check(flags == [0, 1, 1], "due_flag_is_stored_per_task")
    let days = (try? store.db.query("SELECT due_day FROM cards ORDER BY id") { sqlite3_column_type($0, 0) == SQLITE_NULL ? "-" : DB.text($0, 0) }) ?? [] // try?-ok: a failed query makes the check fail
    check(days == ["2026-11-20", "-", "-"], "due_day_kept_only_for_date_only_tasks")

    // A date-only task stays on its day when the zone changes; a timed one stays at its instant.
    AppTime.zone = TimeZone(identifier: "Asia/Shanghai")!
    store.reload()
    check(card("Date only").map { !$0.dueHasTime && AppTime.calendar.component(.day, from: $0.due!) == 20
                                  && AppTime.calendar.component(.hour, from: $0.due!) == 0 } ?? false, "due_date_only_survives_zone_change")
    check(card("Timed")?.due == nov20at15 && card("Timed")?.dueHasTime == true, "due_timed_keeps_its_instant_across_zone_change")
    AppTime.zone = TimeZone(identifier: "Europe/London")!
    store.reload()

    // setDue: a day with no time, then with one.
    if let id = card("Date only")?.id {
        let nov21 = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 13))!   // any time of that day
        store.setDue(id, day: nov21, time: DateComponents(hour: 9, minute: 30), actor: .user)
        let timed = store.card(id)
        check(timed.map { $0.dueHasTime && cal.component(.hour, from: $0.due!) == 9 && day($0.due) == 21 } ?? false, "set_due_with_time")
        store.setDue(id, day: nov21, time: nil, actor: .user)
        let plain = store.card(id)
        check(plain.map { !$0.dueHasTime && cal.component(.hour, from: $0.due!) == 0 && day($0.due) == 21 } ?? false, "set_due_without_time")
        let who = (try? store.db.query("SELECT actor FROM events WHERE card_id=? AND kind LIKE 'due:%'", [id]) { DB.text($0, 0) }) ?? [] // try?-ok: a failed query makes the check fail
        check(who == ["user", "user"], "set_due_records_the_actor")
    } else { check(false, "set_due setup") }

    // Upgrading a v10 board keeps what each due meant: 00:00 in this Mac's zone was date-only, anything else had a time.
    let old = root.appendingPathComponent("v10.sqlite")
    do {
        _ = try DB(url: old)
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open(old.path, &h) == SQLITE_OK else { throw DBError.sql("cannot open") }
        let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20))!.timeIntervalSince1970
        let half2 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 14, minute: 30))!.timeIntervalSince1970
        let sql = """
            ALTER TABLE cards DROP COLUMN due_day; ALTER TABLE cards DROP COLUMN due_has_time; PRAGMA user_version = 10;
            INSERT INTO cards(title,area,due,status,created) VALUES('Old date only','Personal',\(midnight),'todo',1);
            INSERT INTO cards(title,area,due,status,created) VALUES('Old timed','Personal',\(half2),'todo',1);
            INSERT INTO cards(title,area,status,created) VALUES('Old no due','Personal','todo',1);
            """
        guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw DBError.sql("v10 setup") }
        sqlite3_close(h); h = nil
        let upgraded = Store(db: try DB(url: old))
        func up(_ t: String) -> Card? { upgraded.cards.first { $0.title == t } }
        check(up("Old date only").map { !$0.dueHasTime && $0.due == cal.date(from: DateComponents(year: 2026, month: 11, day: 20)) } ?? false
              && up("Old timed").map { $0.dueHasTime && $0.due?.timeIntervalSince1970 == half2 } ?? false
              && up("Old no due").map { $0.due == nil && !$0.dueHasTime } ?? false, "due_upgrade_keeps_meaning")
    } catch { check(false, "due_upgrade_keeps_meaning: \(error)") }
}
