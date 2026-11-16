import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Fixes from the final whole-branch review of the calendar feature: each section names the finding it covers.
@MainActor func finalFixChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-finalfix-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let acct = "me@example.com"
    func setup(_ name: String) throws -> (Store, CalendarCache, CalendarOutbox) {
        let store = Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true)])
        return (store, cache, CalendarOutbox(store: store))
    }
    let cal = AppTime.calendar
    let day = cal.date(byAdding: .day, value: 4, to: cal.startOfDay(for: Date()))!
    func at(_ h: Int, _ m: Int = 0, plusDays: Int = 0) -> Date {
        cal.date(byAdding: .day, value: plusDays, to: cal.date(bySettingHour: h, minute: m, second: 0, of: day)!)!
    }

    // 1. The event panel: opening and closing it changes nothing; an overnight event keeps its next-day end.
    do {
        let (store, cache, outbox) = try setup("panel")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "night", cancelled: false,
            fields: CalEventFields(start: at(23), end: at(1, plusDays: 1), title: "Night shift ", googleUpdated: Date()))], nextToken: nil)
        guard let ev = cache.event(account: acct, calendarID: acct, eventID: "night") else { check(false, "panel setup: no event"); return }
        let opened = EventPanelEdit.Fields(ev)
        // The time fields as a time input leaves them: same hour and minute, another date underneath.
        var same = opened
        same.start = cal.date(byAdding: .day, value: -3, to: opened.start)!; same.end = cal.date(byAdding: .day, value: 2, to: opened.end)!
        let none = EventPanelEdit.changes(event: ev, opened: opened, now: same)
        if let m = none.move { store.moveCalendarEvent(ev, start: m.start, end: m.end) }
        check(none.title == nil && none.move == nil && outbox.rows(unsent: true).isEmpty, "panel_unchanged_overnight_event_queues_nothing")

        var later = opened; later.end = at(2)  // the end time typed as 02:00
        let c2 = EventPanelEdit.changes(event: ev, opened: opened, now: later)
        check(c2.move?.start == at(23) && c2.move?.end == at(2, plusDays: 1) && c2.title == nil, "panel_overnight_end_edit_stays_next_day")

        var earlier = opened; earlier.start = at(22)  // only the start: the length is kept, like a drag
        let c3 = EventPanelEdit.changes(event: ev, opened: opened, now: earlier)
        check(c3.move?.start == at(22) && c3.move?.end == at(0, plusDays: 1), "panel_start_edit_keeps_length")

        var renamed = opened; renamed.title = "Night shift (swap)"
        let c4 = EventPanelEdit.changes(event: ev, opened: opened, now: renamed)
        check(c4.title == "Night shift (swap)" && c4.move == nil, "panel_title_edit_only_renames")

        let sheet = EventPanelEdit.span(day: day, start: at(23), end: at(23).addingTimeInterval(3600))
        let sheet2 = EventPanelEdit.span(day: day, start: at(23), end: at(22))
        check(sheet.start == at(23) && sheet.end == at(0, plusDays: 1) && sheet2.end == at(22, plusDays: 1), "new_event_end_rolls_to_next_day")
    } catch { check(false, "panel checks: \(error)") }

    // 2. The calendar list is read again at the next pass after a failed read or a reconnect, not 6 hours later;
    //    calendars of a removed account are not read.
    do {
        let (store, cache, _) = try setup("relist")
        let who = "relist@example.com", removed = "removed@example.com"
        cache.upsertCalendars(account: removed, [CalCalendar(account: removed, calendarID: removed, name: "Old", color: "#000000", owned: true, shown: true)])
        let fake = FakeGoogle()
        var listOK = false
        fake.handler = { r in
            if r.url?.path.hasSuffix("/users/me/calendarList") == true {
                return listOK ? (##"{"items":[{"id":"relist@example.com","summary":"R","accessRole":"owner","primary":true,"backgroundColor":"#111111"}]}"##, 200)
                              : (#"{"error":"backendError"}"#, 500)
            }
            return (#"{"items":[],"nextSyncToken":"T"}"#, 200)
        }
        let sync = CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [who] })
        func lists() -> Int { fake.requests.filter { $0.url?.path.hasSuffix("/users/me/calendarList") == true }.count }
        await sync.tick()
        let afterFail = lists()
        listOK = true
        await sync.tick()   // the failed read is tried again at once
        check(afterFail == 1 && lists() == 2 && CalendarListAttempts.outcome(who) == .listed
              && cache.calendars().contains { $0.account == who }, "calendar_list_retried_next_pass_after_failure")
        await sync.tick()
        let steady = lists()
        CalendarListAttempts.forget(who)   // what a fresh sign-in (Reconnect) does
        await sync.tick()
        check(steady == 2 && lists() == 3, "calendar_list_read_next_pass_after_reconnect")
        check(!fake.requests.contains { $0.url?.path.contains(removed) == true }, "sync_skips_calendars_of_removed_accounts")
    } catch { check(false, "relist checks: \(error)") }
}

/// A fake Google for the checks: records requests and answers with `handler` (body, status).
final class FakeGoogle: @unchecked Sendable {
    var requests: [URLRequest] = []
    var handler: (URLRequest) -> (String, Int) = { _ in ("{}", 200) }
    func api() -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { [self] req in
            requests.append(req)
            let (body, status) = handler(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}
