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

    // The upgrade reads the day in this Mac's zone, not the app zone: a midnight due made in Shanghai keeps its day.
    do {
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Shanghai", 1); tzset(); NSTimeZone.resetSystemTimeZone()
        defer { if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }; tzset(); NSTimeZone.resetSystemTimeZone() }
        let shanghai = root.appendingPathComponent("v10-shanghai.sqlite")
        do {
            _ = try DB(url: shanghai)
            var h: OpaquePointer?
            defer { sqlite3_close(h) }
            guard sqlite3_open(shanghai.path, &h) == SQLITE_OK else { throw DBError.sql("cannot open") }
            let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20))!.timeIntervalSince1970
            let sql = """
                ALTER TABLE cards DROP COLUMN due_day; ALTER TABLE cards DROP COLUMN due_has_time; PRAGMA user_version = 10;
                INSERT INTO cards(title,area,due,status,created) VALUES('Shanghai midnight','Personal',\(midnight),'todo',1);
                """
            guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw DBError.sql("v10 setup") }
            sqlite3_close(h); h = nil
            let db = try DB(url: shanghai)
            let rows = try db.query("SELECT due_day, due_has_time FROM cards") { (DB.text($0, 0), DB.int($0, 1)) }
            check(rows.count == 1 && rows[0].0 == "2026-11-20" && rows[0].1 == 0, "due_upgrade_day_uses_mac_zone_at_upgrade")
        } catch { check(false, "due_upgrade_day_uses_mac_zone_at_upgrade: \(error)") }
    }

    // The engine's has_time decides whether a proposal's due is timed.
    do {
        func prop(_ due: String, hasTime: Bool?, mid: String) -> Proposal? {
            var json: [String: Any] = ["id": mid, "kind": "task", "source_key": ["message_id": mid, "sent_at": "2026-11-01T09:00:00Z"],
                                       "title": "T", "why": "w", "due": due, "importance": 1, "source_label": "x", "link": "",
                                       "provenance": ["model": "m", "skill_version": "1", "created": "2026-11-01T09:00:00Z"]]
            if let hasTime { json["has_time"] = hasTime }
            return try? JSONDecoder().decode(Proposal.self, from: JSONSerialization.data(withJSONObject: json)) // try?-ok: nil fails the check
        }
        let cases: [(String, Bool?, Bool, String)] = [
            ("2026-11-20T00:00", false, false, "due_proposal_midnight_with_has_time_false_is_date_only"),
            ("2026-11-20T00:00", true, true, "due_proposal_midnight_with_has_time_true_is_timed"),
            ("2026-11-20", true, false, "due_proposal_without_T_is_never_timed"),
            ("2026-11-20T00:00", nil, false, "due_proposal_missing_has_time_midnight_is_date_only"),
            ("2026-11-20T14:30", nil, true, "due_proposal_missing_has_time_uses_old_rule_for_a_time"),
        ]
        for (i, c) in cases.enumerated() {
            guard let p = prop(c.0, hasTime: c.1, mid: "<due\(i)@x>") else { check(false, c.3 + ": decode"); continue }
            do {
                try Reconciler.apply([p], connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
                let got = store.cards.first { $0.sourceKey?.messageID == "<due\(i)@x>" }
                check(got.map { $0.dueHasTime == c.2 && $0.due != nil } ?? false, c.3)
            } catch { check(false, c.3 + ": \(error)") }
        }
    }
}

/// The app's time zone: London unless set, saved on the board, and every date and time on screen follows it.
@MainActor func appTimeChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-apptime-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let savedSetting = AppTime.setting
    defer { AppTime.apply(savedSetting) }
    let savedTZ = ProcessInfo.processInfo.environment["TZ"]
    func setProcessZone(_ id: String) { setenv("TZ", id, 1); tzset(); NSTimeZone.resetSystemTimeZone() }
    defer { if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }; tzset(); NSTimeZone.resetSystemTimeZone() }
    let london = TimeZone(identifier: "Europe/London")!, shanghai = TimeZone(identifier: "Asia/Shanghai")!

    let db: DB
    do { db = try DB(url: root.appendingPathComponent("board.sqlite")) } catch { check(false, "app time setup: \(error)"); return }
    AppTime.load(from: db)
    check(AppTime.zone == london && !AppTime.followsMac && AppTime.setting == "Europe/London", "app_time_default_is_london")

    setProcessZone("Asia/Tokyo")
    do {
        try AppTime.save("mac", to: db)
        check(AppTime.followsMac && AppTime.zone == TimeZone(identifier: "Asia/Tokyo")! && AppTime.calendar.timeZone == AppTime.zone, "app_time_follow_mac_uses_system_zone")
        setProcessZone("America/New_York")
        check(AppTime.zone == TimeZone(identifier: "America/New_York")!, "app_time_follow_mac_tracks_the_mac_zone")
        AppTime.apply("Europe/London")
        AppTime.load(from: db)
        check(AppTime.followsMac, "app_time_setting_is_saved_on_the_board")
        try AppTime.save("Asia/Shanghai", to: db)
        AppTime.apply("Europe/London")
        AppTime.load(from: db)
        check(AppTime.zone == shanghai && !AppTime.followsMac, "app_time_fixed_zone_is_saved_on_the_board")
        try AppTime.save("Not/AZone", to: db)
        check(AppTime.zone == shanghai, "app_time_rejects_an_unknown_zone")
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('time_zone','Not/AZone')")
        AppTime.load(from: db)
        check(AppTime.zone == london, "app_time_unknown_saved_zone_falls_back_to_london")
    } catch { check(false, "app time save: \(error)") }
    AppTime.apply("Europe/London")

    // Every formatter reads the zone at call time: 09:00 UTC in July is 10:00 in London and 17:00 in Shanghai.
    let instant = ISO8601DateFormatter().date(from: "2026-07-01T09:00:00Z")!
    check(Fmt.clock(instant) == "10:00", "formatters_use_app_zone_london")
    AppTime.apply("Asia/Shanghai")
    check(Fmt.clock(instant) == "17:00" && Fmt.withTime(instant) == "2026-07-01 17:00" && Fmt.csvDate(instant) == "2026-07-01 17:00", "formatters_use_app_zone")
    AppTime.apply("Pacific/Pago_Pago")   // UTC-11: still the day before
    check(Fmt.short(instant) == "2026-06-30" && Fmt.heading(instant).hasPrefix("2026-06-30"), "formatters_follow_a_zone_change_without_a_restart")
    AppTime.apply("Europe/London")

    // "Today" is the app zone's today: a date-only due for today in each zone is due today in that zone.
    var todayOK = true
    for id in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/London"] {
        AppTime.apply(id)
        let c = Card(id: 1, title: "t", notes: "", area: "Work", importance: .medium, due: Due.startOfDay(Due.dayString(Date())),
                     status: .todo, created: Date(), started: nil, done: nil, dueHasTime: false)
        todayOK = todayOK && c.dueInDays == 0 && !c.isOverdue
    }
    check(todayOK, "today_follows_app_zone")
    AppTime.apply("Europe/London")

    // The editor's path: a day picked, no time. A Mac in Shanghai must not move a London date-only task.
    setProcessZone("Asia/Shanghai")
    let picked = AppTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 0, minute: 30))!
    let due = Due.combine(day: picked, time: nil)
    let store = Store(db: db)
    store.add(title: "Editor path", area: "Personal", importance: .medium, due: due)
    let storedDay = (try? db.query("SELECT due_day FROM cards WHERE title='Editor path'") { DB.text($0, 0) })?.first // try?-ok: nil fails the check
    let shown = store.cards.last { $0.title == "Editor path" }?.due
    check(storedDay == "2026-11-20" && shown == AppTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))
          && shown.map(Fmt.short) == "2026-11-20", "date_only_via_editor_path_keeps_day_under_shanghai")
    check(Reconciler.parseDue("2026-11-20").map { Due.dayString($0) } == "2026-11-20" && Reconciler.parseDue("2026-07-01T09:00") == ISO8601DateFormatter().date(from: "2026-07-01T08:00:00Z"),
          "parse_due_defaults_to_app_zone")

    // A legacy proposal (no has_time) at 00:00 is date-only by the app zone's midnight, not the Mac's.
    do {
        let json: [String: Any] = ["id": "<legacy@x>", "kind": "task", "source_key": ["message_id": "<legacy@x>", "sent_at": "2026-11-01T09:00:00Z"],
                                   "title": "Legacy", "why": "w", "due": "2026-11-20T00:00", "importance": 1, "source_label": "x", "link": "",
                                   "provenance": ["model": "m", "skill_version": "1", "created": "2026-11-01T09:00:00Z"]]
        if let data = try? JSONSerialization.data(withJSONObject: json), let p = try? JSONDecoder().decode(Proposal.self, from: data) { // try?-ok: nil fails the check
            do {
                try Reconciler.apply([p], connector: "email", store: store, defaultGroup: "Personal", autoAdd: true)
                let got = store.cards.first { $0.sourceKey?.messageID == "<legacy@x>" }
                check(got.map { !$0.dueHasTime && Due.dayString($0.due!) == "2026-11-20" } ?? false, "due_legacy_midnight_proposal_is_date_only_with_mac_in_shanghai")
            } catch { check(false, "due_legacy_midnight_proposal_is_date_only_with_mac_in_shanghai: \(error)") }
        } else { check(false, "legacy proposal decode") }
    }

    // And on a Mac in New York everything treats it as the 20th.
    setProcessZone("America/New_York")
    let nov20 = Due.startOfDay("2026-11-20")!
    let task = Card(id: 2, title: "t", notes: "", area: "Work", importance: .medium, due: nov20, status: .todo, created: Date(), started: nil, done: nil, dueHasTime: false)
    let url = task.googleCalendarURL?.absoluteString ?? ""
    check(Fmt.short(nov20) == "2026-11-20" && Fmt.due(nov20, hasTime: false) == "2026-11-20" && Fmt.heading(nov20).hasPrefix("2026-11-20")
          && url.contains("dates=20261120/20261121") && task.dueSortKey.map { Due.dayString($0) } == "2026-11-20"
          && task.dueInDays != nil, "date_only_shown_same_day_in_new_york")
    var nyOverdue = Card(id: 3, title: "t", notes: "", area: "Work", importance: .medium, due: Due.startOfDay("2020-01-01"), status: .todo, created: Date(), started: nil, done: nil, dueHasTime: false)
    check(nyOverdue.isOverdue && Fmt.short(nyOverdue.due!) == "2020-01-01", "date_only_overdue_in_new_york")
    nyOverdue.due = Due.startOfDay(Due.dayString(Date()))
    check(nyOverdue.dueInDays == 0 && !nyOverdue.isOverdue, "date_only_today_in_new_york")
}
