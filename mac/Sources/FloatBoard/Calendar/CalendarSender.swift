import FloatBoardConnectors
import FloatBoardCore
import Foundation

/// Sends the changes waiting in the calendar outbox to Google, one at a time, oldest first. A failure keeps the change
/// (it is tried again later with a growing wait) and is written to Activity with Google's reply.
/// Nothing starts this on its own yet: whoever wires it up calls `drain()`.
@MainActor
final class CalendarSender {
    private let store: Store
    private let outbox: CalendarOutbox
    private let cache: CalendarCache
    private let apiFor: (String) -> GoogleCalendarAPI
    private var draining = false

    init(store: Store, google: Google) {
        self.store = store
        self.outbox = CalendarOutbox(store: store)
        self.cache = CalendarCache(store: store)
        self.apiFor = { google.calendarAPI(for: $0) }
    }

    /// Sends everything that is due now. A second call while one is running does nothing.
    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        for row in outbox.due(now: Date()) {
            await send(row)
        }
    }

    private func send(_ row: CalOutboxRow) async {
        guard let write = row.write else {
            // Cannot be read, so it can never succeed: keep it (it stays visible in Activity) and wait the longest.
            outbox.markFailed(uuid: row.uuid, error: row.lastError)
            store.activity("calendar", .error, "A queued calendar change can't be read", detail: row.lastError, trace: row.uuid)
            return
        }
        let api = apiFor(row.account)
        do {
            switch write {
            case .create(let fields, let cardID, let addMeet):
                outbox.markSent(uuid: row.uuid, result: try await api.insert(calendarID: row.calendarID, fields, cardID: cardID, addMeet: addMeet))
            case .patch(let eventID, let title, let start, let end, let allDayStart):
                outbox.markSent(uuid: row.uuid, result: try await api.patch(calendarID: row.calendarID, eventID: eventID, title: title,
                                                                            start: start, end: end, allDayStart: allDayStart))
            case .delete(let eventID):
                try await api.delete(calendarID: row.calendarID, eventID: eventID)
                outbox.markSent(uuid: row.uuid, result: nil)
            }
        } catch {
            if case GoogleCalendarError.needsReconnect = error {
                cache.setNeedsReconnect(account: row.account, calendarID: row.calendarID, true)
            }
            outbox.markFailed(uuid: row.uuid, error: "\(error)")
            store.activity("calendar", .warning, "Could not send a calendar change to Google (\(row.account)); will retry",
                           detail: "\(error)", trace: row.uuid)
        }
    }
}
