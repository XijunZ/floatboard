import Foundation

/// One change to send to Google.
public enum CalWrite: Equatable {
    case create(CalEventFields, cardID: Int64?, addMeet: Bool)
    case patch(eventID: String, title: String?, start: Date?, end: Date?, allDayStart: String?)
    case delete(eventID: String)

    var kind: String {
        switch self { case .create: "create"; case .patch: "patch"; case .delete: "delete" }
    }
    var eventID: String? {
        switch self { case .create: nil; case .patch(let id, _, _, _, _): id; case .delete(let id): id }
    }
    var cardID: Int64? {
        if case .create(_, let c, _) = self { return c }
        return nil
    }
}

/// An event's title and time as the board last saw them from Google when a change to it was queued: what tells, at sending
/// time, which fields Google changed since (C4).
public struct CalPatchBase: Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public init(title: String, start: Date, end: Date, allDay: Bool) { self.title = title; self.start = start; self.end = end; self.allDay = allDay }
    public init(_ e: CalEvent) { self.init(title: e.title, start: e.start, end: e.end, allDay: e.allDay) }
}

/// FloatBoard's own last write to an event that Google accepted: Google's `updated` stamp on its answer and the event as it
/// then was. A later `updated` up to this one is FloatBoard's own doing, never a change made in Google (C4).
public struct CalOwnWrite: Equatable, Codable {
    public var updated: Date
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public init(updated: Date, title: String, start: Date, end: Date, allDay: Bool) {
        self.updated = updated; self.title = title; self.start = start; self.end = end; self.allDay = allDay
    }
    public var base: CalPatchBase { CalPatchBase(title: title, start: start, end: end, allDay: allDay) }
}

/// A change waiting in the outbox.
public struct CalOutboxRow: Equatable {
    public var uuid: String
    public var account: String
    public var calendarID: String
    /// What to send; nil when the saved text can no longer be read (`lastError` says so).
    public var write: CalWrite?
    public var created: Date
    public var attempts: Int
    public var nextTry: Date
    public var lastError: String
    /// Set when Google refused the change for good: it is not sent again (`lastError` says why).
    public var failedAt: Date?
    /// For a patch: the event as cached when it was queued (nil when it was not cached, or for older saved rows).
    public var base: CalPatchBase? = nil
}

/// Changes to Google Calendar are written here first, in the same database as the board, so they survive being offline,
/// a crash or a restart, and are retried with a growing wait. Nothing here talks to Google: the sender in the app does.
@MainActor
public final class CalendarOutbox {
    private let db: DB
    private let store: Store
    private let cache: CalendarCache

    public init(store: Store) {
        self.db = store.db; self.store = store; self.cache = CalendarCache(store: store)
    }

    /// Called after a change the user made on the board (an edit, a delete, an undo, a drag) was queued, so the app can send
    /// it right away instead of at the next timed run. The sync's own catch-up writes do not call it. Set by the app.
    public static var nudge: (@MainActor () -> Void)?

    /// Marks a change as being on its way to Google (the sender sets this around the request), so undo leaves it alone.
    public func setInFlight(_ uuid: String, _ on: Bool) {
        if on { store.calendarInFlight.insert(uuid) } else { store.calendarInFlight.remove(uuid) }
    }

    /// Saves the change and returns its id. `delay` holds it back that long before it may be sent. Returns "" (and logs to Activity) if it could not be saved.
    @discardableResult
    public func enqueue(_ w: CalWrite, account: String, calendarID: String, now: Date = Date(), delay: TimeInterval = 0) -> String {
        let uuid = UUID().uuidString
        do {
            var base: CalPatchBase?
            if case .patch(let id, _, _, _, _) = w { base = cache.event(account: account, calendarID: calendarID, eventID: id).map(CalPatchBase.init) }
            let json = try Self.encode(w, base: base)
            try db.run("""
                INSERT INTO cal_outbox(uuid, kind, account, calendar_id, event_id, card_id, payload_json, created, attempts, next_try, last_error)
                VALUES(?,?,?,?,?,?,?,?,0,?,'')
                """, [uuid, w.kind, account, calendarID, w.eventID, w.cardID, json, now, now.addingTimeInterval(delay)])
            return uuid
        } catch {
            store.activity("calendar", .error, "Could not queue a calendar change", detail: "\(error)")
            return ""
        }
    }

    /// Unsent changes whose wait is over, oldest first. Changes Google refused for good are never due again.
    /// Per event only the oldest unsent change can be due: a later one (a delete after a create, a second edit) waits while
    /// an earlier one for the same event is backing off, so Google always gets an event's changes in the order they were made.
    public func due(now: Date) -> [CalOutboxRow] {
        var seen = Set<String>()
        var out: [CalOutboxRow] = []
        for r in rows("WHERE sent IS NULL AND failed_at IS NULL ORDER BY created, rowid", []) {
            if seen.insert(Self.eventKey(r)).inserted, r.nextTry <= now { out.append(r) }
        }
        return out
    }

    /// Takes the next change to send, skipping those `skip` says no to: read again from the database right now (so a change
    /// Undo removed, or one no longer due, is never sent from an old list) and, in the same step, marked as on its way, so
    /// Undo leaves it alone from here on. The sender clears the mark when Google has answered. Nil when nothing is due.
    public func claimNext(now: Date, skip: (CalOutboxRow) -> Bool) -> CalOutboxRow? {
        guard let row = due(now: now).first(where: { !skip($0) }) else { return nil }
        setInFlight(row.uuid, true)
        return row
    }

    /// The event a change is for: a create's own id on Google's side (the one later changes to it use), else the event it
    /// changes. An unreadable change stands alone.
    static func eventKey(_ r: CalOutboxRow) -> String {
        let event: String
        switch r.write {
        case .create?: event = googleEventID(forUUID: r.uuid)
        case let w?: event = w.eventID ?? "row:" + r.uuid
        case nil: event = "row:" + r.uuid
        }
        return r.account + "|" + r.calendarID + "|" + event
    }

    /// All unsent changes, oldest first (for showing what is waiting), including ones Google refused for good (`failedAt`).
    public func rows(unsent: Bool) -> [CalOutboxRow] {
        rows(unsent ? "WHERE sent IS NULL ORDER BY created, rowid" : "ORDER BY created, rowid", [])
    }

    /// New events (not made from a task) that are queued but not yet in the cache, as events with a negative `shortID` (no E-n
    /// yet), so the calendar can show them, marked as waiting, until Google confirms. Only those overlapping [from, to).
    /// One Google refused for good stays (see `failedNewEvents`) until the user discards it.
    public func pendingNewEvents(from: Date, to: Date) -> [CalEvent] {
        var out: [CalEvent] = []
        for row in rows(unsent: true) {
            guard case .create(let f, nil, _)? = row.write, f.start < to, f.end > from else { continue }
            let id = Self.googleEventID(forUUID: row.uuid)
            if cache.event(account: row.account, calendarID: row.calendarID, eventID: id) != nil { continue }
            out.append(CalEvent(shortID: -Int64(out.count + 1), account: row.account, calendarID: row.calendarID, eventID: id,
                                start: f.start, end: f.end, allDay: f.allDay, title: f.title, location: f.location,
                                videoLink: f.videoLink, description: f.description, htmlLink: f.htmlLink, recurringID: nil,
                                googleUpdated: f.googleUpdated, fbCard: nil))
        }
        return out
    }

    /// New events Google refused for good, by the event id their placeholder carries: the outbox row and Google's answer.
    public func failedNewEvents() -> [String: (uuid: String, error: String)] {
        var out: [String: (uuid: String, error: String)] = [:]
        for row in rows("WHERE sent IS NULL AND failed_at IS NOT NULL AND kind='create' AND card_id IS NULL", []) {
            out[Self.googleEventID(forUUID: row.uuid)] = (row.uuid, row.lastError)
        }
        return out
    }

    /// The user discarded a change Google refused: it is removed. Only an unsent change can be discarded.
    @discardableResult
    public func discard(uuid: String) -> Bool {
        do {
            try db.run("DELETE FROM cal_outbox WHERE uuid=? AND sent IS NULL", [uuid])
            store.activity("calendar", .info, "Discarded a calendar change Google refused", trace: uuid)
            return true
        } catch {
            store.activity("calendar", .error, "Could not discard a calendar change", detail: "\(error)", trace: uuid)
            return false
        }
    }

    /// True while any change still to be sent targets this event (the UI shows "waiting to send"). A refused one is not waiting.
    public func pending(eventShortID: Int64) -> Bool {
        guard let e = cache.event(shortID: eventShortID) else { return false }
        do {
            let n = try db.query("SELECT count(*) FROM cal_outbox WHERE sent IS NULL AND failed_at IS NULL AND account=? AND calendar_id=? AND event_id=?",
                                 [e.account, e.calendarID, e.eventID]) { DB.int($0, 0) }.first ?? 0
            return n > 0
        } catch {
            store.activity("calendar", .error, "Could not check for waiting calendar changes", detail: "\(error)")
            return false
        }
    }

    /// Google accepted the change. A create with a task links the task to the new event; the result (nil for a delete)
    /// goes into the calendar cache. The task and the outbox row change together first; if the cache write then fails the
    /// next calendar sync brings the event in, and the change is never sent twice.
    /// Returns false (and logs to Activity) when the local save failed: the change then stays unsent.
    /// `own` is false when `result` is Google's event as read, not the answer to a write FloatBoard made (nothing was sent).
    @discardableResult
    public func markSent(uuid: String, result: (eventID: String, fields: CalEventFields)?, own: Bool = true, now: Date = Date()) -> Bool {
        let row = rows("WHERE uuid=?", [uuid]).first
        do { try store.performThrowing {
            try db.run("UPDATE cal_outbox SET sent=?, last_error='' WHERE uuid=?", [now, uuid])
            if let row, case .create(_, let cardID?, _) = row.write, let result {
                try db.run("""
                    UPDATE cards SET gcal_account=?, gcal_calendar=?, gcal_event=?, gcal_link=?, gcal_synced_at=?, updated=? WHERE id=?
                    """, [row.account, row.calendarID, result.eventID, result.fields.htmlLink, now, now, cardID])
                try store.insertEvent(cardID, "added to Google Calendar (\(row.account))", actor: .user, at: now)
            }
        } } catch {
            store.activity("calendar", .error, "Could not record a calendar change as sent", detail: "\(error)", trace: uuid)
            return false
        }
        guard let row else { return true }
        if let result {
            cache.apply(account: row.account, calendarID: row.calendarID,
                        changes: [GoogleEventChange(eventID: result.eventID, cancelled: false, fields: result.fields)], nextToken: nil)
            if own { recordOwnWrite(account: row.account, calendarID: row.calendarID, eventID: result.eventID, result.fields) }
        } else if let id = row.write?.eventID {
            cache.apply(account: row.account, calendarID: row.calendarID,
                        changes: [GoogleEventChange(eventID: id, cancelled: true, fields: nil)], nextToken: nil)
        }
        return true
    }

    /// Remembers Google's answer to FloatBoard's own write (`CalOwnWrite`) on the cached event. A failure is logged; the next
    /// patch to this event then compares with the event as queued, as before.
    private func recordOwnWrite(account: String, calendarID: String, eventID: String, _ f: CalEventFields) {
        let own = CalOwnWrite(updated: f.googleUpdated, title: f.title, start: f.start, end: f.end, allDay: f.allDay)
        do {
            let json = String(decoding: try JSONEncoder().encode(own), as: UTF8.self)
            try db.run("UPDATE cal_events SET own_write=? WHERE account=? AND calendar_id=? AND event_id=?", [json, account, calendarID, eventID])
        } catch {
            store.activity("calendar", .error, "Could not note a calendar change as sent by FloatBoard", detail: "\(error)")
        }
    }

    /// FloatBoard's own last accepted write to this event, if one is known.
    public func ownWrite(account: String, calendarID: String, eventID: String) -> CalOwnWrite? {
        do {
            guard let json = try db.query("SELECT own_write FROM cal_events WHERE account=? AND calendar_id=? AND event_id=? AND own_write IS NOT NULL",
                                          [account, calendarID, eventID], { DB.text($0, 0) }).first else { return nil }
            return try JSONDecoder().decode(CalOwnWrite.self, from: Data(json.utf8))
        } catch {
            store.activity("calendar", .error, "Could not read FloatBoard's last change to an event", detail: "\(error)")
            return nil
        }
    }

    /// The id a created event gets on Google's side, the same every time for the same outbox row (Google accepts a second
    /// attempt with it only as a duplicate, never as a second event). 32 hex digits are valid Google event ids.
    public static func googleEventID(forUUID uuid: String) -> String {
        uuid.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// The send failed: keep the change, remember why, and wait 1 minute, then 2, 4 ... never more than an hour.
    public func markFailed(uuid: String, error: String, now: Date = Date()) {
        do {
            let attempts = try db.query("SELECT attempts FROM cal_outbox WHERE uuid=?", [uuid]) { DB.int($0, 0) }.first ?? 0
            let wait = Self.backoff(afterAttempts: Int(attempts) + 1)
            try db.run("UPDATE cal_outbox SET attempts=attempts+1, last_error=?, next_try=? WHERE uuid=?",
                       [error, now.addingTimeInterval(wait), uuid])
        } catch {
            store.activity("calendar", .error, "Could not record a failed calendar send", detail: "\(error)")
        }
    }

    /// Google refused the change for good (or it can't be read): keep it, with why, and never send it again.
    public func markDead(uuid: String, error: String, now: Date = Date()) {
        do {
            try db.run("UPDATE cal_outbox SET attempts=attempts+1, last_error=?, failed_at=? WHERE uuid=?", [error, now, uuid])
        } catch {
            store.activity("calendar", .error, "Could not record a refused calendar change", detail: "\(error)", trace: uuid)
        }
    }

    /// A queued patch, about to be sent, against the event as Google has it now (`current`, just read). When Google changed
    /// the event after the change was queued and after FloatBoard's own last accepted write to it (`own`: Google's later
    /// stamp from that write is FloatBoard's doing, not a change made in Google), the fields Google changed since (compared
    /// with the event as FloatBoard last knew it: its own write when that came after the change was queued, else `base`, the
    /// event as seen when queued; without either, every field counts as changed) keep Google's newer value: they are dropped
    /// from the patch (C4, newer change wins). Returns the patch to send, or nil when nothing is left to send. Anything other
    /// than a patch is returned as it is.
    public static func withoutNewerGoogleFields(_ w: CalWrite, queuedAt: Date, base: CalPatchBase?, own: CalOwnWrite? = nil,
                                                current: CalEventFields) -> CalWrite? {
        let since = max(queuedAt, own?.updated ?? .distantPast)
        guard case .patch(let id, var title, var start, var end, var day) = w, current.googleUpdated > since else { return w }
        let base = own.flatMap { $0.updated > queuedAt ? $0.base : nil } ?? base
        let titleChanged = base.map { $0.title != current.title } ?? true
        if titleChanged { title = nil }
        if start != nil || end != nil || day != nil {
            // Start and end are merged one by one; a switch between all-day and timed keeps them together.
            let startChanged = base.map { $0.start != current.start } ?? true, endChanged = base.map { $0.end != current.end } ?? true
            let kindChanged = base.map { $0.allDay != current.allDay } ?? true
            let converts = (day != nil) != current.allDay
            if kindChanged || (startChanged && endChanged) || (converts && (startChanged || endChanged)) || (day != nil && startChanged) {
                start = nil; end = nil; day = nil
            } else if let d = day, endChanged {
                // All-day, Google changed only the length: the board's new first day keeps Google's new length in days.
                let c = AppTime.calendar
                let days = c.dateComponents([.day], from: c.startOfDay(for: current.start), to: c.startOfDay(for: current.end)).day ?? 1
                end = days > 1 ? Due.startOfDay(d).flatMap { c.date(byAdding: .day, value: days, to: $0) } : nil
            } else if startChanged {
                // Google moved the start; the board's end stays if it still ends after it.
                start = nil
                if let e = end, e <= current.start { end = nil }
            } else if endChanged {
                // Google changed only the end: the board's start goes with Google's new length (or nothing about the end).
                end = start.map { $0.addingTimeInterval(current.end.timeIntervalSince(current.start)) }
            }
        }
        if title == nil && start == nil && end == nil && day == nil { return nil }
        return .patch(eventID: id, title: title, start: start, end: end, allDayStart: day)
    }

    /// Seconds to wait after the nth failure: 60, 120, 240 ... capped at 3600.
    static func backoff(afterAttempts n: Int) -> TimeInterval {
        min(3600, 60 * pow(2, Double(max(0, min(n, 12) - 1))))
    }

    // MARK: Internals

    private func rows(_ tail: String, _ args: [Any?]) -> [CalOutboxRow] {
        do {
            return try db.query("""
                SELECT uuid, account, calendar_id, payload_json, created, attempts, next_try, last_error, failed_at FROM cal_outbox \(tail)
                """, args) { s in
                var write: CalWrite?, base: CalPatchBase?
                var err = DB.text(s, 7)
                do { (write, base) = try Self.decode(DB.text(s, 3)) } catch {
                    err = "Unreadable saved change: \(error)"
                }
                return CalOutboxRow(uuid: DB.text(s, 0), account: DB.text(s, 1), calendarID: DB.text(s, 2), write: write,
                                    created: DB.date(s, 4) ?? Date(), attempts: Int(DB.int(s, 5)), nextTry: DB.date(s, 6) ?? Date(),
                                    lastError: err, failedAt: DB.date(s, 8), base: base)
            }
        } catch {
            store.activity("calendar", .error, "Could not read the calendar outbox", detail: "\(error)")
            return []
        }
    }

    // MARK: Saved form

    private struct Payload: Codable {
        var kind: String
        var eventID: String?
        var cardID: Int64?
        var addMeet: Bool?
        var title: String?
        var start: Double?, end: Double?
        var allDay: Bool?
        var startDay: String?, endDay: String?
        var location: String?, videoLink: String?, description: String?, htmlLink: String?, recurringID: String?
        var googleUpdated: Double?
        var fbCard: Int64?
        var allDayStart: String?
        var baseTitle: String?, baseStart: Double?, baseEnd: Double?, baseAllDay: Bool?
    }

    private static func encode(_ w: CalWrite, base: CalPatchBase? = nil) throws -> String {
        var p = Payload(kind: w.kind)
        if let base {
            p.baseTitle = base.title; p.baseStart = base.start.timeIntervalSince1970; p.baseEnd = base.end.timeIntervalSince1970; p.baseAllDay = base.allDay
        }
        switch w {
        case .create(let f, let cardID, let meet):
            p.cardID = cardID; p.addMeet = meet; p.title = f.title; p.start = f.start.timeIntervalSince1970
            p.end = f.end.timeIntervalSince1970; p.allDay = f.allDay; p.startDay = f.startDay; p.endDay = f.endDay
            p.location = f.location; p.videoLink = f.videoLink; p.description = f.description; p.htmlLink = f.htmlLink
            p.recurringID = f.recurringID; p.googleUpdated = f.googleUpdated.timeIntervalSince1970; p.fbCard = f.fbCard
        case .patch(let id, let title, let start, let end, let allDayStart):
            p.eventID = id; p.title = title; p.start = start?.timeIntervalSince1970; p.end = end?.timeIntervalSince1970
            p.allDayStart = allDayStart
        case .delete(let id):
            p.eventID = id
        }
        return String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
    }

    private static func decode(_ json: String) throws -> (CalWrite, CalPatchBase?) {
        let p = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        func date(_ v: Double?) -> Date? { v.map { Date(timeIntervalSince1970: $0) } }
        var base: CalPatchBase?
        if let t = p.baseTitle, let s = date(p.baseStart), let e = date(p.baseEnd) { base = CalPatchBase(title: t, start: s, end: e, allDay: p.baseAllDay ?? false) }
        return (try decodeWrite(p, date), base)
    }

    private static func decodeWrite(_ p: Payload, _ date: (Double?) -> Date?) throws -> CalWrite {
        switch p.kind {
        case "create":
            guard let title = p.title, let start = date(p.start), let end = date(p.end) else { throw DBError.sql("create is missing fields") }
            let f = CalEventFields(start: start, end: end, allDay: p.allDay ?? false, startDay: p.startDay, endDay: p.endDay,
                                   title: title, location: p.location ?? "", videoLink: p.videoLink ?? "", description: p.description ?? "",
                                   htmlLink: p.htmlLink ?? "", recurringID: p.recurringID,
                                   googleUpdated: date(p.googleUpdated) ?? start, fbCard: p.fbCard)
            return .create(f, cardID: p.cardID, addMeet: p.addMeet ?? false)
        case "patch":
            guard let id = p.eventID else { throw DBError.sql("patch has no event") }
            return .patch(eventID: id, title: p.title, start: date(p.start), end: date(p.end), allDayStart: p.allDayStart)
        case "delete":
            guard let id = p.eventID else { throw DBError.sql("delete has no event") }
            return .delete(eventID: id)
        default:
            throw DBError.sql("unknown kind \(p.kind)")
        }
    }
}
