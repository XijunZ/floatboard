import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Round 7 of the Codex review (codex-review-5.md): conflicts with Google are decided by value, then newest wins.
@MainActor func codexRound7Checks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date) async {
    let acct = "me@example.com"
    let old = Date().addingTimeInterval(-86400)
    let now = Date()
    func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }

    /// A plain event 10:00-11:00; `queue` patches queued at given times; Google moves the start to 10:30 at `googleAt`.
    func run(_ name: String, googleAt: Date, queue: [(start: Date?, end: Date?, at: Date)]) async throws -> (StatefulEvent, CalendarOutbox) {
        let (store, cache, outbox) = try setup(name)
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: name, cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Call", googleUpdated: old))], nextToken: nil)
        let server = StatefulEvent(id: name, title: "Call", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        var edited = false
        for q in queue {
            if !edited && googleAt < q.at { server.externalEdit(start: at(10, 30, 0), at: googleAt); edited = true }
            _ = outbox.enqueue(.patch(eventID: name, title: nil, start: q.start, end: q.end, allDayStart: nil), account: acct, calendarID: acct, now: q.at)
        }
        if !edited { server.externalEdit(start: at(10, 30, 0), at: googleAt) }
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        return (server, outbox)
    }
    func report(_ name: String, _ s: StatefulEvent, _ want: (Date, Date)) -> Bool {
        let ok = s.start == want.0 && s.end == want.1
        if !ok { print("  \(name): server \(s.start) - \(s.end)") }
        return ok
    }

    // R7-1, Codex's trace: 12:00-13:00 queued, Google moves the start to 10:30, then 14:00-15:00 queued. The second move is
    // newer than Google's change: it is sent whole (the first move's end-only write must not make Google's start look newer).
    do {
        let (s, o) = try await run("r7-between", googleAt: ago(20), queue: [(at(12, 0, 0), at(13, 0, 0), ago(30)), (at(14, 0, 0), at(15, 0, 0), ago(10))])
        check(report("r7 between", s, (at(14, 0, 0), at(15, 0, 0))) && o.rows(unsent: true).isEmpty, "r7_google_edit_between_queued_moves_newer_move_wins")
    } catch { check(false, "r7 between: \(error)") }

    // Google's change after both moves were queued: Google's start wins over both; the board's last end stays.
    do {
        let (s, o) = try await run("r7-after", googleAt: ago(5), queue: [(at(12, 0, 0), at(13, 0, 0), ago(30)), (at(14, 0, 0), at(15, 0, 0), ago(10))])
        check(report("r7 after", s, (at(10, 30, 0), at(15, 0, 0))) && o.rows(unsent: true).isEmpty, "r7_google_edit_after_queued_moves_google_start_wins")
    } catch { check(false, "r7 after: \(error)") }

    // An end-only change (a resize), then a move; Google's start change came between them: the move is newer and is sent.
    do {
        let (s, _) = try await run("r7-endonly", googleAt: ago(20), queue: [(nil, at(11, 30, 0), ago(30)), (at(13, 0, 0), at(14, 0, 0), ago(10))])
        check(report("r7 end-only", s, (at(13, 0, 0), at(14, 0, 0))), "r7_end_only_write_updates_only_the_end_baseline")
    } catch { check(false, "r7 end-only: \(error)") }

    // An end-only change queued before Google's start change: the start stays Google's, the end is the board's.
    do {
        let (s, _) = try await run("r7-endonly2", googleAt: ago(10), queue: [(nil, at(11, 30, 0), ago(30))])
        check(report("r7 end-only 2", s, (at(10, 30, 0), at(11, 30, 0))), "r7_end_only_change_keeps_googles_start")
    } catch { check(false, "r7 end-only 2: \(error)") }

    await round7OriginalStartChecks()

    // Round 8: Google independently sets the value the first of two queued edits sends (after both were queued). That first
    // edit must not turn Google's newer change into FloatBoard's own: the second, older edit must not overwrite it.
    do {
        let (store, cache, outbox) = try setup("r8-renames")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "r8t", cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "A", googleUpdated: old))], nextToken: nil)
        let server = StatefulEvent(id: "r8t", title: "A", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        _ = outbox.enqueue(.patch(eventID: "r8t", title: "B", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct, now: ago(30))
        _ = outbox.enqueue(.patch(eventID: "r8t", title: "C", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct, now: ago(20))
        server.externalEdit(title: "B", at: ago(10))
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        if server.title != "B" { print("  r8 renames: server title \(server.title)") }
        check(server.title == "B" && outbox.rows(unsent: true).isEmpty, "r8_google_setting_the_first_queued_title_keeps_it_over_the_second")
    } catch { check(false, "r8 renames: \(error)") }
    do {
        let (store, cache, outbox) = try setup("r8-moves")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "r8m", cancelled: false,
            fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Call", googleUpdated: old))], nextToken: nil)
        let server = StatefulEvent(id: "r8m", title: "Call", start: at(10, 0, 0), end: at(11, 0, 0), updated: old)
        _ = outbox.enqueue(.patch(eventID: "r8m", title: nil, start: at(12, 0, 0), end: at(13, 0, 0), allDayStart: nil), account: acct, calendarID: acct, now: ago(30))
        _ = outbox.enqueue(.patch(eventID: "r8m", title: nil, start: at(14, 0, 0), end: at(15, 0, 0), allDayStart: nil), account: acct, calendarID: acct, now: ago(20))
        server.externalEdit(start: at(12, 0, 0), end: at(13, 0, 0), at: ago(10))
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        check(report("r8 moves", server, (at(12, 0, 0), at(13, 0, 0))) && outbox.rows(unsent: true).isEmpty,
              "r8_google_setting_the_first_queued_time_keeps_it_over_the_second")
    } catch { check(false, "r8 moves: \(error)") }
}

/// R7-2: each instance's original start (Google's originalStartTime) is kept and sent to the phone; the column is part of
/// the amended version 11 and is added in place to a board already at 11 without it.
@MainActor func round7OriginalStartChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-round7-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let savedZone = AppTime.zone
    defer { AppTime.zone = savedZone }
    AppTime.zone = TimeZone(identifier: "Europe/London")!
    let acct = "me@example.com", cid = "main-id"
    let iso = ISO8601DateFormatter()
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("orig.sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cid, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
        let moved = #"{"id":"st_1","status":"confirmed","summary":"Standup","recurringEventId":"st","start":{"dateTime":"2026-11-21T09:00:00Z"},"end":{"dateTime":"2026-11-21T09:15:00Z"},"originalStartTime":{"dateTime":"2026-11-20T09:00:00Z","timeZone":"Europe/London"},"updated":"2026-11-16T10:00:00Z"}"#
        let kept = #"{"id":"st_2","status":"confirmed","summary":"Standup","recurringEventId":"st","start":{"dateTime":"2026-11-19T09:00:00Z"},"end":{"dateTime":"2026-11-19T09:15:00Z"},"originalStartTime":{"dateTime":"2026-11-19T09:00:00Z"},"updated":"2026-11-16T10:00:00Z"}"#
        let allDay = #"{"id":"od_1","status":"confirmed","summary":"Off-site","recurringEventId":"od","start":{"date":"2026-11-25"},"end":{"date":"2026-11-26"},"originalStartTime":{"date":"2026-11-23"},"updated":"2026-11-16T10:00:00Z"}"#
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.url?.path.contains("/events/") == true { return (#"{"recurrence":["RRULE:FREQ=WEEKLY"]}"#, 200) }
            return (#"{"items":[\#(moved),\#(kept),\#(allDay)],"nextSyncToken":"T"}"#, 200)
        }
        await CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [acct] }).syncOnce()
        let events = PhoneBoard.events(store: store, now: iso.date(from: "2026-11-18T08:00:00Z")!)
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func orig(_ start: String) -> String? { events.first { $0.start.hasPrefix(start) }?.originalStart }
        let body = String(decoding: try PhoneBoard.body([], events: events), as: UTF8.self)
        let ok = orig("2026-11-21T09:00").flatMap { frac.date(from: $0) } == iso.date(from: "2026-11-20T09:00:00Z")
            && orig("2026-11-19T09:00").flatMap { frac.date(from: $0) } == iso.date(from: "2026-11-19T09:00:00Z")
            && orig("2026-11-25T00:00").flatMap { frac.date(from: $0) } == iso.date(from: "2026-11-23T00:00:00Z")
            && body.contains("\"original_start\"")
        if !ok { print("  r7 original: \(events.map { "\($0.start) <- \($0.originalStart ?? "nil")" })") }
        check(ok, "r7_original_start_is_kept_and_sent_to_the_phone")
    } catch { check(false, "r7 original: \(error)") }

    do {
        let url = root.appendingPathComponent("v11-orig.sqlite")
        func cols(_ db: DB) throws -> [String] { try db.query("PRAGMA table_info(cal_events)") { DB.text($0, 1) } }
        var before: [String] = []
        do {
            let db = try DB(url: url)
            _ = try db.run("ALTER TABLE cal_events DROP COLUMN original_start")
            before = try cols(db)
        }
        let fresh = root.appendingPathComponent("v11-fresh.sqlite")
        _ = try DB(url: fresh)
        func sql(_ db: DB) throws -> [String] {
            try db.query("SELECT sql FROM sqlite_master WHERE name='cal_events'") { DB.text($0, 0).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression) }
        }
        let db = try DB(url: url)
        let same = try sql(db) == sql(DB(url: fresh))
        let after = try cols(db)
        let version = try db.query("PRAGMA user_version") { DB.int($0, 0) }.first
        check(!before.contains("original_start") && after.contains("original_start") && same && version == 11,
              "r7_existing_v11_board_gets_original_start_in_place")
    } catch { check(false, "r7 v11 amend: \(error)") }

    // When the column is added to an existing board, the next pass reads each calendar in full (the daily full read, which
    // first takes in what changed since the last pass, so nothing is hidden or taken as deleted): cached instances get their
    // original start at once. A board that already has the column keeps its schedule.
    do {
        let url = root.appendingPathComponent("v11-reread.sqlite")
        let recent = Date().addingTimeInterval(-600)
        let inst = #"{"id":"mv_1","status":"confirmed","summary":"Sync","recurringEventId":"mv","start":{"dateTime":"2026-11-21T09:00:00Z"},"end":{"dateTime":"2026-11-21T09:15:00Z"},"originalStartTime":{"dateTime":"2026-11-20T09:00:00Z"},"updated":"2026-11-16T10:00:00Z"}"#
        do {
            let store = Store(db: try DB(url: url))
            let cache = CalendarCache(store: store)
            cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cid, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
            cache.apply(account: acct, calendarID: cid, changes: [
                GoogleEventChange(eventID: "mv_1", cancelled: false, fields: CalEventFields(start: iso.date(from: "2026-11-21T09:00:00Z")!, end: iso.date(from: "2026-11-21T09:15:00Z")!,
                                                                                         title: "Sync", recurringID: "mv", googleUpdated: recent)),
                GoogleEventChange(eventID: "keep", cancelled: false, fields: CalEventFields(start: iso.date(from: "2026-11-19T12:00:00Z")!, end: iso.date(from: "2026-11-19T13:00:00Z")!,
                                                                                         title: "Lunch", googleUpdated: recent)),
            ], nextToken: "T", fullRead: true, now: recent)
            cache.saveSeries(account: acct, calendarID: cid, seriesID: "mv", rule: "RRULE:FREQ=WEEKLY", now: Date())
            _ = try store.db.run("ALTER TABLE cal_events DROP COLUMN original_start")
        }
        let store = Store(db: try DB(url: url))
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.url?.path.contains("/events/") == true { return (#"{"recurrence":["RRULE:FREQ=WEEKLY"]}"#, 200) }
            // The catch-up since the last pass reports nothing new; the full read lists only the moved instance (the other
            // event is simply not listed: it must stay, not be hidden or taken as deleted).
            if r.url?.query?.contains("syncToken") == true { return (#"{"items":[],"nextSyncToken":"T2"}"#, 200) }
            return (#"{"items":[\#(inst)],"nextSyncToken":"T3"}"#, 200)
        }
        await CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [acct] }).syncOnce()
        let cache = CalendarCache(store: store)
        let lists = fake.requests.filter { $0.url?.path.hasSuffix("/events") == true }
        let fullList = lists.contains { $0.url?.query?.contains("syncToken") != true }
        let moved = cache.event(account: acct, calendarID: cid, eventID: "mv_1")
        let kept = cache.event(account: acct, calendarID: cid, eventID: "keep")
        let ok = fullList && moved?.originalStart == iso.date(from: "2026-11-20T09:00:00Z") && kept?.gone == false && kept?.cancelled == false
        if !ok { print("  r7 reread: full \(fullList), moved \(String(describing: moved?.originalStart)), kept gone \(String(describing: kept?.gone))") }
        check(ok, "r7_adding_original_start_rereads_calendars_without_hiding_events")

        // Opening again (the column is there now) does not ask for another full read.
        let before = cache.calendars().first?.fullReadAt
        _ = try DB(url: url)
        let reopened = Store(db: try DB(url: url))
        check(before != nil && CalendarCache(store: reopened).calendars().first?.fullReadAt == before,
              "r7_board_with_original_start_keeps_its_read_schedule")
    } catch { check(false, "r7 reread: \(error)") }
}
