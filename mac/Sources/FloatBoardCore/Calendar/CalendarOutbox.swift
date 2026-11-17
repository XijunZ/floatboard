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

/// What FloatBoard knows Google had for each linked field of an event (the title; the start; the end, each with all-day):
/// the value, the `updated` stamp of the moment it was known, and whether the value was put there by someone else in
/// Google (`external`) rather than by FloatBoard's own write. It is updated when FloatBoard writes a field (only the fields
/// that write set: an end-only write leaves the start's record alone), when it reads the event before sending a change,
/// and when a calendar sync brings the event in. A field counts as changed in Google by its VALUE: when Google's current
/// value differs from the one recorded; the stamp then only says when, for newest-wins against a queued edit (C4).
public struct CalOwnWrite: Equatable, Codable {
    public struct Title: Equatable, Codable {
        public var updated: Date; public var title: String; public var external: Bool?
        public init(updated: Date, title: String, external: Bool? = nil) { self.updated = updated; self.title = title; self.external = external }
    }
    /// One end of the event's time.
    public struct Edge: Equatable, Codable {
        public var updated: Date; public var value: Date; public var allDay: Bool; public var external: Bool?
        public init(updated: Date, value: Date, allDay: Bool, external: Bool? = nil) {
            self.updated = updated; self.value = value; self.allDay = allDay; self.external = external
        }
    }
    /// Saved before start and end were kept apart: both ends at once, FloatBoard's own write. Read as both; never written.
    public struct Time: Equatable, Codable { public var updated: Date; public var start: Date; public var end: Date; public var allDay: Bool }
    public var title: Title?
    public var start: Edge?
    public var end: Edge?
    public var time: Time?
    public init(title: Title? = nil, start: Edge? = nil, end: Edge? = nil) { self.title = title; self.start = start; self.end = end }
    /// The start's record (or the older both-ends one).
    public var startAck: Edge? { start ?? time.map { Edge(updated: $0.updated, value: $0.start, allDay: $0.allDay) } }
    /// The end's record (or the older both-ends one).
    public var endAck: Edge? { end ?? time.map { Edge(updated: $0.updated, value: $0.end, allDay: $0.allDay) } }
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
    /// For a patch: what was last sent to Google for it (saved before the request), nil when it was never sent. A retry
    /// that finds Google already has these values knows they are FloatBoard's own write whose answer was lost.
    public var attempted: CalWrite? = nil
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
    /// `wrote` is the change actually sent when it differs from the queued one (fields left to Google were dropped): only the
    /// field groups it set are recorded as FloatBoard's own write.
    @discardableResult
    public func markSent(uuid: String, result: (eventID: String, fields: CalEventFields)?, own: Bool = true, wrote: CalWrite? = nil,
                         now: Date = Date()) -> Bool {
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
            if own, let w = wrote ?? row.write { recordOwnWrite(account: row.account, calendarID: row.calendarID, eventID: result.eventID, w, result.fields) }
        } else if let id = row.write?.eventID {
            cache.apply(account: row.account, calendarID: row.calendarID,
                        changes: [GoogleEventChange(eventID: id, cancelled: true, fields: nil)], nextToken: nil)
        }
        return true
    }

    /// Remembers Google's answer to FloatBoard's own write on the cached event: the fields that write set are now known as
    /// FloatBoard's. A failure is logged; the next change to this event is then decided against the event as queued.
    private func recordOwnWrite(account: String, calendarID: String, eventID: String, _ w: CalWrite, _ f: CalEventFields) {
        var setTitle = true, setStart = true, setEnd = true
        // An all-day move writes both dates (the end defaults to the next day); a timed patch writes only what it carries.
        if case .patch(_, let t, let s, let e, let d) = w { setTitle = t != nil; setStart = s != nil || d != nil; setEnd = e != nil || d != nil }
        guard setTitle || setStart || setEnd else { return }
        var own = ownWrite(account: account, calendarID: calendarID, eventID: eventID) ?? CalOwnWrite()
        if own.time != nil { own.start = own.startAck; own.end = own.endAck; own.time = nil }   // older form, now kept per end
        if setTitle { own.title = .init(updated: f.googleUpdated, title: f.title) }
        if setStart { own.start = .init(updated: f.googleUpdated, value: f.start, allDay: f.allDay) }
        if setEnd { own.end = .init(updated: f.googleUpdated, value: f.end, allDay: f.allDay) }
        saveKnown(account: account, calendarID: calendarID, eventID: eventID, own)
    }

    /// Saves what is known of the event in Google (`CalOwnWrite`). A failure is logged.
    public func saveKnown(account: String, calendarID: String, eventID: String, _ known: CalOwnWrite) {
        do {
            let json = String(decoding: try JSONEncoder().encode(known), as: UTF8.self)
            try db.run("UPDATE cal_events SET own_write=? WHERE account=? AND calendar_id=? AND event_id=?", [json, account, calendarID, eventID])
        } catch {
            store.activity("calendar", .error, "Could not note what Google has for an event", detail: "\(error)")
        }
    }

    /// What is known after reading `current` from Google: a field whose value is still the recorded one keeps its record;
    /// one that differs was changed in Google (external) and is recorded with Google's stamp now. A field with no record yet
    /// is compared with `base` (the event as cached when the change was queued): the same value is known, not a change in
    /// Google; without either it counts as changed in Google.
    public static func observed(_ known: CalOwnWrite?, base: CalPatchBase?, current: CalEventFields) -> CalOwnWrite {
        var k = known ?? CalOwnWrite()
        if k.time != nil { k.start = k.startAck; k.end = k.endAck; k.time = nil }
        let u = current.googleUpdated
        if k.title?.title != current.title {
            k.title = .init(updated: u, title: current.title, external: k.title == nil && base?.title == current.title ? nil : true)
        }
        func edge(_ e: CalOwnWrite.Edge?, _ value: Date, _ baseValue: Date?) -> CalOwnWrite.Edge {
            if let e, e.value == value, e.allDay == current.allDay { return e }
            let known = e == nil && baseValue == value && base?.allDay == current.allDay
            return .init(updated: u, value: value, allDay: current.allDay, external: known ? nil : true)
        }
        k.start = edge(k.start, current.start, base?.start)
        k.end = edge(k.end, current.end, base?.end)
        return k
    }

    /// Saves on the row the patch about to be sent (before the request goes), so a retry after a lost answer can tell
    /// FloatBoard's own write from a change made in Google. Returns false (logged) when it could not be saved: then it is
    /// not sent this time.
    public func markAttempted(uuid: String, _ w: CalWrite) -> Bool {
        guard case .patch(_, let t, let st, let en, let d) = w else { return true }
        do {
            guard let json = try db.query("SELECT payload_json FROM cal_outbox WHERE uuid=?", [uuid], { DB.text($0, 0) }).first else { return false }
            var p = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
            p.tried = true; p.triedTitle = t; p.triedStart = st?.timeIntervalSince1970; p.triedEnd = en?.timeIntervalSince1970; p.triedDay = d
            try db.run("UPDATE cal_outbox SET payload_json=? WHERE uuid=?", [String(decoding: try JSONEncoder().encode(p), as: UTF8.self), uuid])
            return true
        } catch {
            store.activity("calendar", .error, "Could not note a calendar change as being sent; it waits", detail: "\(error)", trace: uuid)
            return false
        }
    }

    /// A retry of a patch already sent once (`attempted`): each field for which Google now has exactly the value that was
    /// sent is FloatBoard's own write whose answer was lost, recorded as such (not as a change made in Google). If Google
    /// set that same value itself while the request was on its way, it is taken as FloatBoard's too (accepted ambiguity).
    public static func claimingOwnRetry(_ known: CalOwnWrite, attempted: CalWrite?, current: CalEventFields) -> CalOwnWrite {
        guard case .patch(_, let t, let st, let en, let d)? = attempted else { return known }
        var k = known
        let u = current.googleUpdated
        if let t, t == current.title { k.title = .init(updated: u, title: current.title) }
        if let d {
            // All-day: the first day and the (exclusive) end day are decided one by one. The end sent is the given end's
            // day, else the day after the first (as `GoogleCalendarAPI.patch` sends it).
            guard current.allDay else { return k }
            if current.startDay == d { k.start = .init(updated: u, value: current.start, allDay: true) }
            let sentEnd = en.map(Due.dayString) ?? Due.startOfDay(d).flatMap { AppTime.calendar.date(byAdding: .day, value: 1, to: $0) }.map(Due.dayString)
            if let sentEnd, current.endDay == sentEnd { k.end = .init(updated: u, value: current.end, allDay: true) }
        } else if !current.allDay {
            if let st, st == current.start { k.start = .init(updated: u, value: current.start, allDay: false) }
            if let en, en == current.end { k.end = .init(updated: u, value: current.end, allDay: false) }
        }
        return k
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
            try db.run("UPDATE cal_outbox SET attempts=attempts+1, last_error=?, next_try=?, conflicts=0 WHERE uuid=?",
                       [error, now.addingTimeInterval(wait), uuid])
        } catch {
            store.activity("calendar", .error, "Could not record a failed calendar send", detail: "\(error)")
        }
    }

    /// The event changed in Google between reading it and sending the change (412). Returns how many times in a row that has
    /// happened. The first is tried again at the next run; from the second on the change waits like a failure (1 minute, 2,
    /// 4 ... at most an hour), so an event that keeps changing does not take a request pair every run. Not counted as a failure.
    @discardableResult
    public func markConflict(uuid: String, now: Date = Date()) -> Int {
        do {
            let n = Int(try db.query("SELECT conflicts FROM cal_outbox WHERE uuid=?", [uuid]) { DB.int($0, 0) }.first ?? 0) + 1
            let wait = n >= 2 ? Self.backoff(afterAttempts: n - 1) : 0
            try db.run("UPDATE cal_outbox SET conflicts=?, next_try=? WHERE uuid=?", [n, now.addingTimeInterval(wait), uuid])
            return n
        } catch {
            store.activity("calendar", .error, "Could not record a calendar change that met a newer change in Google", detail: "\(error)", trace: uuid)
            return 0
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

    /// A queued patch, about to be sent, against the event as Google has it now (`current`, just read). Per field (title,
    /// start, end), Google changed it when its value differs from what FloatBoard knew Google had (`own`, else `base`, the
    /// event as cached when queued; see `observed`) and from what this change sends. Such a field keeps Google's value when
    /// Google's change is newer than this change (newest wins, C4); an older one is overwritten by this change. Returns the
    /// patch to send, or nil when nothing is left to send. A field that already has the value being sent is left out (it
    /// stays Google's if Google set it). Anything other than a patch is returned as it is.
    public static func withoutNewerGoogleFields(_ w: CalWrite, queuedAt: Date, base: CalPatchBase?, own: CalOwnWrite? = nil,
                                                current: CalEventFields) -> CalWrite? {
        guard case .patch(let id, var title, var start, var end, var day) = w else { return w }
        let seen = observed(own, base: base, current: current)
        func googleNewer(_ external: Bool?, _ at: Date?) -> Bool { external == true && (at ?? .distantFuture) > queuedAt }
        if let t = title, t != current.title, googleNewer(seen.title?.external, seen.title?.updated) { title = nil }
        if start != nil || end != nil || day != nil {
            // Start and end are merged one by one; a switch between all-day and timed keeps them together. Sending the
            // value Google already has is no conflict.
            let sameStart = day == nil && start == current.start && !current.allDay
            let sameEnd = day == nil && end == current.end && !current.allDay
            let startChanged = !sameStart && googleNewer(seen.start?.external, seen.start?.updated)
            let endChanged = !sameEnd && googleNewer(seen.end?.external, seen.end?.updated)
            let converts = (day != nil) != current.allDay
            if (startChanged && endChanged) || (converts && (startChanged || endChanged)) || (day != nil && startChanged) {
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
        // A field that already has the value being sent is not sent: the write would change nothing, and noting it as
        // FloatBoard's own would erase the record that Google set it (an older queued edit could then overwrite it).
        if title == current.title { title = nil }
        if day == nil, !current.allDay {
            if start == current.start { start = nil }
            if end == current.end { end = nil }
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
                var write: CalWrite?, base: CalPatchBase?, attempted: CalWrite?
                var err = DB.text(s, 7)
                do { (write, base, attempted) = try Self.decode(DB.text(s, 3)) } catch {
                    err = "Unreadable saved change: \(error)"
                }
                return CalOutboxRow(uuid: DB.text(s, 0), account: DB.text(s, 1), calendarID: DB.text(s, 2), write: write,
                                    created: DB.date(s, 4) ?? Date(), attempts: Int(DB.int(s, 5)), nextTry: DB.date(s, 6) ?? Date(),
                                    lastError: err, failedAt: DB.date(s, 8), base: base, attempted: attempted)
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
        /// The patch as last sent (only the fields sent): set just before each send.
        var triedTitle: String?, triedStart: Double?, triedEnd: Double?, triedDay: String?, tried: Bool?
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

    private static func decode(_ json: String) throws -> (CalWrite, CalPatchBase?, CalWrite?) {
        let p = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        func date(_ v: Double?) -> Date? { v.map { Date(timeIntervalSince1970: $0) } }
        var base: CalPatchBase?
        if let t = p.baseTitle, let s = date(p.baseStart), let e = date(p.baseEnd) { base = CalPatchBase(title: t, start: s, end: e, allDay: p.baseAllDay ?? false) }
        let write = try decodeWrite(p, date)
        var tried: CalWrite?
        if p.tried == true, let id = write.eventID {
            tried = .patch(eventID: id, title: p.triedTitle, start: date(p.triedStart), end: date(p.triedEnd), allDayStart: p.triedDay)
        }
        return (write, base, tried)
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
