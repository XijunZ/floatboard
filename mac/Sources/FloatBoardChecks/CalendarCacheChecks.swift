import Foundation
import FloatBoardCore

/// The calendar cache: Google calendars and events kept on the board, with stable E-n ids.
@MainActor func calendarCacheChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-calcache-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup

    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "calendar cache setup: \(error)"); return }
    let cache = CalendarCache(store: store)
    let acct = "me@example.com", cal = "primary", other = "team"
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func fields(_ title: String, at hours: Double, length: Double = 1, fbCard: Int64? = nil, updated: Double = 0) -> CalEventFields {
        CalEventFields(start: base.addingTimeInterval(hours * 3600), end: base.addingTimeInterval((hours + length) * 3600),
                       title: title, googleUpdated: base.addingTimeInterval(updated), fbCard: fbCard)
    }
    func change(_ id: String, _ f: CalEventFields) -> GoogleEventChange { GoogleEventChange(eventID: id, cancelled: false, fields: f) }
    func cancel(_ id: String) -> GoogleEventChange { GoogleEventChange(eventID: id, cancelled: true, fields: nil) }

    cache.upsertCalendars(account: acct, [
        CalCalendar(account: acct, calendarID: cal, name: "Me", color: "#112233", owned: true, shown: true),
        CalCalendar(account: acct, calendarID: other, name: "Team", color: "#445566", owned: false, shown: true)])

    cache.apply(account: acct, calendarID: cal, changes: [change("a", fields("Standup", at: 1)), change("b", fields("Review", at: 5)),
                                                         change("c", fields("Late", at: 30))], nextToken: "tok1")
    let day = base...base.addingTimeInterval(24 * 3600)
    let inRange = cache.events(from: day.lowerBound, to: day.upperBound)
    check(inRange.map(\.title) == ["Standup", "Review"] && inRange[0].eventID == "a" && inRange[0].account == acct
          && inRange[0].start == base.addingTimeInterval(3600) && inRange[0].id.text == "E-\(inRange[0].shortID)"
          && cache.events(from: base.addingTimeInterval(1.5 * 3600), to: base.addingTimeInterval(1.6 * 3600)).map(\.title) == ["Standup"]
          && cache.events(from: base.addingTimeInterval(2 * 3600), to: base.addingTimeInterval(5 * 3600)).isEmpty
          && cache.calendars().first { $0.calendarID == cal }?.syncToken == "tok1",
          "cache_upsert_and_range_query")

    let aID = inRange[0].shortID
    cache.apply(account: acct, calendarID: cal, changes: [cancel("a")], nextToken: "tok2")
    let kept = cache.event(shortID: aID)
    check(cache.events(from: day.lowerBound, to: day.upperBound).map(\.title) == ["Review"]
          && kept?.eventID == "a" && cache.event(account: acct, calendarID: cal, eventID: "a")?.shortID == aID
          && cache.calendars().first { $0.calendarID == cal }?.syncToken == "tok2",
          "cache_cancelled_marks_gone_keeps_short_id")

    let reviewID = inRange[1].shortID
    var moved = fields("Review (moved)", at: 6, updated: 60)
    moved.location = "Room 2"; moved.recurringID = "series"
    cache.apply(account: acct, calendarID: cal, changes: [change("b", moved)], nextToken: nil)
    let after = cache.event(shortID: reviewID)
    check(after?.title == "Review (moved)" && after?.location == "Room 2" && after?.recurringID == "series"
          && after?.start == base.addingTimeInterval(6 * 3600) && cache.event(account: acct, calendarID: cal, eventID: "b")?.shortID == reviewID
          && cache.calendars().first { $0.calendarID == cal }?.syncToken == "tok2",
          "cache_short_id_stable_across_updates")

    cache.resetSync(account: acct, calendarID: cal)
    check(cache.events(from: day.lowerBound, to: day.upperBound).isEmpty
          && cache.calendars().first { $0.calendarID == cal }?.syncToken == nil, "cache_reset_clears_token_and_hides_events")
    cache.apply(account: acct, calendarID: cal, changes: [change("b", fields("Review again", at: 5))], nextToken: "tok3")
    cache.apply(account: acct, calendarID: cal, changes: [change("a", fields("Standup", at: 1))], nextToken: "tok3")
    let again = cache.events(from: day.lowerBound, to: day.upperBound)
    check(again.map(\.shortID) == [aID, reviewID] && again.map(\.title) == ["Standup", "Review again"],
          "cache_reset_then_refill_reuses_short_id")

    cache.apply(account: acct, calendarID: other, changes: [change("t1", fields("Team sync", at: 3))], nextToken: "x")
    check(cache.events(from: day.lowerBound, to: day.upperBound).map(\.title) == ["Standup", "Team sync", "Review again"], "cache_second_calendar_included")
    cache.setShown(account: acct, calendarID: other, false)
    check(cache.events(from: day.lowerBound, to: day.upperBound).map(\.title) == ["Standup", "Review again"]
          && cache.nextMeeting(after: base.addingTimeInterval(2 * 3600))?.title == "Review again"
          && cache.event(account: acct, calendarID: other, eventID: "t1") != nil, "cache_hidden_calendar_not_returned")
    cache.setShown(account: acct, calendarID: other, true)
    cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: other, name: "Team renamed", color: "#000000", owned: false, shown: false)])
    check(cache.calendars().first { $0.calendarID == other }.map { $0.name == "Team renamed" && $0.shown && $0.syncToken == "x" } == true,
          "cache_calendar_refresh_keeps_choices_and_token")

    // All-day events: days are stored; start and end come from them in the app's zone.
    let saved = AppTime.setting
    defer { AppTime.apply(saved) }
    AppTime.apply("Europe/London")
    let allDay = CalEventFields(start: base, end: base, allDay: true, startDay: "2026-07-01", endDay: "2026-07-03",
                                title: "Offsite", googleUpdated: base)
    cache.apply(account: acct, calendarID: cal, changes: [change("d", allDay)], nextToken: nil)
    var c = AppTime.calendar
    let want = (c.date(from: DateComponents(year: 2026, month: 7, day: 1))!, c.date(from: DateComponents(year: 2026, month: 7, day: 3))!)
    let got = cache.event(account: acct, calendarID: cal, eventID: "d")
    check(got?.allDay == true && got?.start == want.0 && got?.end == want.1, "cache_all_day_start_end_from_days_in_app_zone")
    AppTime.apply("Asia/Shanghai")
    c = AppTime.calendar
    check(cache.event(account: acct, calendarID: cal, eventID: "d")?.start == c.date(from: DateComponents(year: 2026, month: 7, day: 1)),
          "cache_all_day_follows_time_zone_change")
    AppTime.apply("Europe/London")

    // next meeting: skips all-day events and events made from tasks
    cache.apply(account: acct, calendarID: other, changes: [
        change("m1", fields("Task block", at: 40, fbCard: 7)),
        change("m2", fields("Real meeting", at: 41)),
        change("m3", CalEventFields(start: base.addingTimeInterval(39 * 3600), end: base.addingTimeInterval(63 * 3600), allDay: true,
                                    startDay: "2027-01-01", endDay: "2027-01-02", title: "Holiday", googleUpdated: base))], nextToken: nil)
    check(cache.nextMeeting(after: base.addingTimeInterval(35 * 3600))?.title == "Real meeting"
          && cache.nextMeeting(after: base.addingTimeInterval(100 * 3600)) == nil, "next_meeting_skips_all_day_and_task_events")

    // "Real meeting" runs 41-42h; at 41.5h it is in progress and still the next one, at 42h it is over
    check(cache.nextMeeting(after: base.addingTimeInterval(41.5 * 3600))?.title == "Real meeting"
          && cache.nextMeeting(after: base.addingTimeInterval(42 * 3600)) == nil, "next_meeting_includes_in_progress")

    // The bar's next meeting: shown from 60 minutes before the start until the end; Join only with a video link.
    func meeting(_ title: String, start: Double, end: Double, link: String = "") -> CalEvent {
        CalEvent(shortID: 1, account: acct, calendarID: cal, eventID: "bm", start: base.addingTimeInterval(start * 3600),
                 end: base.addingTimeInterval(end * 3600), allDay: false, title: title, location: "", videoLink: link,
                 description: "", htmlLink: "", recurringID: nil, googleUpdated: base, fbCard: nil)
    }
    let bm = meeting("Sync", start: 10, end: 11)
    check(BarMeeting.visible(next: bm, now: base.addingTimeInterval(8.99 * 3600)) == nil
          && BarMeeting.visible(next: bm, now: base.addingTimeInterval(9 * 3600))?.title == "Sync"
          && BarMeeting.visible(next: bm, now: base.addingTimeInterval(10.5 * 3600))?.title == "Sync"
          && BarMeeting.visible(next: nil, now: base) == nil, "bar_meeting_appears_60_min_before")
    check(BarMeeting.visible(next: bm, now: base.addingTimeInterval(10.99 * 3600)) != nil
          && BarMeeting.visible(next: bm, now: base.addingTimeInterval(11 * 3600)) == nil
          && BarMeeting.visible(next: bm, now: base.addingTimeInterval(12 * 3600)) == nil, "bar_meeting_hides_after_end")
    check(BarMeeting.joinURL(meeting("A", start: 1, end: 2, link: "https://meet.example.com/abc"))?.absoluteString == "https://meet.example.com/abc"
          && BarMeeting.joinURL(meeting("A", start: 1, end: 2)) == nil
          && BarMeeting.joinURL(meeting("A", start: 1, end: 2, link: "  ")) == nil
          && BarMeeting.joinURL(meeting("A", start: 1, end: 2, link: "javascript:alert(1)")) == nil
          && BarMeeting.label(bm) == "\(Fmt.clock(bm.start)) Sync", "bar_meeting_join_only_with_video_link")

    // a write that fails is reported to Activity, not swallowed
    try? store.db.run("DROP TABLE cal_events") // try?-ok: the drop is the test setup; the check below fails if it did not happen
    let ok = cache.apply(account: acct, calendarID: cal, changes: [change("z", fields("Z", at: 2))], nextToken: "never")
    check(!ok && store.recentActivity(limit: 5).contains { $0.level == .error && $0.component == "calendar" }, "cache_write_failure_goes_to_activity")
}
