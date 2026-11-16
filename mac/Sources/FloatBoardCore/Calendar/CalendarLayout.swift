import Foundation

/// One thing drawn on a day of the calendar: an event or a task, with where it sits.
public struct PlacedItem: Identifiable, Equatable {
    public enum Content: Equatable { case event(CalEvent), task(Card) }
    public var content: Content
    /// The part of the item on this day (clipped at midnight). A task is as long as a default event.
    public var start: Date
    public var end: Date
    /// Side-by-side position among overlapping items: `column` of `columns`. Always 0 of 1 in the strip.
    public var column: Int
    public var columns: Int
    /// True for the strip above the hours: all-day events and tasks with a date but no time.
    public var inStrip: Bool

    /// "E-37" or "T-142".
    public var id: String {
        switch content {
        case .event(let e): e.id.text
        case .task(let t): ShortID(kind: .task, number: t.id).text
        }
    }
}

/// The maths of the Calendar tab, apart from any drawing.
@MainActor
public enum CalendarLayout {
    /// The grid moves and resizes in steps of this many minutes.
    public static let stepMinutes = 15

    /// What shows on `day`: events from the calendar and tasks with a due on that day. A task with an event shows once, as
    /// the task (C6): its event is left out, when the task is among `tasks` and has its due on this day.
    public static func columns(for events: [CalEvent], tasks: [Card], day: Date) -> [PlacedItem] {
        let cal = AppTime.calendar
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let minLength = TimeInterval(stepMinutes * 60)

        // Tasks on this day, and which events they stand for.
        var shownTasks: [Card] = []
        for t in tasks {
            guard let due = t.due, due >= dayStart, due < dayEnd else { continue }
            shownTasks.append(t)
        }
        let taskIDs = Set(shownTasks.map(\.id))
        func standsForTask(_ e: CalEvent) -> Bool {
            if let c = e.fbCard, taskIDs.contains(c) { return true }
            return shownTasks.contains { !$0.gcalEvent.isEmpty && $0.gcalEvent == e.eventID && $0.gcalAccount == e.account }
        }

        var strip: [PlacedItem] = []
        var timed: [PlacedItem] = []
        for e in events where !e.gone && e.start < dayEnd && e.end > dayStart && !standsForTask(e) {
            if e.allDay {
                strip.append(PlacedItem(content: .event(e), start: dayStart, end: dayEnd, column: 0, columns: 1, inStrip: true))
            } else {
                let s = max(e.start, dayStart)
                timed.append(PlacedItem(content: .event(e), start: s, end: max(min(e.end, dayEnd), s), column: 0, columns: 1, inStrip: false))
            }
        }
        for t in shownTasks {
            guard let due = t.due else { continue }
            if t.dueHasTime {
                timed.append(PlacedItem(content: .task(t), start: due, end: min(due.addingTimeInterval(TaskEventRules.eventLength), dayEnd),
                                        column: 0, columns: 1, inStrip: false))
            } else {
                strip.append(PlacedItem(content: .task(t), start: dayStart, end: dayEnd, column: 0, columns: 1, inStrip: true))
            }
        }

        // Overlapping timed items sit side by side: each takes the first free column; a run of items that touch
        // each other shares the run's widest column count.
        timed.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        var placed: [PlacedItem] = []
        var group: [PlacedItem] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast
        func closeGroup() {
            for var g in group { g.columns = max(columnEnds.count, 1); placed.append(g) }
            group = []; columnEnds = []
        }
        for var item in timed {
            if !group.isEmpty && item.start >= groupEnd { closeGroup() }
            // A short or empty item still takes up one step of room.
            let shownEnd = max(item.end, item.start.addingTimeInterval(minLength))
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                item.column = free; columnEnds[free] = shownEnd
            } else {
                item.column = columnEnds.count; columnEnds.append(shownEnd)
            }
            groupEnd = group.isEmpty ? shownEnd : max(groupEnd, shownEnd)
            group.append(item)
        }
        closeGroup()
        strip.sort { ($0.id) < ($1.id) }
        return strip + placed
    }

    /// The Monday that starts the week with `date`, at midnight, in the app's calendar.
    public static func weekStart(containing date: Date) -> Date {
        var cal = AppTime.calendar
        cal.firstWeekday = 2
        let day = cal.startOfDay(for: date)
        let back = (cal.component(.weekday, from: day) + 5) % 7 // Monday = 0 ... Sunday = 6
        return cal.date(byAdding: .day, value: -back, to: day) ?? day
    }

    /// The seven days of the week with `date`, Monday first.
    public static func days(ofWeekContaining date: Date) -> [Date] {
        let cal = AppTime.calendar
        let monday = weekStart(containing: date)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    /// `date` moved back to the step before it (where a click lands).
    public static func snapDown(_ date: Date) -> Date {
        let step = TimeInterval(stepMinutes * 60)
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
    }

    /// `date` moved to the nearest step (15 minutes).
    public static func snap(_ date: Date) -> Date {
        let step = TimeInterval(stepMinutes * 60)
        return Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / step).rounded() * step)
    }
}
