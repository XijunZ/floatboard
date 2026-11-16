import Foundation
import FloatBoardCore

/// Where events and tasks go on a day of the calendar: side by side when they overlap, the top strip for all-day items.
@MainActor func calendarLayoutChecks() {
    let cal = AppTime.calendar
    let day = cal.date(from: DateComponents(timeZone: AppTime.zone, year: 2026, month: 11, day: 18))! // a Wednesday
    func at(_ h: Int, _ m: Int = 0, dayOffset: Int = 0) -> Date {
        cal.date(byAdding: .day, value: dayOffset, to: cal.date(bySettingHour: h, minute: m, second: 0, of: day)!)!
    }
    func event(_ n: Int64, _ title: String, _ s: Date, _ e: Date, allDay: Bool = false, eventID: String? = nil, fbCard: Int64? = nil) -> CalEvent {
        CalEvent(shortID: n, account: "me@example.com", calendarID: "primary", eventID: eventID ?? "ev\(n)", start: s, end: e,
                 allDay: allDay, title: title, location: "", videoLink: "", description: "", htmlLink: "",
                 recurringID: nil, googleUpdated: day, fbCard: fbCard)
    }
    func task(_ id: Int64, _ title: String, due: Date?, hasTime: Bool, gcalEvent: String = "") -> Card {
        Card(id: id, title: title, notes: "", area: "Personal", importance: .medium, due: due, status: .todo,
             created: day, started: nil, done: nil, gcalAccount: gcalEvent.isEmpty ? "" : "me@example.com",
             dueHasTime: hasTime, gcalCalendar: gcalEvent.isEmpty ? "" : "primary", gcalEvent: gcalEvent)
    }

    // Overlapping items share the width; separate ones keep it all.
    let a = event(1, "Standup", at(9), at(10)), b = event(2, "Review", at(9, 30), at(10, 30)), c = event(3, "Lunch", at(12), at(13))
    let placed = CalendarLayout.columns(for: [a, b, c], tasks: [], day: day)
    func item(_ id: String) -> PlacedItem? { placed.first { $0.id == id } }
    check(item("E-1")?.columns == 2 && item("E-2")?.columns == 2 && item("E-1")?.column != item("E-2")?.column
          && item("E-3")?.columns == 1 && item("E-3")?.column == 0, "layout_overlaps_side_by_side")

    // All-day events and date-only tasks go to the top strip; timed items do not.
    let holiday = event(4, "Bank holiday", at(0), at(0, dayOffset: 1), allDay: true)
    let passport = task(7, "Renew passport", due: at(0), hasTime: false)
    let sendDeck = task(8, "Send the deck", due: at(15), hasTime: true)
    let strip = CalendarLayout.columns(for: [holiday, a], tasks: [passport, sendDeck], day: day)
    check(Set(strip.filter(\.inStrip).map(\.id)) == ["E-4", "T-7"] && Set(strip.filter { !$0.inStrip }.map(\.id)) == ["E-1", "T-8"]
          && strip.first { $0.id == "T-8" }?.end == at(15, 30), "layout_all_day_and_date_only_in_strip")

    // A task with an event shows once, as the task (C6), whether linked by the task's fields or by the event's.
    let linkedA = event(5, "Send the deck", at(15), at(15, 30), eventID: "g1")
    let linkedB = event(6, "Pay the bill", at(16), at(16, 30), eventID: "g2", fbCard: 9)
    let deck = task(8, "Send the deck", due: at(15), hasTime: true, gcalEvent: "g1")
    let bill = task(9, "Pay the bill", due: at(16), hasTime: true)
    let once = CalendarLayout.columns(for: [linkedA, linkedB], tasks: [deck, bill], day: day)
    check(once.map(\.id).sorted() == ["T-8", "T-9"], "layout_linked_task_shown_once")
    // If the task is not shown (no due on this day), its event stays so the time is not lost.
    let keep = CalendarLayout.columns(for: [linkedA], tasks: [task(8, "Send the deck", due: nil, hasTime: false, gcalEvent: "g1")], day: day)
    check(keep.map(\.id) == ["E-5"], "layout_linked_event_without_task_due")

    // Weeks start on Monday, in the app's calendar.
    let monday = CalendarLayout.weekStart(containing: day)
    check(cal.component(.weekday, from: monday) == 2 && cal.component(.day, from: monday) == 16
          && CalendarLayout.days(ofWeekContaining: day).count == 7
          && cal.component(.weekday, from: CalendarLayout.days(ofWeekContaining: day)[6]) == 1, "layout_week_starts_monday")

    // Multi-day events are clipped to the day; 15-minute snapping.
    let long = event(10, "Offsite", at(20, dayOffset: -1), at(10), eventID: "x")
    let clipped = CalendarLayout.columns(for: [long], tasks: [], day: day).first
    check(clipped?.start == at(0) && clipped?.end == at(10), "layout_clips_to_day")
    check(CalendarLayout.snap(at(9, 7)) == at(9) && CalendarLayout.snap(at(9, 9)) == at(9, 15)
          && CalendarLayout.snap(at(9, 53)) == at(10), "layout_snaps_to_15_minutes")

    // An event with no length at midnight still shows on that day.
    let zero = event(11, "Midnight ping", at(0), at(0))
    check(CalendarLayout.columns(for: [zero], tasks: [], day: day).map(\.id) == ["E-11"], "layout_zero_length_event_at_midnight")
}

/// Calendar edits: resizing an event made from a task, and new events that wait to be sent.
@MainActor func calendarEditChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-caledit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "calendar edit setup: \(error)"); return }
    let cache = CalendarCache(store: store), outbox = CalendarOutbox(store: store)
    let acct = "me@example.com"
    cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true)])
    let start = AppTime.calendar.date(byAdding: .day, value: 3, to: AppTime.calendar.startOfDay(for: Date()))!.addingTimeInterval(10 * 3600)

    store.add(title: "Call the bank", area: store.areas.first?.name ?? "Work", importance: .medium, due: start, dueHasTime: true)
    guard let id = store.cards.last?.id else { check(false, "calendar edit setup: no card"); return }
    store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(acct)', gcal_event='g1' WHERE id=\(id)")
    cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "g1", cancelled: false,
        fields: CalEventFields(start: start, end: start.addingTimeInterval(1800), title: "Call the bank", googleUpdated: Date(), fbCard: id))], nextToken: nil)
    guard let ev = cache.event(account: acct, calendarID: acct, eventID: "g1") else { check(false, "calendar edit setup: no event"); return }

    // Resize: only the event's end is patched; the task's due stays.
    let before = store.card(id)?.due
    store.moveCalendarEvent(ev, start: ev.start, end: ev.end.addingTimeInterval(1800))
    let rows = outbox.rows(unsent: true)
    var endOnly = false
    if rows.count == 1, case .patch(let eid, nil, nil, let e?, nil)? = rows[0].write { endOnly = eid == "g1" && e == ev.end.addingTimeInterval(1800) }
    check(endOnly && store.card(id)?.due == before, "linked_event_resize_patches_end_only")

    // Move: through the task (its due follows, the patch carries the new start).
    store.moveCalendarEvent(ev, start: ev.start.addingTimeInterval(3600), end: ev.end.addingTimeInterval(3600))
    check(store.card(id)?.due == start.addingTimeInterval(3600), "linked_event_move_goes_through_the_task")

    // A new event waits as a placeholder until the cache has it.
    let f = CalEventFields(start: start, end: start.addingTimeInterval(3600), title: "Dinner", googleUpdated: Date())
    let uuid = outbox.enqueue(.create(f, cardID: nil, addMeet: false), account: acct, calendarID: acct)
    let waiting = outbox.pendingNewEvents(from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200))
    check(waiting.count == 1 && waiting[0].title == "Dinner" && waiting[0].shortID < 0
          && outbox.pendingNewEvents(from: start.addingTimeInterval(86400), to: start.addingTimeInterval(90000)).isEmpty,
          "new_event_shows_while_waiting")
    outbox.markSent(uuid: uuid, result: (CalendarOutbox.googleEventID(forUUID: uuid), f))
    check(outbox.pendingNewEvents(from: start.addingTimeInterval(-3600), to: start.addingTimeInterval(7200)).isEmpty, "new_event_placeholder_goes_when_sent")
}
