import FloatBoardCore
import Foundation

/// Sends the changes waiting in the calendar outbox to Google, one at a time, oldest first, each event's changes in order. A passing failure (Google busy,
/// the network) keeps the change, tried again later with a growing wait, and is written to Activity once per change and reason.
/// An answer that can never turn into success (the event is gone, the calendar is read-only for you, a bad request) ends the
/// change for good: it is kept with Google's reply, never sent again, and written to Activity as an error. Nothing is sent
/// while the Mac is offline. The app's calendar scheduler calls `drain()`.
@MainActor
public final class CalendarSender {
    private let store: Store
    private let outbox: CalendarOutbox
    private let cache: CalendarCache
    private let apiFor: (String) -> GoogleCalendarAPI
    private let isConnected: (String) -> Bool
    private let isOnline: @MainActor () -> Bool
    private var draining = false
    /// The passing failure last written to Activity per change, so a repeating one is written once.
    private var warned: [String: String] = [:]
    /// Accounts whose sign-in is gone: their changes are left alone (quietly) until the account is connected again.
    private var parked: Set<String> = []

    /// `apiFor` gives the Google client for an account; `isConnected` says whether the account still has a saved sign-in;
    /// `isOnline` whether the Mac has a network (the app's network monitor, as the health watchdog uses).
    public init(store: Store, apiFor: @escaping (String) -> GoogleCalendarAPI, isConnected: @escaping (String) -> Bool = { _ in true },
                isOnline: @escaping @MainActor () -> Bool = { Health.isOnline }) {
        self.store = store
        self.outbox = CalendarOutbox(store: store)
        self.cache = CalendarCache(store: store)
        self.apiFor = apiFor
        self.isConnected = isConnected
        self.isOnline = isOnline
    }

    /// Sends everything that is due now. A second call while one is running does nothing; offline it does nothing (the
    /// changes wait without counting failures).
    public func drain() async {
        guard !draining, isOnline() else { return }
        draining = true
        defer { draining = false }
        for account in parked where isConnected(account) {
            parked.remove(account)
            setReconnect(account, false)
            store.activity("calendar", .info, "\(account) is connected again; its waiting calendar changes will now be sent")
        }
        // One change at a time, each read again and marked as on its way just before it goes (never from a list made before
        // an earlier send's wait: Undo may have taken a delete back meanwhile). A change that was waiting behind an earlier one
        // for its event can go as soon as that one is sent. Each change is tried once per run.
        var tried = Set<String>()
        while let row = outbox.claimNext(now: Date(), skip: { tried.contains($0.uuid) || parked.contains($0.account) }) {
            tried.insert(row.uuid)
            await send(row)
        }
    }

    private func setReconnect(_ account: String, _ needs: Bool) {
        for c in cache.calendars() where c.account == account { cache.setNeedsReconnect(account: account, calendarID: c.calendarID, needs) }
    }

    /// `row` was claimed (marked as on its way); the mark is cleared when this returns.
    private func send(_ row: CalOutboxRow) async {
        defer { outbox.setInFlight(row.uuid, false) }
        guard let write = row.write else {
            // Cannot be read, so it can never succeed: keep it (for the record) and never send it.
            outbox.markDead(uuid: row.uuid, error: row.lastError)
            store.activity("calendar", .error, "A queued calendar change can't be read; it will not be sent", detail: row.lastError, trace: row.uuid)
            return
        }
        let api = apiFor(row.account)
        do {
            let saved: Bool
            switch write {
            case .create(let fields, let cardID, let addMeet):
                let id = CalendarOutbox.googleEventID(forUUID: row.uuid)
                let made: (eventID: String, fields: CalEventFields)
                do {
                    made = try await api.insert(calendarID: row.calendarID, fields, cardID: cardID, addMeet: addMeet, eventID: id)
                } catch GoogleCalendarError.http(let status, _) where status == 409 {
                    // An earlier attempt got through but its answer was lost: the event is already there under this id.
                    made = try await api.get(calendarID: row.calendarID, eventID: id)
                }
                saved = outbox.markSent(uuid: row.uuid, result: made)
            case .patch(let eventID, _, _, _, _):
                // Read the event first: a field Google changed after this change was queued keeps Google's newer value (C4), and
                // the rest is sent only if the event is still as read (If-Match; 412 otherwise, see below).
                let read = try await api.getForUpdate(calendarID: row.calendarID, eventID: eventID)
                let base = row.base ?? cache.event(account: row.account, calendarID: row.calendarID, eventID: eventID).map(CalPatchBase.init)
                // What Google has now is noted first (a field whose value changed there, with Google's stamp now), so a later
                // write of other fields cannot make that change look newer than it was.
                // A retry after a lost answer: values Google has that this row already sent are FloatBoard's own write.
                let own = CalendarOutbox.claimingOwnRetry(
                    CalendarOutbox.observed(outbox.ownWrite(account: row.account, calendarID: row.calendarID, eventID: eventID),
                                            base: base, current: read.fields),
                    attempted: row.attempted, current: read.fields)
                outbox.saveKnown(account: row.account, calendarID: row.calendarID, eventID: eventID, own)
                let toSend = CalendarOutbox.withoutNewerGoogleFields(write, queuedAt: row.created, base: base, own: own, current: read.fields)
                if toSend != write {
                    store.activity("calendar", .info, "Google had a newer change to an event (\(row.account)); kept it instead of the older one from the board",
                                   detail: "\"\(read.fields.title)\"", trace: row.uuid)
                }
                guard case .patch(_, let title, let start, let end, let allDayStart)? = toSend else {
                    saved = outbox.markSent(uuid: row.uuid, result: (read.eventID, read.fields), own: false)   // nothing left to send
                    break
                }
                // Noted on the row before the request goes, so a lost answer is recognised as this row's own write.
                guard outbox.markAttempted(uuid: row.uuid, toSend!) else {
                    outbox.markFailed(uuid: row.uuid, error: "Could not note the change as being sent")
                    return
                }
                saved = outbox.markSent(uuid: row.uuid, result: try await api.patch(calendarID: row.calendarID, eventID: eventID, title: title,
                                                                                    start: start, end: end, allDayStart: allDayStart, ifMatch: read.etag),
                                        wrote: toSend)
            case .delete(let eventID):
                try await api.delete(calendarID: row.calendarID, eventID: eventID)
                saved = outbox.markSent(uuid: row.uuid, result: nil)
            }
            if !saved {
                // Google has it but the board could not note that; wait and try again (safe: creates use a fixed id).
                outbox.markFailed(uuid: row.uuid, error: "Sent to Google, but the board could not save that")
            } else {
                warned[row.uuid] = nil
            }
        } catch GoogleCalendarError.notConnected(let account) {
            parked.insert(account)
            setReconnect(account, true)
            store.activity("calendar", .warning, "\(account) is not connected any more; its calendar changes wait until it is connected again",
                           trace: row.uuid)
        } catch GoogleCalendarError.http(let status, _) where status == 412 {
            // The event changed in Google between the read and the change: the next run reads it again and decides again.
            // Once is quiet; repeated ones wait longer each time, and the third in a row is written to Activity once.
            if outbox.markConflict(uuid: row.uuid) >= 3, warned[row.uuid] != "conflict" {
                warned[row.uuid] = "conflict"
                store.activity("calendar", .warning, "An event kept changing in Google while FloatBoard tried to send a change to it (\(row.account)); will retry",
                               detail: Self.describe(write), trace: row.uuid)
            }
        } catch where Self.isPermanent(error) {
            outbox.markDead(uuid: row.uuid, error: "\(error)")
            warned[row.uuid] = nil
            store.activity("calendar", .error, "Google refused to \(Self.describe(write)) (\(row.account)); it will not be tried again",
                           detail: "\(error)", trace: row.uuid)
        } catch {
            if case GoogleCalendarError.needsReconnect = error { cache.setNeedsReconnect(account: row.account, calendarID: row.calendarID, true) }
            outbox.markFailed(uuid: row.uuid, error: "\(error)")
            let text = "\(error)"
            if warned[row.uuid] != text {
                warned[row.uuid] = text
                store.activity("calendar", .warning, "Could not send a calendar change to Google (\(row.account)); will retry",
                               detail: text, trace: row.uuid)
            }
        }
    }

    /// Google's answers that no retry can change: a bad request (400), no right to change this calendar or event (403, other
    /// than a rate limit; a missing sign-in permission is `.needsReconnect`, not this), and an event that is not there (404/410
    /// on a change; a delete of a missing event already counts as done).
    static func isPermanent(_ error: Error) -> Bool {
        guard case GoogleCalendarError.http(let status, let body) = error else { return false }
        switch status {
        case 400, 404, 410: return true
        case 403: return !["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "dailyLimitExceeded"].contains { body.contains($0) }
        default: return false
        }
    }

    /// The change in words for Activity: "add \"Lunch\" to the calendar".
    private static func describe(_ w: CalWrite) -> String {
        switch w {
        case .create(let f, let cardID, _):
            return "add \"\(f.title)\" to the calendar" + (cardID == nil ? " (discard it on the calendar)" : " (the task stays; Add to calendar can try again)")
        case .patch: return "change an event"
        case .delete: return "delete an event"
        }
    }
}
