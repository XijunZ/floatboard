import Foundation

/// Google calendars and events kept on the board, so the calendar shows instantly and works offline.
/// Everything here is local: no networking. Another part fetches from Google and hands the changes to `apply`.
/// A failed write or read goes to the Activity log (and `apply` and friends report failure), never swallowed.
@MainActor
public final class CalendarCache {
    private let db: DB
    private let store: Store?

    /// `store` is where failures are logged (Activity). Without one they go to stderr, the last resort.
    public init(db: DB, store: Store? = nil) { self.db = db; self.store = store }
    public convenience init(store: Store) { self.init(db: store.db, store: store) }

    // MARK: Calendars

    /// Adds new calendars and refreshes name, colour and ownership of known ones. What the user chose (shown),
    /// the sync token and reconnect state of a known calendar are kept.
    @discardableResult
    public func upsertCalendars(account: String, _ calendars: [CalCalendar]) -> Bool {
        write("Could not save the calendar list") {
            for c in calendars {
                try db.run("""
                    INSERT INTO cal_calendars(account, calendar_id, name, color, owned, shown) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(account, calendar_id) DO UPDATE SET name=excluded.name, color=excluded.color, owned=excluded.owned
                    """, [account, c.calendarID, c.name, c.color, c.owned ? 1 : 0, c.shown ? 1 : 0])
            }
        }
    }

    public func calendars() -> [CalCalendar] {
        read("Could not read calendars") {
            try db.query("""
                SELECT account, calendar_id, name, color, owned, shown, needs_reconnect, sync_token, synced_at
                FROM cal_calendars ORDER BY account, name, calendar_id
                """) { s in
                CalCalendar(account: DB.text(s, 0), calendarID: DB.text(s, 1), name: DB.text(s, 2), color: DB.text(s, 3),
                            owned: DB.int(s, 4) != 0, shown: DB.int(s, 5) != 0, needsReconnect: DB.int(s, 6) != 0,
                            syncToken: DB.isNull(s, 7) ? nil : DB.text(s, 7), syncedAt: DB.date(s, 8))
            }
        } ?? []
    }

    @discardableResult
    public func setShown(account: String, calendarID: String, _ shown: Bool) -> Bool {
        write("Could not change whether a calendar is shown") {
            try db.run("UPDATE cal_calendars SET shown=? WHERE account=? AND calendar_id=?", [shown ? 1 : 0, account, calendarID])
        }
    }

    @discardableResult
    public func setNeedsReconnect(account: String, calendarID: String, _ needs: Bool) -> Bool {
        write("Could not save the calendar's sign-in state") {
            try db.run("UPDATE cal_calendars SET needs_reconnect=? WHERE account=? AND calendar_id=?", [needs ? 1 : 0, account, calendarID])
        }
    }

    // MARK: Events

    /// Applies what Google reported: new and changed events are stored (a cancelled event that comes back is revived with
    /// the same E-n), cancelled ones are marked gone and kept so links to them still resolve. `nextToken`, when given,
    /// becomes the calendar's sync token and the sync time is stamped; it all happens in one step or not at all.
    @discardableResult
    public func apply(account: String, calendarID: String, changes: [GoogleEventChange], nextToken: String?, now: Date = Date()) -> Bool {
        write("Could not save calendar changes") {
            for change in changes {
                if change.cancelled || change.fields == nil {
                    try db.run("UPDATE cal_events SET gone=1 WHERE account=? AND calendar_id=? AND event_id=?",
                               [account, calendarID, change.eventID])
                } else if let f = change.fields {
                    let (start, end) = Self.span(f)
                    try db.run("""
                        INSERT INTO cal_events(account, calendar_id, event_id, start, end, all_day, start_day, end_day, title, location,
                                               video_link, description, html_link, recurring_id, google_updated, fb_card, gone)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
                        ON CONFLICT(account, calendar_id, event_id) DO UPDATE SET
                            start=excluded.start, end=excluded.end, all_day=excluded.all_day, start_day=excluded.start_day,
                            end_day=excluded.end_day, title=excluded.title, location=excluded.location,
                            video_link=excluded.video_link, description=excluded.description, html_link=excluded.html_link,
                            recurring_id=excluded.recurring_id, google_updated=excluded.google_updated,
                            fb_card=excluded.fb_card, gone=0
                        """, [account, calendarID, change.eventID, start, end, f.allDay ? 1 : 0, f.startDay, f.endDay, f.title,
                              f.location, f.videoLink, f.description, f.htmlLink, f.recurringID, f.googleUpdated, f.fbCard])
                }
            }
            if let nextToken {
                try db.run("UPDATE cal_calendars SET sync_token=?, synced_at=? WHERE account=? AND calendar_id=?",
                           [nextToken, now, account, calendarID])
            }
        }
    }

    /// Forgets the calendar's sync token and hides all its events until the next full read brings them back
    /// (each comes back with the same E-n).
    @discardableResult
    public func resetSync(account: String, calendarID: String) -> Bool {
        write("Could not reset a calendar's sync") {
            try db.run("UPDATE cal_calendars SET sync_token=NULL WHERE account=? AND calendar_id=?", [account, calendarID])
            try db.run("UPDATE cal_events SET gone=1 WHERE account=? AND calendar_id=?", [account, calendarID])
        }
    }

    /// Events that overlap [from, to): they start before `to` and end after `from`. Shown calendars only, not gone, by start.
    public func events(from: Date, to: Date) -> [CalEvent] {
        events("WHERE e.gone=0 AND c.shown=1 AND e.start<? AND e.end>? ORDER BY e.start, e.short_id", [to, from])
    }

    /// Any event by its E-n, even a cancelled one (so a link to it still resolves); nil if there is none.
    public func event(shortID: Int64) -> CalEvent? {
        events("WHERE e.short_id=?", [shortID]).first
    }

    public func event(account: String, calendarID: String, eventID: String) -> CalEvent? {
        events("WHERE e.account=? AND e.calendar_id=? AND e.event_id=?", [account, calendarID, eventID]).first
    }

    /// The earliest-starting timed event that has not ended by `date` (one in progress counts) and is not an all-day event or one made from a task (C6).
    public func nextMeeting(after date: Date) -> CalEvent? {
        events("WHERE e.gone=0 AND c.shown=1 AND e.all_day=0 AND e.fb_card IS NULL AND e.end>? ORDER BY e.start, e.short_id LIMIT 1",
               [date]).first
    }

    // MARK: Internals

    private static let columns = """
        e.short_id, e.account, e.calendar_id, e.event_id, e.start, e.end, e.all_day, e.start_day, e.end_day, e.title, e.location,
        e.video_link, e.description, e.html_link, e.recurring_id, e.google_updated, e.fb_card, e.gone
        """

    private func events(_ tail: String, _ args: [Any?]) -> [CalEvent] {
        read("Could not read calendar events") {
            try db.query("""
                SELECT \(Self.columns) FROM cal_events e
                LEFT JOIN cal_calendars c ON c.account=e.account AND c.calendar_id=e.calendar_id \(tail)
                """, args) { s in
                let allDay = DB.int(s, 6) != 0
                var start = DB.date(s, 4) ?? Date(), end = DB.date(s, 5) ?? Date()
                if allDay, let range = Self.dayRange(DB.isNull(s, 7) ? nil : DB.text(s, 7), DB.isNull(s, 8) ? nil : DB.text(s, 8)) {
                    (start, end) = range // the days are the truth; the dates follow the time zone in use now
                }
                return CalEvent(shortID: DB.int(s, 0), account: DB.text(s, 1), calendarID: DB.text(s, 2), eventID: DB.text(s, 3),
                                start: start, end: end, allDay: allDay, title: DB.text(s, 9), location: DB.text(s, 10),
                                videoLink: DB.text(s, 11), description: DB.text(s, 12), htmlLink: DB.text(s, 13),
                                recurringID: DB.isNull(s, 14) ? nil : DB.text(s, 14), googleUpdated: DB.date(s, 15) ?? Date(),
                                fbCard: DB.isNull(s, 16) ? nil : DB.int(s, 16), gone: DB.int(s, 17) != 0)
            }
        } ?? []
    }

    /// Start and end to store: for an all-day event, midnight of its first day and of its (exclusive) end day in the app's zone.
    private static func span(_ f: CalEventFields) -> (Date, Date) {
        if f.allDay, let r = dayRange(f.startDay, f.endDay) { return r }
        return (f.start, f.end)
    }

    private static func dayRange(_ startDay: String?, _ endDay: String?) -> (Date, Date)? {
        guard let startDay, let s = day(startDay) else { return nil }
        let e = endDay.flatMap(day) ?? AppTime.calendar.date(byAdding: .day, value: 1, to: s) ?? s
        return (s, e)
    }

    private static func day(_ text: String) -> Date? {
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return AppTime.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    private func write(_ what: String, _ work: () throws -> Void) -> Bool {
        do { try db.transaction(work); return true } catch { fail(what, error); return false }
    }

    private func read<T>(_ what: String, _ work: () throws -> T) -> T? {
        do { return try work() } catch { fail(what, error); return nil }
    }

    private func fail(_ what: String, _ error: Error) {
        if let store { store.activity("calendar", .error, what, detail: "\(error)") }
        else { FileHandle.standardError.write(Data("FloatBoard: \(what): \(error)\n".utf8)) }
    }
}
