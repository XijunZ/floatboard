import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Round 6 of the Codex review (codex-review-4.md: C1, C4).
@MainActor func codexRound6Checks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date,
                                  newTask: (Store, String, Date?, Bool) -> Int64, linkTask: (Store, Int64, String) -> Void) async {
    let acct = "me@example.com"
    let old = Date().addingTimeInterval(-86400)

    // C1. Two time moves queued offline (12:00-13:00, then 14:00-15:00); Google then moves only the start to 10:30. The first
    //     PATCH keeps Google's start and writes only the end, so it must acknowledge only the end: the second PATCH must still
    //     see Google's newer start and keep it.
    do {
        let (store, cache, outbox) = try setup("c1-partial-ack")
        let id = newTask(store, "Review", at(10, 0, 0), true)
        linkTask(store, id, "p1")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "p1", cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Review", googleUpdated: old, fbCard: id))], nextToken: nil)
        let server = StatefulEvent(id: "p1", title: "Review", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        if var c = store.card(id) { c.due = at(12, 0, 0); store.update(c, now: Date().addingTimeInterval(-3)) }
        if var c = store.card(id) { c.due = at(14, 0, 0); store.update(c, now: Date().addingTimeInterval(-2)) }
        server.externalEdit(start: at(10, 30, 0))
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        let ok = server.start == at(10, 30, 0) && server.end == at(15, 0, 0) && outbox.rows(unsent: true).isEmpty
        if !ok { print("  c1: server \(server.start) - \(server.end), unsent \(outbox.rows(unsent: true).count)") }
        check(ok, "c1_end_only_write_does_not_acknowledge_the_start")
    } catch { check(false, "c1: \(error)") }

    // C1. An acknowledgement saved before start and end were tracked apart (one "time" entry) still counts for both.
    do {
        let legacy = #"{"time":{"updated":100,"start":200,"end":300,"allDay":false}}"#
        let own = try JSONDecoder().decode(CalOwnWrite.self, from: Data(legacy.utf8))
        check(own.startAck?.updated == Date(timeIntervalSinceReferenceDate: 100) && own.endAck?.value == Date(timeIntervalSinceReferenceDate: 300),
              "c1_older_saved_time_acknowledgement_still_reads")
    } catch { check(false, "c1 legacy: \(error)") }

    await round6RecurrenceChecks()
}

/// C4: a repeating meeting's label converts the series' weekday and time together into the app's zone.
@MainActor private func round6RecurrenceChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-round6-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let savedZone = AppTime.zone
    defer { AppTime.zone = savedZone }
    AppTime.zone = TimeZone(identifier: "Europe/London")!
    let acct = "me@example.com", cid = "main-id"
    let iso = ISO8601DateFormatter()

    // Monday 23:00 in Los Angeles is Tuesday 07:00 in London (both on winter time): the phone shows "weekly Tue 07:00".
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("c4.sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cid, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
        let inst = #"{"id":"la_1","status":"confirmed","summary":"US sync","recurringEventId":"la","start":{"dateTime":"2026-11-24T07:00:00Z","timeZone":"America/Los_Angeles"},"end":{"dateTime":"2026-11-24T07:30:00Z","timeZone":"America/Los_Angeles"},"updated":"2026-11-16T10:00:00Z"}"#
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.url?.path.hasSuffix("/events/la") == true {
                return (#"{"recurrence":["RRULE:FREQ=WEEKLY;BYDAY=MO"],"start":{"dateTime":"2026-11-02T23:00:00-08:00","timeZone":"America/Los_Angeles"}}"#, 200)
            }
            return (#"{"items":[\#(inst)],"nextSyncToken":"T"}"#, 200)
        }
        await CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [acct] }).syncOnce()
        let now = iso.date(from: "2026-11-18T08:00:00Z")!
        let label = PhoneBoard.events(store: store, now: now).first { $0.title == "US sync" }?.repeatLabel
        if label != "weekly Tue 07:00" { print("  c4: label \(label ?? "nil")") }
        check(label == "weekly Tue 07:00", "c4_label_converts_weekday_and_time_together")
        check(cache.seriesMaster(account: acct, calendarID: cid, seriesID: "la")?.zone.identifier == "America/Los_Angeles",
              "c4_series_start_and_zone_are_kept_with_the_rule")
    } catch { check(false, "c4: \(error)") }

    // The rule in words with the series' zone: conversions, and no clock time when a clock change makes it differ by day.
    do {
        let la = TimeZone(identifier: "America/Los_Angeles")!, ldn = TimeZone(identifier: "Europe/London")!
        let mon23 = iso.date(from: "2026-11-02T23:00:00-08:00")!
        func range(_ a: String, _ b: String) -> DateInterval { DateInterval(start: iso.date(from: a)!, end: iso.date(from: b)!) }
        let nov = range("2026-11-16T00:00:00Z", "2026-11-30T00:00:00Z")
        // London left summer time on 25 Oct, Los Angeles on 1 Nov: in between 23:00 there is 06:00 in London, after it 07:00.
        let dst = range("2026-10-26T00:00:00Z", "2026-11-09T00:00:00Z")
        let inst = iso.date(from: "2026-11-24T07:00:00Z")!
        let cases: [(String, (start: Date, zone: TimeZone)?, DateInterval, String)] = [
            ("RRULE:FREQ=WEEKLY;BYDAY=MO", (mon23, la), nov, "weekly Tue 07:00"),
            ("RRULE:FREQ=WEEKLY", (mon23, la), nov, "weekly Tue 07:00"),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", (mon23, la), nov, "weekly Tue, Wed, Thu, Fri, Sat 07:00"),
            ("RRULE:FREQ=DAILY", (mon23, la), nov, "daily 07:00"),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO", (mon23, la), dst, "weekly Tue"),
            ("RRULE:FREQ=DAILY", (mon23, la), dst, "daily"),
            ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", (iso.date(from: "2026-11-02T09:00:00Z")!, ldn), nov, "weekdays 09:00"),
            ("RRULE:FREQ=MONTHLY;BYDAY=1MO", (mon23, la), nov, "monthly"),
        ]
        var ok = true
        for (rule, master, r, want) in cases {
            let got = RecurrenceLabel.text(rule: rule, start: inst, allDay: false, master: master, range: r)
            if got != want { ok = false; print("  c4 label \(rule) over \(r.start): \(got) (want \(want))") }
        }
        check(ok, "c4_labels_in_the_app_zone_and_no_time_across_a_clock_change")
    }

    // The amendment of version 11: a board already at 11 without the new columns gets them on open, keeps its rows and its
    // version, matches a new board, and opening it again changes nothing.
    do {
        let url = root.appendingPathComponent("v11-old.sqlite")
        func cols(_ db: DB) throws -> [String] { try db.query("PRAGMA table_info(cal_series)") { DB.text($0, 1) } }
        var before: [String] = []
        do {
            // A board at 11 from before the amendment (built from the v11 shape): it is amended, then upgraded.
            guard makeV11Schema(url, extra: """
                INSERT INTO cal_series(account, calendar_id, series_id, rule, read_at) VALUES('a','c','s','RRULE:FREQ=DAILY',1);
                ALTER TABLE cal_series DROP COLUMN master_start; ALTER TABLE cal_series DROP COLUMN master_zone;
                """) else { throw DBError.sql("v11 board setup") }
            before = rawColumns(url, "cal_series")
        }
        let fresh = root.appendingPathComponent("v11-new.sqlite")
        _ = try DB(url: fresh)
        func schemaSQL(_ db: DB) throws -> [String] {
            try db.query("SELECT sql FROM sqlite_master WHERE name='cal_series'") { DB.text($0, 0).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression) }
        }
        let db = try DB(url: url)
        let after = try cols(db)
        let again = try cols(DB(url: url))
        let version = try db.query("PRAGMA user_version") { DB.int($0, 0) }.first
        let rows = try db.query("SELECT rule, master_zone IS NULL FROM cal_series") { (DB.text($0, 0), DB.int($0, 1)) }
        check(!before.contains("master_start") && !before.contains("master_zone") && before.contains("rule"), "c4_v11_amend_setup")
        let sameSchema = try schemaSQL(db) == schemaSQL(DB(url: fresh))
        check(after.contains("master_start") && after.contains("master_zone") && again == after && version == Int64(DB.schemaVersion)
              && rows.count == 1 && rows.first?.0 == "RRULE:FREQ=DAILY" && rows.first?.1 == 1
              && sameSchema, "c4_existing_v11_board_gets_the_new_columns_in_place")
    } catch { check(false, "c4 v11 amend: \(error)") }
}
