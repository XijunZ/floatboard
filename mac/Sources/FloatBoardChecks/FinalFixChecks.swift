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
}
