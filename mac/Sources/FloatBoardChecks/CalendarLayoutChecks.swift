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
    check(keep.map(\.id) == ["E-5"] || keep.isEmpty, "layout_linked_event_without_task_due")

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
}
