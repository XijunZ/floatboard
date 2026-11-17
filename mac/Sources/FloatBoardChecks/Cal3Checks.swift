import Foundation
import FloatBoardCore

/// CAL-3: calendar items show as much of their title as fits, the all-day row stacks up to three, and a click on a task
/// opens the board's task editor (events keep their event panel).
@MainActor func cal3Checks() {
    // How a timed block uses its height: title lines first, then the time, then the id.
    let short = CalendarLayout.blockText(height: 22)          // a 30-minute block
    let hour = CalendarLayout.blockText(height: 46)           // a 1-hour block
    let long = CalendarLayout.blockText(height: 138)          // 3 hours
    let tiny = CalendarLayout.blockText(height: 11.5)         // 15 minutes
    check(tiny.titleLines == 1 && !tiny.showTime && short.titleLines >= 1 && !short.showTime,
          "cal3_short_blocks_drop_the_time_line_first")
    check(hour.titleLines >= 2 && hour.titleLines <= 3 && hour.showTime, "cal3_a_one_hour_block_shows_two_or_three_title_lines_and_its_time")
    check(long.titleLines > hour.titleLines && long.showTime && long.showID, "cal3_tall_blocks_wrap_further_and_show_the_id")

    // The all-day row: up to three items a day; more shows two and "+N more".
    check(CalendarLayout.stripSplit(count: 2) == (2, 0) && CalendarLayout.stripSplit(count: 3) == (3, 0)
          && CalendarLayout.stripSplit(count: 5) == (2, 3), "cal3_all_day_row_stacks_three_then_plus_more")

    // A click: a task opens the board's editor, an event its panel.
    let e = CalEvent(shortID: 7, account: "a@example.com", calendarID: "c", eventID: "x", start: Date(), end: Date().addingTimeInterval(3600),
                     allDay: false, title: "Call", location: "", videoLink: "", description: "", htmlLink: "", recurringID: nil,
                     googleUpdated: Date(), fbCard: nil)
    let t = Card(id: 42, title: "Write the long plan", notes: "", area: "Work", importance: .medium, due: Date(), status: .todo, created: Date(), started: nil, done: nil)
    check(CalendarLayout.clickTarget(.task(t)) == .taskEditor(42) && CalendarLayout.clickTarget(.event(e)) == .eventPanel(7),
          "cal3_click_on_a_task_opens_the_task_editor_events_their_panel")
}
