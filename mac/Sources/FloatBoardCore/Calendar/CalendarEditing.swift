import Foundation

extension Store {
    /// The task an event was made from or is linked to, if any.
    public func linkedTask(of e: CalEvent) -> Card? {
        cards.first { $0.id == e.fbCard || (!$0.gcalEvent.isEmpty && $0.gcalEvent == e.eventID && $0.gcalAccount == e.account) }
    }

    /// The calendar screen moved or resized `e`. A new start on an event made from a task goes through the task (its due moves
    /// and the event follows, the same path as a drag); a new end alone only patches the event's end, because an event's length
    /// lives in Google, not on the task (D10). Anything else is a plain patch. Returns true when a change was queued.
    @discardableResult
    public func moveCalendarEvent(_ e: CalEvent, start: Date, end: Date, now: Date = Date()) -> Bool {
        let outbox = CalendarOutbox(store: self)
        func patchEnd() -> Bool {
            !outbox.enqueue(.patch(eventID: e.eventID, title: nil, start: nil, end: end, allDayStart: nil),
                            account: e.account, calendarID: e.calendarID, now: now).isEmpty
        }
        if let t = linkedTask(of: e), !e.allDay {
            var queued = false
            if start != e.start { queued = placeOnCalendar(cardID: t.id, start: start, account: nil, now: now) }
            // The task path keeps the old length; a different length is patched on top.
            if end.timeIntervalSince(start) != e.end.timeIntervalSince(e.start) {
                if start == e.start { return patchEnd() }
                queued = patchEnd() || queued
            }
            return queued
        }
        return !outbox.enqueue(.patch(eventID: e.eventID, title: nil, start: start, end: end, allDayStart: nil),
                               account: e.account, calendarID: e.calendarID, now: now).isEmpty
    }
}
