import Foundation

/// Google calendars and events kept on the board, so the calendar shows instantly and works offline.
/// Everything here is local: no networking. Another part fetches from Google and hands the changes to `apply`.
/// A failed write or read goes to the Activity log (and `apply` and friends report failure), never swallowed.
@MainActor
public final class CalendarCache {
    let db: DB
    let store: Store?

    /// `store` is where failures are logged (Activity). Without one they go to stderr, the last resort.
    public init(db: DB, store: Store? = nil) { self.db = db; self.store = store }
    public convenience init(store: Store) { self.init(db: store.db, store: store) }

    /// The accounts that are connected right now, in the app's order (as Settings lists them; "the first connected" is the
    /// first here). What the calendar and the bar show leaves out the others (a removed account's events stay saved, with each
    /// calendar's shown choice, and come back when the account is added again). Nil: no filtering (the sync and the checks).
    /// The app sets it from its list of Google accounts.
    public static var connectedAccounts: (() -> [String])?

    /// SQL for "only connected accounts" on the event table `e`, with its arguments.
    private static func connectedClause() -> (String, [Any?]) {
        guard let connected = connectedAccounts?() else { return ("", []) }
        if connected.isEmpty { return (" AND 0", []) }
        let list = Set(connected).sorted()
        return (" AND e.account IN (" + list.map { _ in "?" }.joined(separator: ",") + ")", list)
    }

    // MARK: Calendars

    /// The id Google accepts for "the account's main calendar" in place of its real id. Used (and cached under) until the
    /// calendar list, which gives the real id, can be read.
    public static let primaryAlias = "primary"

    /// Adds new calendars and refreshes name, colour, ownership and the main-calendar flag of known ones. What the user chose
    /// (shown), the sync token and reconnect state of a known calendar are kept. When the list names the account's main
    /// calendar, whatever was kept under the "primary" stand-in moves to its real id, in the same step: the calendar row (with
    /// its choice and sync token), its events (same E-n), tasks linked to them and changes waiting to be sent.
    @discardableResult
    public func upsertCalendars(account: String, _ calendars: [CalCalendar]) -> Bool {
        write("Could not save the calendar list") {
            if let main = calendars.first(where: { $0.primary && $0.calendarID != Self.primaryAlias }) {
                try rekeyPrimary(account: account, to: main.calendarID)
            }
            for c in calendars {
                try db.run("""
                    INSERT INTO cal_calendars(account, calendar_id, name, color, owned, shown, is_primary) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(account, calendar_id) DO UPDATE SET name=excluded.name, color=excluded.color, owned=excluded.owned,
                        is_primary=excluded.is_primary
                    """, [account, c.calendarID, c.name, c.color, c.owned ? 1 : 0, c.shown ? 1 : 0, c.primary ? 1 : 0])
            }
        }
    }

    /// Moves everything kept under the "primary" stand-in for `account` to the main calendar's real id. An event already
    /// kept under the real id stays as it is and its stand-in copy goes, so nothing is there twice; links to the copy's E-n
    /// move to the one that stays first. Runs inside `write`.
    private func rekeyPrimary(account: String, to id: String) throws {
        let alias = Self.primaryAlias
        let pairs = try db.query("""
            SELECT a.short_id, r.short_id FROM cal_events a JOIN cal_events r ON r.account=a.account AND r.event_id=a.event_id
            WHERE a.account=? AND a.calendar_id=? AND r.calendar_id=?
            """, [account, alias, id]) { (DB.int($0, 0), DB.int($0, 1)) }
        for (gone, kept) in pairs { try moveLinks(from: gone, to: kept) }
        try db.run("""
            UPDATE cal_events SET calendar_id=? WHERE account=? AND calendar_id=?
            AND event_id NOT IN (SELECT event_id FROM cal_events WHERE account=? AND calendar_id=?)
            """, [id, account, alias, account, id])
        try db.run("DELETE FROM cal_events WHERE account=? AND calendar_id=?", [account, alias])
        try db.run("UPDATE cards SET gcal_calendar=? WHERE gcal_account=? AND gcal_calendar=?", [id, account, alias])
        try db.run("UPDATE cal_outbox SET calendar_id=? WHERE account=? AND calendar_id=?", [id, account, alias])
        try db.run("UPDATE OR IGNORE cal_series SET calendar_id=? WHERE account=? AND calendar_id=?", [id, account, alias])
        try db.run("DELETE FROM cal_series WHERE account=? AND calendar_id=?", [account, alias])
        try db.run("""
            UPDATE cal_calendars SET calendar_id=? WHERE account=? AND calendar_id=?
            AND NOT EXISTS (SELECT 1 FROM cal_calendars WHERE account=? AND calendar_id=?)
            """, [id, account, alias, account, id])
        try db.run("DELETE FROM cal_calendars WHERE account=? AND calendar_id=?", [account, alias])
    }

    /// Every link to event E-`gone` now points at E-`kept` (stored the way `Store.link` stores a pair: smaller text first). A link
    /// that would join the event to itself is dropped; one that already exists is not doubled.
    private func moveLinks(from gone: Int64, to kept: Int64) throws {
        let g = String(gone), event = ItemKind.event.rawValue
        let rows = try db.query("""
            SELECT from_type, from_id, to_type, to_id, created, actor FROM links WHERE (from_type=? AND from_id=?) OR (to_type=? AND to_id=?)
            """, [event, g, event, g]) { s in
            (DB.text(s, 0), DB.text(s, 1), DB.text(s, 2), DB.text(s, 3), DB.date(s, 4) ?? Date(), DB.text(s, 5))
        }
        try db.run("DELETE FROM links WHERE (from_type=? AND from_id=?) OR (to_type=? AND to_id=?)", [event, g, event, g])
        let keptID = ShortID(kind: .event, number: kept)
        for r in rows {
            let other = r.0 == event && r.1 == g ? (r.2, r.3) : (r.0, r.1)
            guard let kind = ItemKind(rawValue: other.0), let n = Int64(other.1) else { continue }
            let o = ShortID(kind: kind, number: n)
            guard o != keptID else { continue }
            let (a, b) = keptID.text <= o.text ? (keptID, o) : (o, keptID)
            try db.run("INSERT OR IGNORE INTO links(from_type, from_id, to_type, to_id, created, actor) VALUES(?,?,?,?,?,?)",
                       [a.kind.rawValue, String(a.number), b.kind.rawValue, String(b.number), r.4, r.5])
        }
    }

    public func calendars() -> [CalCalendar] {
        read("Could not read calendars") {
            try db.query("""
                SELECT account, calendar_id, name, color, owned, shown, needs_reconnect, sync_token, synced_at, full_read_at, is_primary
                FROM cal_calendars ORDER BY account, name, calendar_id
                """) { s in
                CalCalendar(account: DB.text(s, 0), calendarID: DB.text(s, 1), name: DB.text(s, 2), color: DB.text(s, 3),
                            owned: DB.int(s, 4) != 0, shown: DB.int(s, 5) != 0, needsReconnect: DB.int(s, 6) != 0,
                            syncToken: DB.isNull(s, 7) ? nil : DB.text(s, 7), syncedAt: DB.date(s, 8), fullReadAt: DB.date(s, 9),
                            primary: DB.int(s, 10) != 0)
            }
        } ?? []
    }

    /// The calendars of connected accounts only: what can be shown or chosen for a new event.
    public func connectedCalendars() -> [CalCalendar] {
        guard let connected = Self.connectedAccounts?() else { return calendars() }
        let set = Set(connected)
        return calendars().filter { set.contains($0.account) }
    }

    /// The connected accounts in order: the app's list, or (without one: the sync and the checks) every account with a saved calendar.
    public func connectedAccountList() -> [String] {
        Self.connectedAccounts?() ?? Array(Set(calendars().map(\.account))).sorted()
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
    public func apply(account: String, calendarID: String, changes: [GoogleEventChange], nextToken: String?, fullRead: Bool = false, now: Date = Date()) -> Bool {
        write("Could not save calendar changes") {
            for change in changes {
                if change.cancelled || change.fields == nil {
                    try db.run("UPDATE cal_events SET gone=1, cancelled=1 WHERE account=? AND calendar_id=? AND event_id=?",
                               [account, calendarID, change.eventID])
                } else if let f = change.fields {
                    let (start, end) = Self.span(f)
                    try db.run("""
                        INSERT INTO cal_events(account, calendar_id, event_id, start, end, all_day, start_day, end_day, title, location,
                                               video_link, description, html_link, recurring_id, google_updated, fb_card, original_start, gone)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
                        ON CONFLICT(account, calendar_id, event_id) DO UPDATE SET
                            start=excluded.start, end=excluded.end, all_day=excluded.all_day, start_day=excluded.start_day,
                            end_day=excluded.end_day, title=excluded.title, location=excluded.location,
                            video_link=excluded.video_link, description=excluded.description, html_link=excluded.html_link,
                            recurring_id=excluded.recurring_id, google_updated=excluded.google_updated,
                            fb_card=excluded.fb_card, original_start=excluded.original_start, gone=0, cancelled=0
                        """, [account, calendarID, change.eventID, start, end, f.allDay ? 1 : 0, f.startDay, f.endDay, f.title,
                              f.location, f.videoLink, f.description, f.htmlLink, f.recurringID, f.googleUpdated, f.fbCard, f.originalStart])
                    // An event FloatBoard has written or sent to: note what Google has now (a changed field with its stamp).
                    if let json = try db.query("SELECT own_write FROM cal_events WHERE account=? AND calendar_id=? AND event_id=? AND own_write IS NOT NULL",
                                               [account, calendarID, change.eventID], { DB.text($0, 0) }).first {
                        let prior = try? JSONDecoder().decode(CalOwnWrite.self, from: Data(json.utf8)) // try?-ok: an unreadable record is rebuilt from what Google has now
                        let seen = CalendarOutbox.observed(prior, base: nil, current: f)
                        if seen != prior {
                            try db.run("UPDATE cal_events SET own_write=? WHERE account=? AND calendar_id=? AND event_id=?",
                                       [String(decoding: try JSONEncoder().encode(seen), as: UTF8.self), account, calendarID, change.eventID])
                        }
                    }
                }
            }
            if let nextToken {
                try db.run("UPDATE cal_calendars SET sync_token=?, synced_at=?, full_read_at=CASE WHEN ? THEN ? ELSE full_read_at END WHERE account=? AND calendar_id=?",
                           [nextToken, now, fullRead ? 1 : 0, now, account, calendarID])
            }
        }
    }

    /// Forgets the calendar's sync token and hides all its events until the next full read brings them back
    /// (each comes back with the same E-n). Hidden is not cancelled: only Google's own cancellation marks an event deleted.
    @discardableResult
    public func resetSync(account: String, calendarID: String) -> Bool {
        write("Could not reset a calendar's sync") {
            try db.run("UPDATE cal_calendars SET sync_token=NULL WHERE account=? AND calendar_id=?", [account, calendarID])
            try db.run("UPDATE cal_events SET gone=1 WHERE account=? AND calendar_id=?", [account, calendarID])
        }
    }

    /// Events that overlap [from, to): they start before `to` and end after `from`. Shown calendars of connected accounts only, not gone, by start.
    public func events(from: Date, to: Date) -> [CalEvent] {
        let (clause, args) = Self.connectedClause()
        return events("WHERE e.gone=0 AND c.shown=1 AND e.start<? AND e.end>?\(clause) ORDER BY e.start, e.short_id", [to, from] + args)
    }

    /// Any event by its E-n, even a cancelled one (so a link to it still resolves); nil if there is none.
    public func event(shortID: Int64) -> CalEvent? {
        events("WHERE e.short_id=?", [shortID]).first
    }

    public func event(account: String, calendarID: String, eventID: String) -> CalEvent? {
        events("WHERE e.account=? AND e.calendar_id=? AND e.event_id=?", [account, calendarID, eventID]).first
    }

    /// An event made from a task (C6) is one whose `fb_card` is set, or that a live card points at.
    /// The one rule for "this is a task's event, not a meeting"; used by `nextMeeting` and `meetings(from:to:)`.
    private static let notTaskEvent = """
        e.fb_card IS NULL AND NOT EXISTS (SELECT 1 FROM cards k WHERE k.deleted=0 AND k.gcal_account=e.account AND k.gcal_event=e.event_id)
        """

    /// The meeting the bar shows: a timed event (not all-day, not made from a task, C6) that has not ended by `date`. One that
    /// starts within the bar's lead time (60 minutes) wins over one already in progress, so a long block under way never hides
    /// the real next meeting; with none starting soon, the one in progress; else the next one to start.
    public func nextMeeting(after date: Date) -> CalEvent? {
        let (clause, args) = Self.connectedClause()
        let base = "WHERE e.gone=0 AND c.shown=1\(clause) AND e.all_day=0 AND \(Self.notTaskEvent) AND e.end>?"
        let near = events(base + " AND e.start<=? ORDER BY e.start, e.short_id", args + [date, date.addingTimeInterval(BarMeeting.leadTime)])
        if let soon = near.first(where: { $0.start >= date }) { return soon }
        if let current = near.first { return current }
        return events(base + " ORDER BY e.start, e.short_id LIMIT 1", args + [date]).first
    }

    /// Like `events(from:to:)` but without events made from tasks (C6): what the phone's planning summary shows.
    public func meetings(from: Date, to: Date) -> [CalEvent] {
        let (clause, args) = Self.connectedClause()
        return events("WHERE e.gone=0 AND c.shown=1 AND e.start<? AND e.end>?\(clause) AND \(Self.notTaskEvent) ORDER BY e.start, e.short_id", [to, from] + args)
    }

    // MARK: Internals

    private static let columns = """
        e.short_id, e.account, e.calendar_id, e.event_id, e.start, e.end, e.all_day, e.start_day, e.end_day, e.title, e.location,
        e.video_link, e.description, e.html_link, e.recurring_id, e.google_updated, e.fb_card, e.gone, e.cancelled, e.original_start
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
                var e = CalEvent(shortID: DB.int(s, 0), account: DB.text(s, 1), calendarID: DB.text(s, 2), eventID: DB.text(s, 3),
                                start: start, end: end, allDay: allDay, title: DB.text(s, 9), location: DB.text(s, 10),
                                videoLink: DB.text(s, 11), description: DB.text(s, 12), htmlLink: DB.text(s, 13),
                                recurringID: DB.isNull(s, 14) ? nil : DB.text(s, 14), googleUpdated: DB.date(s, 15) ?? Date(),
                                fbCard: DB.isNull(s, 16) ? nil : DB.int(s, 16), gone: DB.int(s, 17) != 0, cancelled: DB.int(s, 18) != 0)
                e.originalStart = Self.originalStart(DB.isNull(s, 19) ? nil : DB.text(s, 19))
                return e
            }
        } ?? []
    }

    /// An instance's original start as kept: a day ("yyyy-MM-dd", midnight in the app's zone now, like all-day starts) or a time.
    private static func originalStart(_ v: String?) -> Date? {
        guard let v else { return nil }
        if v.count == 10 { return day(v) }
        return ISO8601DateFormatter().date(from: v)
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
