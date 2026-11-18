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

    // Review fix 2: the hover details never open during a drag or resize, and do not come back after the drop until the
    // pointer enters the item again.
    var g = HoverGate()
    g.enter(suppressed: false); g.suppress(); g.waited(suppressed: false)
    let duringDrag = g.shown
    g.waited(suppressed: false)   // the drag ended, the pointer still over the item
    let afterDrop = g.shown
    g.leave(); g.enter(suppressed: false); g.waited(suppressed: false)
    let nextEntry = g.shown
    var h = HoverGate(); h.enter(suppressed: false); h.waited(suppressed: false); let open = h.shown; h.suppress()
    check(!duringDrag && !afterDrop && nextEntry && open && !h.shown, "review2_hover_details_close_on_drag_and_stay_closed_until_next_entry")
}
