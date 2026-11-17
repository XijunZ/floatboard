import Foundation

/// The logic behind Settings › Calendar, kept apart from the screen so it can be checked.
public enum CalendarSettings {
    /// The account new events go to: the saved one while it is still connected, else the first connected one.
    /// Nothing is written: a saved account that is signed out for a while is remembered and used again when it returns.
    public static func effectiveDefault(saved: String?, connected: [String]) -> String? {
        if let saved, !saved.isEmpty, connected.contains(saved) { return saved }
        return connected.first
    }

    /// What the last attempt to read an account's calendar list found.
    public enum ListOutcome: Equatable { case listed, needsReconnect, failed
        /// The sign-in cannot list calendars (it predates that permission): only the account's main calendar is shown.
        case mainOnly
    }

    /// What Settings shows for one account.
    public enum AccountState: Equatable {
        /// The first calendar list has not come back yet: say so quietly.
        case loading
        /// Google refused the list (permission missing) or one of the account's calendars: ask to sign in again.
        case reconnect
        /// Only the main calendar is available until the account signs in again for the full list: say so calmly, offer it.
        case mainOnly
        /// Show the account's calendars with their switches.
        case calendars
    }

    /// Decides what to show for an account. A new account is "loading" until its first list attempt has finished, and only an
    /// attempt that really reported a missing sign-in or permission (or a calendar flagged by the sync) asks to reconnect.
    public static func state(account: String, calendars: [CalCalendar], lastList: ListOutcome?) -> AccountState {
        let mine = calendars.filter { $0.account == account }
        if mine.contains(where: \.needsReconnect) || lastList == .needsReconnect { return .reconnect }
        if lastList == .mainOnly { return .mainOnly }
        if !mine.isEmpty || lastList == .listed { return .calendars }
        return .loading
    }

    /// One account's calendars, the ones the user owns first, then by name.
    public static func calendars(of account: String, in all: [CalCalendar]) -> [CalCalendar] {
        all.filter { $0.account == account }.sorted {
            if $0.owned != $1.owned { return $0.owned }
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.calendarID < $1.calendarID : c == .orderedAscending
        }
    }
}

extension Store {
    /// The account chosen in Settings › Calendar for new events (may no longer be connected); nil when none was chosen.
    public func savedDefaultCalendarAccount() -> String? {
        do {
            let v = try db.query("SELECT value FROM meta WHERE key=?", [TaskEventRules.defaultAccountKey]) { DB.text($0, 0) }.first
            return v?.isEmpty == false ? v : nil
        } catch {
            activity("calendar", .error, "Could not read the default calendar account", detail: "\(error)")
            return nil
        }
    }

    /// Where a new event goes, the one rule for tasks (drag, Add to calendar) and the New event sheet: `account` when given,
    /// else the default account from Settings while it is connected, else the first connected one (never a removed account);
    /// on it, its main calendar (Google names it with the account's address), else its first owned one. With `among` (the
    /// sheet's choices) only those calendars count and nil means none fits; without it an account whose calendars are not
    /// read yet still gets its main calendar by address. Nil when no account is connected.
    public func newEventCalendar(account: String? = nil, among: [CalCalendar]? = nil) -> (account: String, calendarID: String)? {
        let cache = CalendarCache(store: self)
        let cals = among ?? cache.connectedCalendars()
        var chosen = account
        if chosen == nil {
            var connected = cache.connectedAccountList()
            if let among { connected = connected.filter { a in among.contains { $0.account == a } } }
            chosen = CalendarSettings.effectiveDefault(saved: savedDefaultCalendarAccount(), connected: connected)
        }
        guard let acct = chosen else { return nil }
        let mine = cals.filter { $0.account == acct }
        let main = mine.first { $0.calendarID.lowercased() == acct.lowercased() } ?? mine.first { $0.owned }
        if among != nil {
            guard let pick = main ?? mine.first else { return nil }
            return (acct, pick.calendarID)
        }
        return (acct, main?.calendarID ?? acct)
    }

    @discardableResult
    public func setDefaultCalendarAccount(_ account: String) -> Bool {
        do {
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [TaskEventRules.defaultAccountKey, account])
            return true
        } catch {
            activity("calendar", .error, "Could not save the default calendar account", detail: "\(error)")
            return false
        }
    }
}

/// Remembers, while the app runs, how the last calendar-list read went for each account. Kept in memory: the list is read
/// again at every start, and calendars already saved still show meanwhile.
@MainActor
public enum CalendarListAttempts {
    private static var outcomes: [String: CalendarSettings.ListOutcome] = [:]
    public static func outcome(_ account: String) -> CalendarSettings.ListOutcome? { outcomes[account] }
    public static func record(_ account: String, _ outcome: CalendarSettings.ListOutcome) { outcomes[account] = outcome }
    /// After a fresh sign-in: the next list read decides again.
    public static func forget(_ account: String) { outcomes[account] = nil }
}
