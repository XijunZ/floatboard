import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// The phone's planning summary (C7, changed 17 Nov): the events sent cover today through the end of next week, a recurring
/// meeting carries its series and a short label made from the series' rule, read once per series and kept.
@MainActor func planningChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-planning-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let cal = AppTime.calendar
    let acct = "me@example.com", cid = "main-id"
    func on(_ day: Date, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }

    // The rule in words.
    let nine = on(cal.startOfDay(for: Date()), 9)
    let tue = cal.nextDate(after: Date(), matching: DateComponents(hour: 14, minute: 0, weekday: 3), matchingPolicy: .nextTime)!
    let labels: [(String, Date, Bool, String)] = [
        ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", nine, false, "weekdays 09:00"),
        ("RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR", nine, false, "weekdays 09:00"),
        ("RRULE:FREQ=WEEKLY", tue, false, "weekly Tue 14:00"),
        ("RRULE:FREQ=WEEKLY;BYDAY=TU", tue, false, "weekly Tue 14:00"),
        ("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", nine, false, "every 2 weeks Mon, Wed 09:00"),
        ("RRULE:FREQ=DAILY", nine, false, "daily 09:00"),
        ("RRULE:FREQ=DAILY;INTERVAL=3;COUNT=10", nine, false, "every 3 days 09:00"),
        ("RRULE:FREQ=MONTHLY;BYDAY=1TH", nine, false, "monthly"),
        ("RRULE:FREQ=MONTHLY;INTERVAL=3", nine, false, "every 3 months"),
        ("RRULE:FREQ=YEARLY", nine, true, "yearly"),
        ("RRULE:FREQ=WEEKLY;BYDAY=FR", cal.startOfDay(for: tue), true, "weekly Fri"),
        ("EXDATE;TZID=Europe/London:20261120T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;UNTIL=20270101T000000Z", nine, false, "weekdays 09:00"),
        ("RRULE:FREQ=HOURLY", nine, false, "repeats"),
        ("RRULE:FREQ=WEEKLY;INTERVAL=x", nine, false, "repeats"),
        ("RDATE:20261120", nine, false, "repeats"),
        ("", nine, false, "repeats"),
    ]
    var labelsOK = true
    for (rule, start, allDay, want) in labels {
        let got = RecurrenceLabel.text(rule: rule, start: start, allDay: allDay)
        if got != want { labelsOK = false; print("  label for \(rule.debugDescription): \(got) (want \(want))") }
    }
    check(labelsOK, "recurrence_rule_in_short_english")

    // The sync reads each series' rule once and keeps it; the daily full read reads it again.
    do {
        let store = Store(db: try DB(url: root.appendingPathComponent("series.sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cid, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
        let day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        func inst(_ n: Int) -> String {
            let s = cal.date(byAdding: .day, value: n, to: on(day, 9))!
            return #"{"id":"ser1_\#(n)","status":"confirmed","summary":"Standup","recurringEventId":"ser1","start":{"dateTime":"\#(GoogleTimes.rfc(s))"},"end":{"dateTime":"\#(GoogleTimes.rfc(s.addingTimeInterval(900)))"},"updated":"2026-11-16T10:00:00Z"}"#
        }
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.url?.path.hasSuffix("/events/ser1") == true {
                return (#"{"recurrence":["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]}"#, 200)
            }
            return (#"{"items":[\#(inst(0)),\#(inst(1)),\#(inst(2))],"nextSyncToken":"T"}"#, 200)
        }
        func ruleReads() -> [URLRequest] { fake.requests.filter { $0.url?.path.hasSuffix("/events/ser1") == true } }
        let sync = CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [acct] })
        await sync.syncOnce()
        await sync.syncOnce()
        let once = ruleReads().count == 1 && ruleReads().first?.url?.query?.contains("fields=recurrence") == true
        check(once && cache.seriesRule(account: acct, calendarID: cid, seriesID: "ser1") == "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
              "series_rule_read_once_and_kept")
        store.performForTest("UPDATE cal_calendars SET full_read_at=0, sync_token='T'")   // the daily full read is due
        await sync.syncOnce()
        check(ruleReads().count == 2, "series_rule_read_again_at_the_daily_full_read")

        // The phone copy: today through the end of next week; each instance carries its series and label.
        let now = on(cal.startOfDay(for: Date()), 8)
        let weekday = cal.component(.weekday, from: now)              // 1 = Sunday
        let monday = cal.date(byAdding: .day, value: -((weekday + 5) % 7), to: cal.startOfDay(for: now))!
        let lastDay = cal.date(byAdding: .day, value: 13, to: monday)!  // Sunday of next week
        let after = cal.date(byAdding: .day, value: 14, to: monday)!    // the Monday after
        cache.apply(account: acct, calendarID: cid, changes: [
            GoogleEventChange(eventID: "last", cancelled: false, fields: CalEventFields(start: on(lastDay, 18), end: on(lastDay, 19), title: "Sunday dinner", googleUpdated: now)),
            GoogleEventChange(eventID: "beyond", cancelled: false, fields: CalEventFields(start: on(after, 9), end: on(after, 10), title: "Too far", googleUpdated: now)),
        ], nextToken: nil)
        let events = PhoneBoard.events(store: store, now: now)
        let standups = events.filter { $0.title == "Standup" }
        check(events.contains { $0.title == "Sunday dinner" } && !events.contains { $0.title == "Too far" } && PhoneBoard.maxEvents >= 150
              && PhoneBoard.maxEvents <= 300, "phone_events_cover_today_through_end_of_next_week")
        check(standups.count == 3 && Set(standups.compactMap(\.series)).count == 1 && standups.allSatisfy { $0.repeatLabel == "weekdays 09:00" }
              && events.first { $0.title == "Sunday dinner" }?.series == nil, "phone_events_carry_series_and_label")
        let body = try JSONSerialization.jsonObject(with: try PhoneBoard.body([], events: standups)) as? [String: Any]
        let first = (body?["events"] as? [[String: Any]])?.first
        check(first?["repeat"] as? String == "weekdays 09:00" && (first?["series"] as? String)?.hasPrefix("S-") == true, "phone_body_sends_series_and_repeat")
    } catch { check(false, "planning sync: \(error)") }
}
