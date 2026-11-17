import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// CAL-1: each connected Google account has its own colour, used for its events, the legend, the bar and the phone.
@MainActor func calColourChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-calcolour-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let a = "a@example.com", b = "b@example.org", c = "c@example.net"
    let p = AccountColors.palette

    // Assignment: in connection order, each account the next colour no other account has; kept once given.
    check(AccountColors.assign(accounts: [a, b], saved: [:]) == [a: p[0], b: p[1]], "cal1_accounts_get_distinct_colours_in_order")
    check(AccountColors.assign(accounts: [a, b], saved: [b: p[0]]) == [a: p[1], b: p[0]], "cal1_a_saved_colour_is_kept_and_not_reused")
    check(Set(AccountColors.assign(accounts: [a, b, c], saved: [:]).values).count == 3, "cal1_three_accounts_three_colours")
    check(p.count >= 6 && Set(p).count == p.count && !p.contains(AccountColors.fallback), "cal1_palette_is_distinct_and_not_grey")
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("colours.sqlite")))
        let first = store.accountColors(for: [a, b])
        let again = store.accountColors(for: [b, a])   // another order later does not reshuffle
        let changed = store.setAccountColor(b, "#FF453A")
        check(first == [a: p[0], b: p[1]] && again == first && changed && store.accountColors(for: [a, b])[b] == "#FF453A",
              "cal1_account_colours_are_saved_and_changeable")
        // Show/hide an account from the legend.
        store.setCalendarAccountHidden(a, true)
        let hidden = store.hiddenCalendarAccounts()
        store.setCalendarAccountHidden(a, false)
        check(hidden == [a] && store.hiddenCalendarAccounts().isEmpty, "cal1_legend_hides_and_shows_an_account")
        // The banner: dismissed per account, for good (Settings still offers the sign-in).
        store.dismissCalendarBanner(a)
        check(store.dismissedCalendarBanners() == [a], "cal2_banner_dismissal_is_kept_per_account")
    } catch { check(false, "cal1 store: \(error)") }

    // An event's colours: the account's colour as the stripe; the calendar's own colour as a small mark only when the account
    // shows several calendars and that colour says something (not Google's grey stand-in, not the same as the stripe).
    let fam = CalCalendar(account: a, calendarID: "fam", name: "Family", color: "#16a765", owned: false, shown: true)
    let grey = CalCalendar(account: a, calendarID: "primary", name: "Main calendar", color: "#9aa0a6", owned: true, shown: true)
    check(AccountColors.eventColors(accountColor: p[0], calendar: fam, shownCalendarsOfAccount: 2) == .init(stripe: p[0], mark: "#16a765")
          && AccountColors.eventColors(accountColor: p[0], calendar: fam, shownCalendarsOfAccount: 1) == .init(stripe: p[0], mark: nil)
          && AccountColors.eventColors(accountColor: p[0], calendar: grey, shownCalendarsOfAccount: 3) == .init(stripe: p[0], mark: nil),
          "cal1_event_stripe_is_the_account_colour_calendar_colour_only_a_mark")

    // CAL-2 banner: an account shown with its main calendar only (the list permission is missing) gets one line, unless dismissed.
    let main = { (acct: String) in CalCalendar(account: acct, calendarID: CalendarCache.primaryAlias, name: "Main calendar", color: "#9aa0a6", owned: true, shown: true, primary: true) }
    let listed = CalCalendar(account: c, calendarID: c, name: "C", color: "#111111", owned: true, shown: true, primary: true)
    let outcomes: [String: CalendarSettings.ListOutcome] = [a: .mainOnly, c: .listed]
    check(CalendarSettings.mainOnlyBanner(connected: [a, b, c], calendars: [main(a), main(b), listed], outcome: { outcomes[$0] }, dismissed: []) == [a, b]
          && CalendarSettings.mainOnlyBanner(connected: [a, b, c], calendars: [main(a), main(b), listed], outcome: { outcomes[$0] }, dismissed: [b]) == [a],
          "cal2_banner_lists_main_only_accounts_not_dismissed_ones")

    // CAL-2: once the list can be read, every calendar (owned and subscribed) starts shown; a choice made later is kept.
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("list.sqlite")))
        let cache = CalendarCache(store: store)
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.url?.path.hasSuffix("/users/me/calendarList") == true {
                return (##"{"items":[{"id":"a@example.com","summary":"Me","accessRole":"owner","primary":true,"backgroundColor":"#111111"},{"id":"family#x","summary":"Family","accessRole":"reader","backgroundColor":"#16a765"},{"id":"team#y","summary":"Team","accessRole":"writer","backgroundColor":"#4986e7"},{"id":"en.uk#holiday@group.v.calendar.google.com","summary":"Holidays in the UK","accessRole":"reader","backgroundColor":"#16a765"},{"id":"addressbook#contacts@group.v.calendar.google.com","summary":"Birthdays","accessRole":"reader","backgroundColor":"#92e1c0"},{"id":"e_2_en#weeknum@group.v.calendar.google.com","summary":"Week Numbers","accessRole":"reader","backgroundColor":"#9fc6e7"}]}"##, 200)
            }
            return (#"{"items":[],"nextSyncToken":"T"}"#, 200)
        }
        await CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [a] }).refreshCalendars()
        let mine = cache.calendars().filter { $0.account == a }
        let on = Set(mine.filter(\.shown).map(\.name))
        if on != ["Me", "Family", "Team"] { print("  cal2 shown: \(mine.map { "\($0.name)=\($0.shown)" })") }
        check(mine.count == 6 && on == ["Me", "Family", "Team"], "cal2_all_listed_calendars_start_shown_except_google_generated_ones")
        _ = cache.setShown(account: a, calendarID: "team#y", false)
        await CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [a] }).refreshCalendars()
        check(cache.calendars().first { $0.calendarID == "team#y" }?.shown == false, "cal2_a_calendar_switched_off_stays_off")

        // The phone gets the account's colour with each meeting (not the calendar's).
        cache.upsertCalendars(account: a, [CalCalendar(account: a, calendarID: "a@example.com", name: "Me", color: "#111111", owned: true, shown: true, primary: true)])
        let start = AppTime.calendar.date(byAdding: .hour, value: 2, to: Date())!
        cache.apply(account: a, calendarID: "a@example.com", changes: [GoogleEventChange(eventID: "f1", cancelled: false,
            fields: CalEventFields(start: start, end: start.addingTimeInterval(1800), title: "School run", googleUpdated: Date()))], nextToken: nil)
        let colour = store.accountColors(for: [a])[a]
        let sent = PhoneBoard.events(store: store, now: Date()).first { $0.title == "School run" }?.color
        if sent != colour { print("  cal1 phone colour: \(sent ?? "nil") (want \(colour ?? "nil"))") }
        check(sent != nil && sent == colour, "cal1_phone_meeting_carries_the_account_colour")
    } catch { check(false, "cal2 list: \(error)") }
}
