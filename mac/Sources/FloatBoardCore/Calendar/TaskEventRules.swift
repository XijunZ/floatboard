import Foundation

/// How a task and the Google event made for it stay in step. Pure board logic: it reads the calendar cache and writes
/// changes for Google into the calendar outbox; the sender in the connectors module talks to Google.
///
/// - A task gets an event only when the user puts it there (drag onto a time, "Add to calendar"): D7.
/// - Its title and time stay in step both ways (D10); the newer change wins per field (C4).
/// - Deleting the task deletes the event FloatBoard made for it (D8); clearing the due or finishing the task leaves it (D8, C3).
/// - Deleting the event in Google leaves the task, keeps its date, drops its time and its link (D4).
/// - Events made in Google never create or change tasks (D9): only tasks that carry a link are looked at.
@MainActor
public enum TaskEventRules {
    /// How far the sync reads: 30 days back, 90 days ahead.
    public static let windowBack: TimeInterval = 30 * 86400
    public static let windowAhead: TimeInterval = 90 * 86400
    /// Length of an event made for a task (C1).
    public static let eventLength: TimeInterval = 30 * 60
    /// Meta key holding the account new events go to (Settings › Calendar).
    public static let defaultAccountKey = "calendar_default_account"
    /// Who changed a task when Google's value was copied onto it.
    public static let actor = Actor.connector("calendar")

    /// For every task that carries a link to an event: copies Google's newer title or time onto the task, queues the
    /// task's newer title or time for Google, and lets go of the link when the event is gone from Google. Tasks with a
    /// change still waiting to be sent are left alone until it has gone. Returns how many tasks it changed or queued for.
    @discardableResult
    public static func reconcile(store: Store, cache: CalendarCache, now: Date, unreadCalendars: Set<String> = []) -> Int {
        var touched = 0
        let links: [LinkedCard]
        do { try store.backfillOldLinks() } catch {
            store.activity("calendar", .error, "Could not update tasks added to the calendar by an earlier version", detail: "\(error)")
        }
        do { links = try store.linkedCards() } catch {
            store.activity("calendar", .error, "Could not read which tasks are on the calendar", detail: "\(error)")
            return 0
        }
        for l in links {
            guard let card = store.card(l.cardID) else { continue }
            do {
                if try store.hasUnsentCalendarWrite(cardID: card.id, link: l.link) { continue }
                guard let ev = cache.event(account: l.link.account, calendarID: l.link.calendar, eventID: l.link.event) else { continue }
                if ev.gone {
                    // Only Google's own cancellation counts (D4). An event hidden by a sync reset may still exist, and a calendar
                    // whose read failed in this pass says nothing new.
                    guard ev.cancelled, !unreadCalendars.contains(key(l.link.account, l.link.calendar)) else { continue }
                    try store.performThrowing { try store.dropEventLink(card, now: now) }
                    touched += 1
                } else if try store.align(card, with: ev, link: l, cache: cache, now: now) {
                    touched += 1
                }
            } catch {
                store.activity("calendar", .error, "Could not bring a task and its calendar event in step", detail: "task \(card.id): \(error)")
            }
        }
        return touched
    }

    /// Names one calendar in `reconcile`'s `unreadCalendars`.
    public static func key(_ account: String, _ calendar: String) -> String { account + "|" + calendar }
}

struct EventLink: Equatable {
    var account: String, calendar: String, event: String
}

struct LinkedCard {
    var cardID: Int64
    var link: EventLink
    var syncedAt: Date?
    /// `CalendarBaseline.pending`, a saved baseline, or "" (none).
    var baseline: String = ""
}

/// A task linked to its event by version 10, whose history cannot tell which side changed last ("edited" rows only):
/// the first sync after the upgrade records what both sides hold and changes neither. After that, a field that differs is
/// settled by which side moved away from this record (both moved: the newer change wins), until the two agree again.
struct CalendarBaseline: Codable, Equatable {
    /// Set by the upgrade's backfill: the next sync takes the record.
    static let pending = "pending"
    var at: Double
    var title: String
    var due: Double?
    var timed: Bool
    var googleTitle: String
    var googleStart: Double
    var googleTimed: Bool

    init(card: Card, event ev: CalEvent, now: Date) {
        at = now.timeIntervalSince1970; title = card.title; due = card.due?.timeIntervalSince1970; timed = card.dueHasTime
        googleTitle = ev.title; googleStart = ev.start.timeIntervalSince1970; googleTimed = !ev.allDay
    }

    var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" } // try?-ok: plain fields always encode; "" means no record, the plain rule applies
    static func decode(_ s: String) throws -> CalendarBaseline? {
        guard !s.isEmpty, s != pending else { return nil }
        return try JSONDecoder().decode(CalendarBaseline.self, from: Data(s.utf8))
    }
    var dueDate: Date? { due.map { Date(timeIntervalSince1970: $0) } }
    var googleStartDate: Date { Date(timeIntervalSince1970: googleStart) }
}

/// Who wins a field that differs between a task and its event.
enum FieldWinner { case google, board, neither, newer }

extension Store {
    // MARK: Putting a task on the calendar

    /// Drag: the task's due becomes `start` (with a time), and its event is created, or moved if it already has one (C1, D7).
    /// New events go to `account`, else the default account (Settings), else the first connected one; 30 minutes long.
    /// Returns true when a change for Google was queued.
    @discardableResult
    public func placeOnCalendar(cardID: Int64, start: Date, account: String?, now: Date = Date()) -> Bool {
        guard card(cardID) != nil else { return false }
        var queued = false
        perform {
            let parts = AppTime.calendar.dateComponents([.hour, .minute], from: start)
            try setDueRow(cardID, day: start, time: parts, actor: .user, now: now, patchCalendar: false)
            guard let c = try cardForEvent(cardID), let due = c.due else { return }
            let outbox = CalendarOutbox(store: self)
            if let t = try eventTarget(cardID) {
                let length = CalendarCache(store: self).event(account: t.account, calendarID: t.calendar, eventID: t.event)
                    .map { $0.allDay ? TaskEventRules.eventLength : $0.end.timeIntervalSince($0.start) } ?? TaskEventRules.eventLength
                outbox.enqueue(.patch(eventID: t.event, title: nil, start: due, end: due.addingTimeInterval(length), allDayStart: nil),
                               account: t.account, calendarID: t.calendar, now: now)
                queued = true
            } else if let (acct, calID) = try resolveCalendar(account) {
                guard let f = eventFields(for: c, now: now) else { return }
                outbox.enqueue(.create(f, cardID: cardID, addMeet: false), account: acct, calendarID: calID, now: now)
                queued = true
            } else {
                activity("calendar", .warning, "No Google calendar to put this task on; connect an account in Settings")
            }
        }
        if queued { calendarQueued() }
        return queued
    }

    /// "Add to calendar" on a task: queues an event on the account's main calendar, with a Meet call if asked. A task with a
    /// time makes a 30-minute event; a date-only task makes an all-day event (D11). A task already on the calendar gets no
    /// second event. Uses the values of `card` as given (the editor may hold unsaved ones). Returns true when queued.
    @discardableResult
    public func addToCalendar(_ card: Card, account: String, addMeet: Bool, now: Date = Date()) -> Bool {
        guard let due = card.due else {
            activity("calendar", .warning, "Give the task a due date before adding it to the calendar")
            return false
        }
        var queued = false
        perform {
            if try eventTarget(card.id) != nil {
                activity("calendar", .info, "Task \(card.id) is already on the calendar; no second event made")
                return
            }
            guard let (acct, calID) = try resolveCalendar(account) else { return }
            guard let f = eventFields(for: card, now: now) else { return }
            CalendarOutbox(store: self).enqueue(.create(f, cardID: card.id, addMeet: addMeet), account: acct, calendarID: calID, now: now)
            queued = true
        }
        if queued { calendarQueued() }
        return queued
    }

    // MARK: Hooks used by the board's own actions

    /// After a title or time edit on a task that has an event (or one on its way): queues a patch with just those fields (D10).
    /// Clearing the due writes nothing (D8). Called inside the edit's transaction.
    func queueCalendarPatch(old: Card, new: Card, now: Date) throws {
        let titleChanged = old.title != new.title
        let timeChanged = !Store.sameDue(old.due, old.dueHasTime, new.due, new.dueHasTime)
        guard titleChanged || (timeChanged && new.due != nil), let t = try eventTarget(new.id) else { return }
        var start: Date?, end: Date?, allDayStart: String?
        if timeChanged, let due = new.due {
            let cached = CalendarCache(store: self).event(account: t.account, calendarID: t.calendar, eventID: t.event)
            if new.dueHasTime {
                let length = cached.map { $0.allDay ? TaskEventRules.eventLength : $0.end.timeIntervalSince($0.start) } ?? TaskEventRules.eventLength
                start = due; end = due.addingTimeInterval(length)
            } else {
                allDayStart = Due.dayString(due)
                end = allDayEnd(startingOn: Due.dayString(due), keeping: cached)
            }
        }
        let row = CalendarOutbox(store: self).enqueue(.patch(eventID: t.event, title: titleChanged ? new.title : nil, start: start, end: end, allDayStart: allDayStart),
                                                      account: t.account, calendarID: t.calendar, now: now)
        if !row.isEmpty { calendarQueued() }
    }

    /// The (exclusive) end for an all-day event moved to start on `day`: as many days later as the event lasts now, because an
    /// event's length belongs to Google (D10). Nil, meaning one day, when the event lasts one day, was timed, or is not known.
    func allDayEnd(startingOn day: String, keeping ev: CalEvent?) -> Date? {
        guard let ev, ev.allDay, let s = Due.startOfDay(day) else { return nil }
        let days = AppTime.calendar.dateComponents([.day], from: AppTime.calendar.startOfDay(for: ev.start), to: AppTime.calendar.startOfDay(for: ev.end)).day ?? 1
        guard days > 1 else { return nil }
        return AppTime.calendar.date(byAdding: .day, value: days, to: s)
    }

    /// Task deleted: delete the event FloatBoard made for it. An event that came from Google (not marked as ours in the
    /// cache) is left alone. Returns the event targeted and the outbox row that deletes it, so undo can take it back.
    /// `delay` is how long the delete is held back so Undo wins: the Undo bar here, or the phone's Undo (`phoneCalendarDeleteDelay`).
    func queueCalendarDelete(cardID: Int64, now: Date, delay: TimeInterval = Store.calendarDeleteDelay) throws -> (link: EventLink, row: String)? {
        guard let t = try eventTarget(cardID) else { return nil }
        // An event marked as made for another task is not this one's. Events from before the mark existed carry none: they are ours.
        if let cached = CalendarCache(store: self).event(account: t.account, calendarID: t.calendar, eventID: t.event),
           let mark = cached.fbCard, mark != cardID {
            return nil
        }
        let row = CalendarOutbox(store: self).enqueue(.delete(eventID: t.event), account: t.account, calendarID: t.calendar, now: now,
                                                    delay: delay)   // held back so Undo wins (R19)
        guard !row.isEmpty else { return nil }   // not queued (logged by enqueue): the event stays, nothing to undo
        // No scheduler nudge: the delete is not due until the Undo bar is gone.
        return (t, row)
    }

    /// Delete undone. A delete that has not reached Google is taken back: its outbox row is removed and the task keeps its link,
    /// so the event stays exactly as it is (guests, Meet link, description; nobody is sent a cancellation). Only a delete that
    /// was sent, or is being sent right now, is followed by a new event.
    func undoCalendarDelete(cardID: Int64, target: EventLink, row: String, now: Date) throws {
        let unsent = try db.query("SELECT count(*) FROM cal_outbox WHERE uuid=? AND sent IS NULL", [row]) { DB.int($0, 0) }.first ?? 0
        if unsent > 0 && !calendarInFlight.contains(row) {
            try db.run("DELETE FROM cal_outbox WHERE uuid=?", [row])
            activity("calendar", .info, "Task \(cardID) is back; its calendar event was not deleted after all", trace: row)
            return
        }
        try queueCalendarRecreate(cardID: cardID, target: target, now: now)
    }

    /// The event was already deleted in Google: queue a new one, under a new outbox id; the send links the task to it.
    /// A task with no due can't have one made: one Activity line says so.
    func queueCalendarRecreate(cardID: Int64, target: EventLink, now: Date) throws {
        guard let c = try cardForEvent(cardID) else { return }
        guard let f = eventFields(for: c, now: now) else {
            activity("calendar", .warning, "Task \(cardID) is back, but its calendar event was already deleted in Google and can't be made again: the task has no due date")
            return
        }
        guard !CalendarOutbox(store: self).enqueue(.create(f, cardID: cardID, addMeet: false), account: target.account, calendarID: target.calendar, now: now).isEmpty else { return }
        calendarQueued()
    }

    /// A change the user made on the board was queued for Google: ask the app to send it now.
    func calendarQueued() { CalendarOutbox.nudge?() }

    /// History rows for a board edit, one per field, so the next sync can tell when each last changed (C4).
    func recordFieldChanges(old: Card, new: Card, actor: Actor, now: Date) throws {
        if old.title != new.title {
            try insertEvent(new.id, "title: " + String(new.title.prefix(80)), actor: actor, at: now)
        }
        if !Store.sameDue(old.due, old.dueHasTime, new.due, new.dueHasTime) {
            try insertEvent(new.id, "due: " + (new.due.map { Fmt.due($0, hasTime: new.dueHasTime) } ?? "none"), actor: actor, at: now)
        }
    }

    // MARK: Used by the rules

    func linkedCards() throws -> [LinkedCard] {
        try db.query("""
            SELECT id, gcal_account, gcal_calendar, gcal_event, gcal_synced_at, gcal_baseline FROM cards
            WHERE deleted=0 AND gcal_event<>'' AND gcal_calendar<>'' ORDER BY id
            """) { s in
            LinkedCard(cardID: DB.int(s, 0), link: EventLink(account: DB.text(s, 1), calendar: DB.text(s, 2), event: DB.text(s, 3)),
                       syncedAt: DB.date(s, 4), baseline: DB.text(s, 5))
        }
    }

    /// Where this task's event is (or will be): the newest create still waiting to be sent, else the saved link.
    func eventTarget(_ cardID: Int64) throws -> EventLink? {
        if let pending = try db.query("""
            SELECT uuid, account, calendar_id FROM cal_outbox WHERE sent IS NULL AND failed_at IS NULL AND kind='create' AND card_id=?
            ORDER BY created DESC, rowid DESC LIMIT 1
            """, [cardID], { s in EventLink(account: DB.text(s, 1), calendar: DB.text(s, 2), event: CalendarOutbox.googleEventID(forUUID: DB.text(s, 0))) }).first {
            return pending
        }
        let own = try db.query("SELECT gcal_account, gcal_calendar, gcal_event FROM cards WHERE id=? AND gcal_event<>''",
                               [cardID]) { EventLink(account: DB.text($0, 0), calendar: DB.text($0, 1), event: DB.text($0, 2)) }.first
        guard var l = own, l.calendar.isEmpty else { return own }
        guard let cal = try oldLinkCalendar(account: l.account, event: l.event) else { return nil }
        l.calendar = cal
        return l
    }

    /// The calendar of an event added by the first version of "Add to calendar", which always used the account's main calendar
    /// ("primary"): the cached event with this account and id tells exactly which calendar that is; failing that, the account's
    /// main calendar as chosen for new events (the one Google flags as main, else the "primary" stand-in).
    private func oldLinkCalendar(account: String, event: String) throws -> String? {
        guard !account.isEmpty else { return nil }
        if let c = try db.query("SELECT calendar_id FROM cal_events WHERE account=? AND event_id=? ORDER BY gone, short_id LIMIT 1",
                                [account, event], { DB.text($0, 0) }).first { return c }
        return try resolveCalendar(account)?.1
    }

    /// Tasks linked by the first version have no calendar saved: save it, so nothing else has to special-case them. Their
    /// first sync records both sides instead of changing either (`CalendarBaseline`).
    func backfillOldLinks() throws {
        let old = try db.query("SELECT id, gcal_account, gcal_event FROM cards WHERE deleted=0 AND gcal_event<>'' AND gcal_calendar='' AND gcal_account<>''")
            { (DB.int($0, 0), DB.text($0, 1), DB.text($0, 2)) }
        for (id, account, event) in old {
            guard let cal = try oldLinkCalendar(account: account, event: event) else { continue }
            try performThrowing { try db.run("UPDATE cards SET gcal_calendar=?, gcal_baseline=? WHERE id=?", [cal, CalendarBaseline.pending, id]) }
        }
    }

    /// A change for this task or its event still to be sent. One Google refused for good does not count: it will never be
    /// sent, so it must not hold the task back.
    func hasUnsentCalendarWrite(cardID: Int64, link: EventLink) throws -> Bool {
        let n = try db.query("""
            SELECT count(*) FROM cal_outbox WHERE sent IS NULL AND failed_at IS NULL
            AND (card_id=? OR (account=? AND calendar_id=? AND event_id=?))
            """, [cardID, link.account, link.calendar, link.event]) { DB.int($0, 0) }.first ?? 0
        return n > 0
    }

    /// When the newest change for this event that Google refused for good was queued, if any.
    private func lastRefusedWrite(_ link: EventLink) throws -> Date? {
        try db.query("""
            SELECT max(created) FROM cal_outbox WHERE sent IS NULL AND failed_at IS NOT NULL AND account=? AND calendar_id=? AND event_id=?
            """, [link.account, link.calendar, link.event]) { DB.date($0, 0) }.first ?? nil
    }

    /// The account and calendar a new event goes to (`newEventCalendar`, the rule the New event sheet uses too).
    private func resolveCalendar(_ account: String?) throws -> (String, String)? {
        guard let target = newEventCalendar(account: account) else {
            activity("calendar", .warning, "No Google calendar to put this task on; connect an account in Settings")
            return nil
        }
        return (target.account, target.calendarID)
    }

    /// The event to make for a task: a 30-minute block at its time, or an all-day event for a date-only task (D11). Nil without a due.
    private func eventFields(for c: Card, now: Date) -> CalEventFields? {
        guard let due = c.due else { return nil }
        if c.dueHasTime {
            return CalEventFields(start: due, end: due.addingTimeInterval(TaskEventRules.eventLength), title: c.title,
                                  description: eventDescription(c), googleUpdated: now, fbCard: c.id)
        }
        let day = Due.dayString(due)
        let s = Due.startOfDay(day) ?? due
        let next = AppTime.calendar.date(byAdding: .day, value: 1, to: s) ?? s.addingTimeInterval(86400)
        return CalEventFields(start: s, end: next, allDay: true, startDay: day, endDay: Due.dayString(next), title: c.title,
                              description: eventDescription(c), googleUpdated: now, fbCard: c.id)
    }

    /// What the event's description gets: the task's notes and its call link.
    private func eventDescription(_ c: Card) -> String {
        var d = c.notes
        if let m = c.meetLink, !d.contains(m.absoluteString) { d += (d.isEmpty ? "" : "\n\n") + m.absoluteString }
        return d
    }

    /// The task with its notes and link, which `currentCard` leaves out.
    private func cardForEvent(_ id: Int64) throws -> Card? {
        guard var c = try currentCard(id)?.card else { return nil }
        if let r = try db.query("SELECT notes, link FROM cards WHERE id=?", [id], { (DB.text($0, 0), DB.text($0, 1)) }).first {
            c.notes = r.0; c.link = r.1
        }
        return c
    }

    /// Same due: both none, or both date-only on one day, or both timed within the same minute.
    static func sameDue(_ a: Date?, _ aTime: Bool, _ b: Date?, _ bTime: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            if aTime != bTime { return false }
            return aTime ? Int(x.timeIntervalSince1970 / 60) == Int(y.timeIntervalSince1970 / 60) : Due.dayString(x) == Due.dayString(y)
        default: return false
        }
    }

    private func lastBoardChange(_ cardID: Int64, _ kind: String) throws -> Date? {
        try db.query("SELECT max(at) FROM events WHERE card_id=? AND kind LIKE ? AND actor<>?",
                     [cardID, kind, TaskEventRules.actor.stored]) { DB.date($0, 0) }.first ?? nil
    }

    /// The first sync of a task linked by version 10: records both sides, changes neither, and says once when they differ.
    private func takeBaseline(_ card: Card, _ ev: CalEvent, now: Date) throws {
        let differ = (!ev.title.isEmpty && ev.title != card.title) || !Store.sameDue(card.due, card.dueHasTime, ev.start, !ev.allDay)
        try performThrowing {
            try db.run("UPDATE cards SET gcal_baseline=?, gcal_synced_at=? WHERE id=?",
                       [differ ? CalendarBaseline(card: card, event: ev, now: now).json : "", now, card.id])
        }
        if differ {
            activity("calendar", .info, "\(ShortID(kind: .task, number: card.id).text) and its Google event differ; kept both",
                     detail: "Task: \"\(card.title)\", \(card.due.map { Fmt.due($0, hasTime: card.dueHasTime) } ?? "no due"). "
                        + "Google: \"\(ev.title)\", \(Fmt.due(ev.start, hasTime: !ev.allDay)). A later change on either side wins.")
        }
    }

    /// For a field that differs, given the version-10 record (if any): the side that moved away from it wins; neither moved
    /// keeps both; both moved (or no record) means the newer change wins.
    private func winner(_ base: CalendarBaseline?, boardMoved: (CalendarBaseline) -> Bool, googleMoved: (CalendarBaseline) -> Bool) -> FieldWinner {
        guard let base else { return .newer }
        switch (boardMoved(base), googleMoved(base)) {
        case (false, false): return .neither
        case (true, false): return .board
        case (false, true): return .google
        case (true, true): return .newer
        }
    }

    /// Brings one task and its live event in step. Returns true when something was applied or queued.
    func align(_ card: Card, with ev: CalEvent, link l: LinkedCard, cache: CalendarCache, now: Date) throws -> Bool {
        if l.baseline == CalendarBaseline.pending { try takeBaseline(card, ev, now: now); return false }
        var base = try CalendarBaseline.decode(l.baseline)
        if base != nil, ev.title.isEmpty || ev.title == card.title, Store.sameDue(card.due, card.dueHasTime, ev.start, !ev.allDay) {
            // The two agree again: the record has done its work.
            try performThrowing { try db.run("UPDATE cards SET gcal_baseline='' WHERE id=?", [card.id]) }
            base = nil
        }
        var did = false
        let gT = ev.googleUpdated
        var patchTitle: String?, patchStart: Date?, patchEnd: Date?, patchDay: String?

        // Title.
        let titleWinner = winner(base, boardMoved: { $0.title != card.title }, googleMoved: { $0.googleTitle != ev.title })
        if !ev.title.isEmpty, ev.title != card.title, titleWinner != .neither {
            let boardAt = try lastBoardChange(card.id, "title:%")
            if titleWinner == .google || (titleWinner == .newer && (boardAt == nil || gT > boardAt!)) {
                try performThrowing {
                    let old = try currentCard(card.id)?.card
                    try db.run("UPDATE cards SET title=?, updated=? WHERE id=?", [ev.title, now, card.id])
                    try insertEvent(card.id, "title: " + String(ev.title.prefix(80)), actor: TaskEventRules.actor, at: now)
                    if let old { var new = old; new.title = ev.title; try queueChange(old: old, new: new, now: now) }
                }
                did = true
            } else {
                patchTitle = card.title
            }
        }

        // Time. A task with no due (cleared on the board) takes Google's time only if Google changed it after that and since we last looked.
        let evTimed = !ev.allDay
        let dueWinner = winner(base, boardMoved: { !Store.sameDue($0.dueDate, $0.timed, card.due, card.dueHasTime) },
                               googleMoved: { !Store.sameDue($0.googleStartDate, $0.googleTimed, ev.start, evTimed) })
        if !Store.sameDue(card.due, card.dueHasTime, ev.start, evTimed), dueWinner != .neither {
            let boardAt = try lastBoardChange(card.id, "due:%")
            let googleNewer = dueWinner == .google || (dueWinner == .newer && (boardAt == nil || gT > boardAt!))
            if card.due == nil {
                if dueWinner == .google || (googleNewer && (l.syncedAt == nil || gT > l.syncedAt!)) { try applyGoogleTime(card.id, ev, now: now); did = true }
            } else if googleNewer {
                try applyGoogleTime(card.id, ev, now: now); did = true
            } else if let due = card.due {
                if card.dueHasTime {
                    let length = ev.allDay ? TaskEventRules.eventLength : ev.end.timeIntervalSince(ev.start)
                    patchStart = due; patchEnd = due.addingTimeInterval(length)
                } else {
                    patchDay = Due.dayString(due)
                    patchEnd = allDayEnd(startingOn: Due.dayString(due), keeping: ev)
                }
            }
        }

        // A board change Google already refused for good is not sent again on every pass; a newer board change is tried once more.
        if patchTitle != nil || patchStart != nil || patchDay != nil, let refused = try lastRefusedWrite(l.link) {
            let titleAt = try lastBoardChange(card.id, "title:%"), dueAt = try lastBoardChange(card.id, "due:%")
            if [titleAt, dueAt].compactMap({ $0 }).allSatisfy({ $0 <= refused }) { patchTitle = nil; patchStart = nil; patchEnd = nil; patchDay = nil }
        }
        if patchTitle != nil || patchStart != nil || patchDay != nil {
            CalendarOutbox(store: self).enqueue(.patch(eventID: l.link.event, title: patchTitle, start: patchStart, end: patchEnd, allDayStart: patchDay),
                                                account: l.link.account, calendarID: l.link.calendar, now: now)
            did = true
        }

        // A Meet link Google added to an event we made goes on the task once (as "Add to calendar" with Meet always did).
        if card.link.trimmingCharacters(in: .whitespaces).isEmpty, ev.fbCard == card.id, !ev.videoLink.isEmpty {
            let done = try db.query("SELECT count(*) FROM events WHERE card_id=? AND kind='link: from calendar'", [card.id]) { DB.int($0, 0) }.first ?? 0
            if done == 0 {
                try performThrowing {
                    try db.run("UPDATE cards SET link=?, updated=? WHERE id=?", [ev.videoLink, now, card.id])
                    try insertEvent(card.id, "link: from calendar", actor: TaskEventRules.actor, at: now)
                }
                did = true
            }
        }

        // Keep the link to the event's page and the time we last looked.
        if (!ev.htmlLink.isEmpty && ev.htmlLink != card.gcalLink) || l.syncedAt == nil || gT > l.syncedAt! {
            try performThrowing {
                try db.run("UPDATE cards SET gcal_link=CASE WHEN ?<>'' THEN ? ELSE gcal_link END, gcal_synced_at=? WHERE id=?",
                           [ev.htmlLink, ev.htmlLink, now, card.id])
            }
        }
        return did
    }

    private func applyGoogleTime(_ cardID: Int64, _ ev: CalEvent, now: Date) throws {
        try performThrowing {
            let time: DateComponents? = ev.allDay ? nil : AppTime.calendar.dateComponents([.hour, .minute], from: ev.start)
            try setDueRow(cardID, day: ev.start, time: time, actor: TaskEventRules.actor, now: now, patchCalendar: false)
        }
    }

    /// The event is gone from Google: the task keeps its date, loses its time and its link (D4). Runs inside a transaction.
    func dropEventLink(_ card: Card, now: Date) throws {
        if card.dueHasTime, let due = card.due {
            try setDueRow(card.id, day: due, time: nil, actor: TaskEventRules.actor, now: now, patchCalendar: false)
        }
        try db.run("UPDATE cards SET gcal_account='', gcal_calendar='', gcal_event='', gcal_link='', gcal_synced_at=NULL, updated=? WHERE id=?",
                   [now, card.id])
        try insertEvent(card.id, "event deleted in Google Calendar; kept the date, cleared the time", actor: TaskEventRules.actor, at: now)
    }
}
