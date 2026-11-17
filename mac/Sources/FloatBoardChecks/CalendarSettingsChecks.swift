import Foundation
import FloatBoardCore

/// Settings › Calendar logic: which account is the effective default, which accounts need to reconnect, the order of an account's calendars.
@MainActor func calendarSettingsChecks() {
    let a = "a@example.com", b = "b@example.com"
    func cal(_ acct: String, _ id: String, _ name: String, owned: Bool = true, reconnect: Bool = false) -> CalCalendar {
        CalCalendar(account: acct, calendarID: id, name: name, color: "#112233", owned: owned, shown: owned, needsReconnect: reconnect)
    }
    // Effective default: the saved account while connected; otherwise the first connected one (the saved value is not touched).
    check(CalendarSettings.effectiveDefault(saved: b, connected: [a, b]) == b, "settings: saved default account wins")
    check(CalendarSettings.effectiveDefault(saved: "gone@example.com", connected: [a, b]) == a, "settings: a disconnected saved default falls back to the first connected")
    check(CalendarSettings.effectiveDefault(saved: nil, connected: [b, a]) == b, "settings: no saved default uses the first connected")
    check(CalendarSettings.effectiveDefault(saved: "", connected: [a]) == a, "settings: an empty saved default counts as none")
    check(CalendarSettings.effectiveDefault(saved: a, connected: []) == nil, "settings: no accounts, no default")

    // What an account shows: loading until its first list attempt ends; reconnect only on a real refusal or a flagged calendar.
    let all = [cal(a, a, "Me"), cal(a, "x", "Team", owned: false, reconnect: true), cal(b, b, "Other")]
    func st(_ acct: String, _ cals: [CalCalendar], _ last: CalendarSettings.ListOutcome?) -> CalendarSettings.AccountState {
        CalendarSettings.state(account: acct, calendars: cals, lastList: last)
    }
    let c = "c@example.com"
    check(st(c, all, nil) == .loading, "settings: a fresh account with no list attempt yet is loading, not reconnect")
    check(st(c, all, .failed) == .loading, "settings: a failed attempt that is not a refusal stays quiet (loading)")
    check(st(c, all, .needsReconnect) == .reconnect, "settings: a list refused for permission asks to reconnect")
    check(st(c, all, .listed) == .calendars, "settings: a successful list with nothing in it shows calendars (empty)")
    check(st(b, all, nil) == .calendars, "settings: saved calendars show right away")
    check(st(a, all, .listed) == .reconnect, "settings: one calendar flagged needs-reconnect flags the account")
    check(st(b, all, .needsReconnect) == .reconnect, "settings: a refused list flags an account that has calendars")
    // The attempt memory: recorded, replaced, forgotten after a fresh sign-in.
    CalendarListAttempts.record(c, .needsReconnect)
    check(CalendarListAttempts.outcome(c) == .needsReconnect, "settings: list attempt is remembered")
    CalendarListAttempts.forget(c)
    check(CalendarListAttempts.outcome(c) == nil, "settings: a fresh sign-in forgets the old attempt")

    // An account's calendars: owned first, then by name.
    let mixed = [cal(a, "z", "Zed", owned: false), cal(a, "m", "Mine"), cal(a, "h", "Holidays", owned: false), cal(b, "o", "Other")]
    check(CalendarSettings.calendars(of: a, in: mixed).map(\.calendarID) == ["m", "h", "z"], "settings: owned calendars first, then by name; other accounts left out")

    // Saving the default account in meta; a later read returns it, even when that account is not connected any more.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-calsettings-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(db: try DB(url: dir.appendingPathComponent("s.sqlite")))
        check(store.savedDefaultCalendarAccount() == nil, "settings: no default saved at first")
        check(store.setDefaultCalendarAccount(b), "settings: saving the default account works")
        check(store.savedDefaultCalendarAccount() == b, "settings: the saved default is read back")
        check(CalendarSettings.effectiveDefault(saved: store.savedDefaultCalendarAccount(), connected: [a]) == a
              && store.savedDefaultCalendarAccount() == b, "settings: falling back never overwrites the saved value")
    } catch {
        check(false, "settings: could not set up a scratch board: \(error)")
    }
    // A removed account's events leave the calendar and the bar; its saved shown choices come back with it.
    do {
        let store = Store(db: try DB(url: dir.appendingPathComponent("r.sqlite")))
        let cache = CalendarCache(store: store)
        let t0 = Date().addingTimeInterval(3600)
        func ev(_ id: String) -> GoogleEventChange {
            GoogleEventChange(eventID: id, cancelled: false, fields: CalEventFields(start: t0, end: t0.addingTimeInterval(1800), title: id, googleUpdated: Date()))
        }
        cache.upsertCalendars(account: a, [CalCalendar(account: a, calendarID: a, name: "A", color: "#111111", owned: true, shown: true)])
        cache.upsertCalendars(account: b, [CalCalendar(account: b, calendarID: b, name: "B", color: "#222222", owned: true, shown: true),
                                           CalCalendar(account: b, calendarID: "x", name: "X", color: "#333333", owned: false, shown: false)])
        cache.apply(account: a, calendarID: a, changes: [ev("from-a")], nextToken: nil)
        cache.apply(account: b, calendarID: b, changes: [ev("from-b")], nextToken: nil)
        let win = (t0.addingTimeInterval(-60), t0.addingTimeInterval(7200))
        var connected: [String] = [a, b]
        CalendarCache.connectedAccounts = { connected }
        defer { CalendarCache.connectedAccounts = nil }
        check(Set(cache.events(from: win.0, to: win.1).map(\.title)) == ["from-a", "from-b"], "settings: both accounts' events show while connected")
        connected = [a]
        check(cache.events(from: win.0, to: win.1).map(\.title) == ["from-a"], "settings: a removed account's events are hidden")
        check(cache.nextMeeting(after: t0.addingTimeInterval(-3600))?.title == "from-a", "settings: the bar's next meeting skips a removed account")
        check(cache.connectedCalendars().map(\.account) == [a], "settings: a removed account's calendars are not offered")
        check(cache.calendars().contains { $0.account == b }, "settings: a removed account's calendars stay saved")
        connected = []
        check(cache.events(from: win.0, to: win.1).isEmpty && cache.nextMeeting(after: t0.addingTimeInterval(-3600)) == nil, "settings: with no accounts nothing shows")
        connected = [a, b]
        let back = cache.connectedCalendars().filter { $0.account == b }.map { "\($0.calendarID)=\($0.shown)" }.sorted()
        check(back == ["x=false", "\(b)=true"].sorted() && cache.events(from: win.0, to: win.1).count == 2,
              "settings: a re-added account returns with its saved shown choices and events")
    } catch {
        check(false, "settings: could not set up the removed-account board: \(error)")
    }
    try? FileManager.default.removeItem(at: dir) // try?-ok: scratch folder cleanup; a leftover temp folder is harmless
}
