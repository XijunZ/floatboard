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

    // Reconnect: no calendars listed for the account, or any of its calendars needs it.
    let all = [cal(a, a, "Me"), cal(a, "x", "Team", owned: false, reconnect: true), cal(b, b, "Other")]
    check(CalendarSettings.needsReconnect(account: a, calendars: all), "settings: one calendar needing reconnect flags the account")
    check(!CalendarSettings.needsReconnect(account: b, calendars: all), "settings: a healthy account is not flagged")
    check(CalendarSettings.needsReconnect(account: "c@example.com", calendars: all), "settings: an account with no calendars listed is flagged")

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
    try? FileManager.default.removeItem(at: dir) // try?-ok: scratch folder cleanup; a leftover temp folder is harmless
}
