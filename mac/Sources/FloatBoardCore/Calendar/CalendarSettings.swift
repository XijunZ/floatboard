import Foundation

/// The logic behind Settings › Calendar, kept apart from the screen so it can be checked.
public enum CalendarSettings {
    /// The account new events go to: the saved one while it is still connected, else the first connected one.
    /// Nothing is written: a saved account that is signed out for a while is remembered and used again when it returns.
    public static func effectiveDefault(saved: String?, connected: [String]) -> String? {
        if let saved, !saved.isEmpty, connected.contains(saved) { return saved }
        return connected.first
    }

    /// True when the account has to sign in again to show its calendars: none are listed (the permission to list them
    /// was never given) or Google refused one of them.
    public static func needsReconnect(account: String, calendars: [CalCalendar]) -> Bool {
        let mine = calendars.filter { $0.account == account }
        return mine.isEmpty || mine.contains { $0.needsReconnect }
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
