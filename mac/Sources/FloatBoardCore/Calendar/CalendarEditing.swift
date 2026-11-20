import Foundation

/// What the event panel's and the New event sheet's title and time fields mean, decided apart from the screen so it can be
/// checked. Only what the user changed since the panel opened is sent to Google: opening and closing a panel changes nothing.
public enum EventPanelEdit {
    /// The fields as the panel holds them: a title, a day, and two times of day (only their hour and minute count).
    public struct Fields: Equatable {
        public var title: String
        public var day: Date
        public var start: Date
        public var end: Date
        public init(title: String, day: Date, start: Date, end: Date) { self.title = title; self.day = day; self.start = start; self.end = end }
        /// What the panel shows for `e` when it opens.
        public init(_ e: CalEvent) { self.init(title: e.title, day: e.start, start: e.start, end: e.end) }
    }

    /// `time`'s hour and minute on `day`, in the app's time zone.
    static func on(_ day: Date, _ time: Date) -> Date {
        let c = AppTime.calendar
        let t = c.dateComponents([.hour, .minute], from: time)
        return c.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? time
    }

    private static func sameClock(_ a: Date, _ b: Date) -> Bool {
        let c = AppTime.calendar
        return c.dateComponents([.hour, .minute], from: a) == c.dateComponents([.hour, .minute], from: b)
    }

    /// The end after the start moves: it moves by the same amount, so the event keeps its length (10:00–11:00 with the
    /// start moved to 14:00 becomes 14:00–15:00; moved back to 9:30, 9:30–10:30).
    public static func endAfterMovingStart(from old: Date, to new: Date, end: Date) -> Date {
        end.addingTimeInterval(new.timeIntervalSince(old))
    }

    /// A start and end from a day and two times of day. The end lands `endDayOffset` days after the start's day; an end that
    /// would not be after the start rolls on to the next day (23:00 to 01:00 ends the next morning, never 15 minutes later).
    public static func span(day: Date, start: Date, end: Date, endDayOffset: Int = 0) -> (start: Date, end: Date) {
        let c = AppTime.calendar
        let s = on(day, start)
        let endDay = c.date(byAdding: .day, value: endDayOffset, to: day) ?? day
        var e = on(endDay, end)
        if e <= s { e = c.date(byAdding: .day, value: 1, to: on(day, end)) ?? e }
        if e <= s { e = s.addingTimeInterval(Double(CalendarLayout.stepMinutes * 60)) }
        return (s, e)
    }

    /// What to send when the panel closes. `title` is set only when the user changed the title field; `move` only when they
    /// changed the day or a time and the result differs from the event. `event` is the event as it is now (Google may have
    /// changed it while the panel was open): the day, the start time and the end time each come from the panel only when the
    /// user changed that field, else from `event`. A new start alone keeps the event's length (like a drag); a new end keeps
    /// the day the end was on relative to the start (an overnight event still ends the next day). Only the end changed: the
    /// start stays exactly the event's, so the move is an end-only change.
    public static func changes(event: CalEvent, opened: Fields, now: Fields) -> (title: String?, move: (start: Date, end: Date)?) {
        var title: String?
        let t = now.title.trimmingCharacters(in: .whitespaces)
        if now.title != opened.title, !t.isEmpty, t != event.title { title = t }
        guard !event.allDay else { return (title, nil) }
        let dayChanged = Due.dayString(now.day) != Due.dayString(opened.day)
        let startChanged = !sameClock(now.start, opened.start), endChanged = !sameClock(now.end, opened.end)
        guard dayChanged || startChanged || endChanged else { return (title, nil) }
        let c = AppTime.calendar
        let day = dayChanged ? now.day : event.start
        let startClock = startChanged ? now.start : event.start
        let s = dayChanged || startChanged ? on(day, startClock) : event.start
        let e: Date
        if endChanged {
            let offset = c.dateComponents([.day], from: c.startOfDay(for: event.start), to: c.startOfDay(for: event.end)).day ?? 0
            e = span(day: day, start: s, end: now.end, endDayOffset: offset).end
        } else {
            e = s.addingTimeInterval(event.end.timeIntervalSince(event.start))
        }
        guard s != event.start || e != event.end else { return (title, nil) }
        return (title, (s, e))
    }
}

extension Store {
    /// The task an event was made from or is linked to, if any.
    public func linkedTask(of e: CalEvent) -> Card? {
        cards.first { $0.id == e.fbCard || (!$0.gcalEvent.isEmpty && $0.gcalEvent == e.eventID && $0.gcalAccount == e.account) }
    }

    /// The calendar screen moved or resized `e`. A new start on an event made from a task goes through the task (its due moves
    /// and the event follows, the same path as a drag); a new end alone only patches the event's end, because an event's length
    /// lives in Google, not on the task (D10). Anything else is a plain patch, with only the end when the start is unchanged.
    /// Returns true when a change was queued.
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
        if start == e.start { return patchEnd() }
        return !outbox.enqueue(.patch(eventID: e.eventID, title: nil, start: start, end: end, allDayStart: nil),
                               account: e.account, calendarID: e.calendarID, now: now).isEmpty
    }
}
