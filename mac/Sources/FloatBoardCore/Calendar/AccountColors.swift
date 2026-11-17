import Foundation

/// Each connected Google account has its own colour, so you can see which email an event comes from: the stripe of its
/// events, the legend on the Calendar page, the bar's next meeting and the phone's meeting lines. Colours are given in
/// connection order from a fixed palette (no two accounts share one while colours are left) and kept per account in meta;
/// Settings › Outputs › Calendar changes them.
public enum AccountColors {
    /// Clear, distinct colours, most different first (blue, orange, green ...). Never Google's grey stand-in.
    public static let palette = ["#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#40C8E0", "#AC8E68", "#5E5CE6", "#FFD60A", "#FF453A"]
    /// The colour FloatBoard keeps for a main calendar whose own colour is not known (the list could not be read).
    public static let fallback = "#9aa0a6"

    /// The colour of every account in `accounts`: its saved one, else (in the given order) the first palette colour no
    /// other account has; when all are taken, round again by position.
    public static func assign(accounts: [String], saved: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for a in accounts { if let s = saved[a] { out[a] = s } }
        var used = Set(saved.values.map { $0.uppercased() })
        for (i, a) in accounts.enumerated() where out[a] == nil {
            let pick = palette.first { !used.contains($0.uppercased()) } ?? palette[i % palette.count]
            out[a] = pick
            used.insert(pick.uppercased())
        }
        return out
    }

    /// The colours an event is drawn with.
    public struct EventColors: Equatable {
        /// The account's colour: the event's stripe and fill.
        public var stripe: String
        /// The event's calendar's own colour, as a small secondary mark; nil when there is nothing to tell apart.
        public var mark: String?
        public init(stripe: String, mark: String?) { self.stripe = stripe; self.mark = mark }
    }

    /// The account colour as the stripe; the calendar's own colour only as a mark, and only when the account shows several
    /// calendars and that colour is a real one (not the grey stand-in) and differs from the stripe.
    public static func eventColors(accountColor: String, calendar: CalCalendar?, shownCalendarsOfAccount: Int) -> EventColors {
        guard shownCalendarsOfAccount > 1, let c = calendar?.color, c.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
              c.lowercased() != fallback, c.lowercased() != accountColor.lowercased() else { return EventColors(stripe: accountColor, mark: nil) }
        return EventColors(stripe: accountColor, mark: c)
    }

    static func key(_ account: String) -> String { "account_color:" + account.lowercased() }
    static let hiddenKey = "calendar_hidden_accounts"
    static let bannerKey = "calendar_banner_dismissed"
}

extension Store {
    /// The colour of each account (given in connection order); colours not given yet are chosen and saved now.
    public func accountColors(for accounts: [String]) -> [String: String] {
        var saved: [String: String] = [:]
        do {
            for (k, v) in try db.query("SELECT key, value FROM meta WHERE key LIKE 'account_color:%'", [], { (DB.text($0, 0), DB.text($0, 1)) }) {
                saved[String(k.dropFirst("account_color:".count))] = v
            }
        } catch {
            activity("calendar", .error, "Could not read the account colours", detail: "\(error)")
        }
        let byLower = Dictionary(accounts.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var mine: [String: String] = [:]
        for (lower, hex) in saved { if let a = byLower[lower] { mine[a] = hex } }
        // Colours of accounts not in this list still count as taken.
        let others = saved.filter { byLower[$0.key] == nil }
        var combined = mine
        for (k, v) in others { combined["\u{0}" + k] = v }
        let out = AccountColors.assign(accounts: accounts, saved: combined).filter { !$0.key.hasPrefix("\u{0}") }
        for (a, hex) in out where mine[a] == nil { _ = setAccountColor(a, hex) }
        return out
    }

    @discardableResult
    public func setAccountColor(_ account: String, _ hex: String) -> Bool {
        do {
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [AccountColors.key(account), hex])
            return true
        } catch {
            activity("calendar", .error, "Could not save an account's colour", detail: "\(error)")
            return false
        }
    }

    /// Accounts hidden from the Calendar page with the legend.
    public func hiddenCalendarAccounts() -> Set<String> { metaSet(AccountColors.hiddenKey) }
    public func setCalendarAccountHidden(_ account: String, _ hidden: Bool) {
        var s = hiddenCalendarAccounts()
        if hidden { s.insert(account) } else { s.remove(account) }
        saveMetaSet(AccountColors.hiddenKey, s)
    }

    /// Accounts whose "Showing main calendars only" line was closed on the Calendar page (Settings still offers the sign-in).
    public func dismissedCalendarBanners() -> Set<String> { metaSet(AccountColors.bannerKey) }
    public func dismissCalendarBanner(_ account: String) {
        var s = dismissedCalendarBanners(); s.insert(account); saveMetaSet(AccountColors.bannerKey, s)
    }

    private func metaSet(_ key: String) -> Set<String> {
        do {
            guard let v = try db.query("SELECT value FROM meta WHERE key=?", [key], { DB.text($0, 0) }).first, !v.isEmpty else { return [] }
            return Set(v.split(separator: "\n").map(String.init))
        } catch {
            activity("calendar", .error, "Could not read a calendar setting", detail: "\(error)")
            return []
        }
    }

    private func saveMetaSet(_ key: String, _ s: Set<String>) {
        do {
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [key, s.sorted().joined(separator: "\n")])
        } catch {
            activity("calendar", .error, "Could not save a calendar setting", detail: "\(error)")
        }
    }
}

extension CalendarSettings {
    /// The calendars a new event can go to: owned and shown, of accounts not hidden on the Calendar page (a new event in a
    /// hidden account would vanish from the page at once). `allHidden`: there are such calendars, but only in hidden accounts.
    public static func newEventOptions(_ calendars: [CalCalendar], hidden: Set<String>) -> (options: [CalCalendar], allHidden: Bool) {
        let possible = calendars.filter { $0.owned && $0.shown }
        let options = possible.filter { !hidden.contains($0.account) }
        return (options, options.isEmpty && !possible.isEmpty)
    }

    /// Whether an event shows on the Calendar page: not in an account hidden with the legend, unless it is still waiting to
    /// be sent or was refused (so its state, and Discard, stay in reach).
    public static func showsOnPage(account: String, hidden: Set<String>, waiting: Bool) -> Bool {
        waiting || !hidden.contains(account)
    }

    /// The accounts the Calendar page names in its "Showing main calendars only" line: connected, shown with their main
    /// calendar only (the last list read said so, or nothing but the main-calendar stand-in is kept and no list read has
    /// finished yet), and the line not closed for them.
    public static func mainOnlyBanner(connected: [String], calendars: [CalCalendar], outcome: (String) -> ListOutcome?,
                                      dismissed: Set<String>) -> [String] {
        connected.filter { a in
            guard !dismissed.contains(a) else { return false }
            let o = outcome(a)
            if o == .mainOnly { return true }
            let mine = calendars.filter { $0.account == a }
            return o == nil && !mine.isEmpty && mine.allSatisfy { $0.calendarID == CalendarCache.primaryAlias }
        }
    }
}
