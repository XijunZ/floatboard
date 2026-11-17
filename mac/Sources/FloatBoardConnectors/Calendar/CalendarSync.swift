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

    /// One scheduled pass: every account's calendar list when it is new or 6 hours old, else the list of any account whose
    /// last read did not succeed (it failed, was refused, or the account was just connected again); then the events.
    public func tick() async {
        guard !running else { return }
        if lastListed.map({ now().timeIntervalSince($0) >= Self.listInterval }) ?? true {
            await refreshCalendars()
        } else {
            let unlisted = accounts().filter { ![.listed, .mainOnly].contains(CalendarListAttempts.outcome($0)) }
            if !unlisted.isEmpty { await refreshCalendars(only: unlisted) }
        }
        await syncOnce()
    }

    /// Reads each connected account's calendar list. New owned calendars and each account's main one start shown; others hidden
    /// (the user chooses in Settings). A known calendar keeps its choice.
    public func refreshCalendars() async {
        lastListed = now()
        await refreshCalendars(only: accounts())
    }

    private func refreshCalendars(only list: [String]) async {
        for account in list {
            let key = "list:" + account
            do {
                let found = try await apiFor(account).listCalendars()
                cache.upsertCalendars(account: account, found.map {
                    CalCalendar(account: account, calendarID: $0.id, name: $0.name, color: $0.color, owned: $0.owned, shown: $0.owned || $0.primary,
                                primary: $0.primary)
                })
                lastProblem[key] = nil
                CalendarListAttempts.record(account, .listed)
            } catch GoogleCalendarError.missingCalendarListAccess {
                // An older sign-in (events only): Google accepts "primary" for the account's main calendar (its real id is usually,
                // not always, the address), so show that one under it; the list, once it can be read, gives the real id and the
                // cache moves everything there. Asked again after the normal list interval or a new sign-in, not every pass.
                if !cache.calendars().contains(where: { $0.account == account }) {
                    cache.upsertCalendars(account: account, [CalCalendar(account: account, calendarID: CalendarCache.primaryAlias, name: "Main calendar",
                                                                          color: "#9aa0a6", owned: true, shown: true, primary: true)])
                }
                lastProblem[key] = nil
                CalendarListAttempts.record(account, .mainOnly)
            } catch GoogleCalendarError.notConnected {
                CalendarListAttempts.record(account, .needsReconnect)
                flagReconnect(account: account, calendarID: nil)
            } catch GoogleCalendarError.needsReconnect(let body) {
                CalendarListAttempts.record(account, .needsReconnect)
                flagReconnect(account: account, calendarID: nil)
                problem(key, "Google Calendar sign-in for \(account) needs to be renewed", body)
            } catch {
                CalendarListAttempts.record(account, .failed)
                problem(key, "Could not read the calendar list for \(account)", "\(error)")
            }
        }
    }

    /// Reads every shown calendar of a connected account, then reconciles tasks with their events. A removed account's
    /// calendars are not read (and count as unread, so nothing is concluded from them). A second call while one runs does nothing.
    public func syncOnce() async {
        guard !running else { return }
        running = true
        defer { running = false }
        var unread = Set<String>()
        let connected = Set(accounts())
        for c in cache.calendars() where c.shown {
            guard connected.contains(c.account) else { unread.insert(TaskEventRules.key(c.account, c.calendarID)); continue }
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
            var result: (changes: [GoogleEventChange], nextToken: String, skipped: [String])
            var full = c.syncToken == nil
            let dailyDue = c.fullReadAt.map { now().timeIntervalSince($0) >= Self.fullReadInterval } ?? true
            do {
                if let token = c.syncToken, dailyDue {
                    // The daily full read replaces the bookmark, so first take in what changed anywhere (also outside the window)
                    // since the last pass; the full read then only has to find events that were beyond the window before.
                    let inc = try await api.listEvents(calendarID: c.calendarID, syncToken: token, timeMin: from, timeMax: to)
                    reportSkipped(c, inc.skipped)
                    guard cache.apply(account: c.account, calendarID: c.calendarID, changes: inc.changes, nextToken: inc.nextToken, now: now()) else { return false }
                    full = true
                }
                result = try await api.listEvents(calendarID: c.calendarID, syncToken: full ? nil : c.syncToken, timeMin: from, timeMax: to)
            } catch GoogleCalendarError.syncExpired {
                full = true
                // The bookmark is too old: forget it (events are hidden until the full read brings them back) and read it all again.
                guard cache.resetSync(account: c.account, calendarID: c.calendarID) else { return false }
                result = try await api.listEvents(calendarID: c.calendarID, syncToken: nil, timeMin: from, timeMax: to)
            }
            reportSkipped(c, result.skipped)
            if cache.apply(account: c.account, calendarID: c.calendarID, changes: result.changes, nextToken: result.nextToken, fullRead: full, now: now()) {
                if c.needsReconnect { cache.setNeedsReconnect(account: c.account, calendarID: c.calendarID, false) }
                lastProblem[key] = nil
                await readSeries(c, api: api, refresh: full)
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

    /// Reads the rule of each repeating meeting of the calendar not read yet (at most 50 a pass), and at the daily full read
    /// (`refresh`) every one read before this pass again, for the phone's short labels ("weekdays 09:00"). A series Google has
    /// no rule for, or refuses for good, is kept with none ("repeats") until the next daily read; a passing failure is tried
    /// at the next pass. Problems are written to Activity once.
    private func readSeries(_ c: CalCalendar, api: GoogleCalendarAPI, refresh: Bool) async {
        let started = now()
        let key = "series:" + c.account + "|" + c.calendarID
        for id in cache.seriesToRead(account: c.account, calendarID: c.calendarID, readBefore: refresh ? started : nil) {
            do {
                let lines = try await api.recurrence(calendarID: c.calendarID, seriesID: id)
                cache.saveSeries(account: c.account, calendarID: c.calendarID, seriesID: id, rule: lines.joined(separator: "\n"), now: started)
            } catch where CalendarSender.isPermanent(error) {
                cache.saveSeries(account: c.account, calendarID: c.calendarID, seriesID: id, rule: "", now: started)
            } catch {
                problem(key, "Could not read how a meeting of \"\(c.name)\" (\(c.account)) repeats; will try again", "\(error)")
                return
            }
        }
    }

    /// Marks one calendar, or every calendar of the account, as needing the user to sign in again. Quiet: being signed out is a state, not an error.
    private func flagReconnect(account: String, calendarID: String?) {
        for c in cache.calendars() where c.account == account && (calendarID == nil || c.calendarID == calendarID) && !c.needsReconnect {
            cache.setNeedsReconnect(account: account, calendarID: c.calendarID, true)
        }
    }

    /// Events Google sent that could not be read were left out (the rest of the calendar still came in): say which, once.
    private func reportSkipped(_ c: CalCalendar, _ skipped: [String]) {
        guard !skipped.isEmpty else { return }
        problem("skipped:" + c.account + "|" + c.calendarID,
                "Left out \(skipped.count) event(s) of calendar \"\(c.name)\" (\(c.account)) that could not be read", skipped.joined(separator: "\n"))
    }

    private func problem(_ key: String, _ message: String, _ detail: String) {
        guard lastProblem[key] != detail else { return }
        lastProblem[key] = detail
        store.activity("calendar", .warning, message, detail: detail)
    }
}
