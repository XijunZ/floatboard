import FloatBoardCore
import Foundation

/// Sends the changes waiting in the calendar outbox to Google, one at a time, oldest first. A failure keeps the change
/// (it is tried again later with a growing wait) and is written to Activity with Google's reply.
/// Nothing starts this on its own yet: whoever wires it up calls `drain()`.
@MainActor
public final class CalendarSender {
    private let store: Store
    private let outbox: CalendarOutbox
    private let cache: CalendarCache
    private let apiFor: (String) -> GoogleCalendarAPI
    private let isConnected: (String) -> Bool
    private var draining = false
    /// Accounts whose sign-in is gone: their changes are left alone (quietly) until the account is connected again.
    private var parked: Set<String> = []

    /// `apiFor` gives the Google client for an account; `isConnected` says whether the account still has a saved sign-in.
    public init(store: Store, apiFor: @escaping (String) -> GoogleCalendarAPI, isConnected: @escaping (String) -> Bool = { _ in true }) {
        self.store = store
        self.outbox = CalendarOutbox(store: store)
        self.cache = CalendarCache(store: store)
        self.apiFor = apiFor
        self.isConnected = isConnected
    }

    /// Sends everything that is due now. A second call while one is running does nothing.
    public func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        for account in parked where isConnected(account) {
            parked.remove(account)
            setReconnect(account, false)
            store.activity("calendar", .info, "\(account) is connected again; its waiting calendar changes will now be sent")
        }
        for row in outbox.due(now: Date()) where !parked.contains(row.account) {
            await send(row)
        }
    }

    private func setReconnect(_ account: String, _ needs: Bool) {
        for c in cache.calendars() where c.account == account { cache.setNeedsReconnect(account: account, calendarID: c.calendarID, needs) }
    }

    private func send(_ row: CalOutboxRow) async {
        guard let write = row.write else {
            // Cannot be read, so it can never succeed: keep it and wait the longest.
            outbox.markFailed(uuid: row.uuid, error: row.lastError)
            store.activity("calendar", .error, "A queued calendar change can't be read", detail: row.lastError, trace: row.uuid)
            return
        }
        let api = apiFor(row.account)
        outbox.setInFlight(row.uuid, true)   // while on the wire, undo can't take it back
        defer { outbox.setInFlight(row.uuid, false) }
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
            case .patch(let eventID, let title, let start, let end, let allDayStart):
                saved = outbox.markSent(uuid: row.uuid, result: try await api.patch(calendarID: row.calendarID, eventID: eventID, title: title,
                                                                                    start: start, end: end, allDayStart: allDayStart))
            case .delete(let eventID):
                try await api.delete(calendarID: row.calendarID, eventID: eventID)
                saved = outbox.markSent(uuid: row.uuid, result: nil)
            }
            if !saved {
                // Google has it but the board could not note that; wait and try again (safe: creates use a fixed id).
                outbox.markFailed(uuid: row.uuid, error: "Sent to Google, but the board could not save that")
            }
        } catch GoogleCalendarError.notConnected(let account) {
            parked.insert(account)
            setReconnect(account, true)
            store.activity("calendar", .warning, "\(account) is not connected any more; its calendar changes wait until it is connected again",
                           trace: row.uuid)
        } catch {
            if case GoogleCalendarError.needsReconnect = error { cache.setNeedsReconnect(account: row.account, calendarID: row.calendarID, true) }
            outbox.markFailed(uuid: row.uuid, error: "\(error)")
            store.activity("calendar", .warning, "Could not send a calendar change to Google (\(row.account)); will retry",
                           detail: "\(error)", trace: row.uuid)
        }
    }
}
