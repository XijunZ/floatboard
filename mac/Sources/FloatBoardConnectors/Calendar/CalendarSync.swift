import FloatBoardCore
import Foundation

/// Reads Google's changes into the calendar cache, then lets the task <-> event rules react. One pass (`syncOnce`) goes
/// through every shown calendar: with the saved bookmark if there is one, else the whole window (30 days back, 90 ahead).
/// Google saying the bookmark is too old (410) means: forget it and read the whole window again. A refused sign-in flags the
/// calendar "needs reconnect" (cleared by the next good read). Problems go to Activity once, not on every pass.
/// Whoever owns the timer calls `tick()`; this class has no timer of its own.
@MainActor
public final class CalendarSync {
    private let store: Store
    private let cache: CalendarCache
    private let apiFor: (String) -> GoogleCalendarAPI
    private let accounts: () -> [String]
    private let now: () -> Date
    private var running = false
    private var lastListed: Date?
    /// The last problem logged per calendar, so a repeating one is written once.
    private var lastProblem: [String: String] = [:]

    /// How often the list of calendars is read again.
    public static let listInterval: TimeInterval = 6 * 3600
    /// How often the whole window is read again. Google's "changes since last time" never returns an event that has not
    /// changed, so one that was beyond the window at the last full read (or hidden by a reset) would otherwise never come in.
    /// The full read's own bookmark replaces the saved one, so the other passes stay incremental.
    public static let fullReadInterval: TimeInterval = 24 * 3600

    /// `apiFor` gives the Google client for an account; `accounts` lists the accounts that are connected.
    public init(store: Store, apiFor: @escaping (String) -> GoogleCalendarAPI, accounts: @escaping () -> [String],
                now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.cache = CalendarCache(store: store)
        self.apiFor = apiFor
        self.accounts = accounts
        self.now = now
    }

    /// One scheduled pass: the calendar list when it is new or 6 hours old, then the events.
    public func tick() async {
        guard !running else { return }
        if lastListed.map({ now().timeIntervalSince($0) >= Self.listInterval }) ?? true { await refreshCalendars() }
        await syncOnce()
    }

    /// Reads each connected account's calendar list. New owned calendars and each account's main one start shown; others hidden
    /// (the user chooses in Settings). A known calendar keeps its choice.
    public func refreshCalendars() async {
        lastListed = now()
        for account in accounts() {
            let key = "list:" + account
            do {
                let found = try await apiFor(account).listCalendars()
                cache.upsertCalendars(account: account, found.map {
                    CalCalendar(account: account, calendarID: $0.id, name: $0.name, color: $0.color, owned: $0.owned, shown: $0.owned || $0.primary)
                })
                lastProblem[key] = nil
            } catch GoogleCalendarError.notConnected {
                flagReconnect(account: account, calendarID: nil)
            } catch GoogleCalendarError.needsReconnect(let body) {
                flagReconnect(account: account, calendarID: nil)
                problem(key, "Google Calendar sign-in for \(account) needs to be renewed", body)
            } catch {
                problem(key, "Could not read the calendar list for \(account)", "\(error)")
            }
        }
    }

    /// Reads every shown calendar, then reconciles tasks with their events. A second call while one runs does nothing.
    public func syncOnce() async {
        guard !running else { return }
        running = true
        defer { running = false }
        var unread = Set<String>()
        for c in cache.calendars() where c.shown {
            if !(await sync(c)) { unread.insert(TaskEventRules.key(c.account, c.calendarID)) }
        }
        TaskEventRules.reconcile(store: store, cache: cache, now: now(), unreadCalendars: unread)
    }

    /// Returns false when the calendar could not be read this time.
    private func sync(_ c: CalCalendar) async -> Bool {
        let key = c.account + "|" + c.calendarID
        let api = apiFor(c.account)
        let from = now().addingTimeInterval(-TaskEventRules.windowBack), to = now().addingTimeInterval(TaskEventRules.windowAhead)
        do {
            var result: (changes: [GoogleEventChange], nextToken: String)
            var full = c.syncToken == nil || (c.fullReadAt.map { now().timeIntervalSince($0) >= Self.fullReadInterval } ?? true)
            do {
                result = try await api.listEvents(calendarID: c.calendarID, syncToken: full ? nil : c.syncToken, timeMin: from, timeMax: to)
            } catch GoogleCalendarError.syncExpired {
                full = true
                // The bookmark is too old: forget it (events are hidden until the full read brings them back) and read it all again.
                guard cache.resetSync(account: c.account, calendarID: c.calendarID) else { return false }
                result = try await api.listEvents(calendarID: c.calendarID, syncToken: nil, timeMin: from, timeMax: to)
            }
            if cache.apply(account: c.account, calendarID: c.calendarID, changes: result.changes, nextToken: result.nextToken, fullRead: full, now: now()) {
                if c.needsReconnect { cache.setNeedsReconnect(account: c.account, calendarID: c.calendarID, false) }
                lastProblem[key] = nil
                return true
            }
            return false
        } catch GoogleCalendarError.notConnected {
            flagReconnect(account: c.account, calendarID: c.calendarID)
            return false
        } catch GoogleCalendarError.needsReconnect(let body) {
            if !c.needsReconnect { cache.setNeedsReconnect(account: c.account, calendarID: c.calendarID, true) }
            problem(key, "Google Calendar sign-in for \(c.account) needs to be renewed (\(c.name))", body)
            return false
        } catch {
            problem(key, "Could not read calendar \"\(c.name)\" (\(c.account)) from Google; will try again", "\(error)")
            return false
        }
    }

    /// Marks one calendar, or every calendar of the account, as needing the user to sign in again. Quiet: being signed out is a state, not an error.
    private func flagReconnect(account: String, calendarID: String?) {
        for c in cache.calendars() where c.account == account && (calendarID == nil || c.calendarID == calendarID) && !c.needsReconnect {
            cache.setNeedsReconnect(account: account, calendarID: c.calendarID, true)
        }
    }

    private func problem(_ key: String, _ message: String, _ detail: String) {
        guard lastProblem[key] != detail else { return }
        lastProblem[key] = detail
        store.activity("calendar", .warning, message, detail: detail)
    }
}
