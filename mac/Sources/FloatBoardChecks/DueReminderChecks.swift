import Foundation
import FloatBoardCore

/// A scheduler that only records what it was asked to do.
@MainActor final class FakeScheduler: ReminderScheduler {
    var pending: [String: DueReminder] = [:]
    var scheduled: [DueReminder] = []
    var cancelled: [String] = []
    func schedule(_ r: DueReminder) { pending[r.id] = r; scheduled.append(r) }
    func cancel(_ ids: [String]) { for id in ids { pending[id] = nil }; cancelled += ids }
}

/// Due reminders on this Mac: timed tasks 15 minutes before, date-only ones at 09:00 that day; rescheduled when the
/// board changes, removed when a task is done, deleted or loses its due; once per task and due value; a setting.
@MainActor func dueReminderChecks() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    func card(_ id: Int64, due: Date?, status: Status = .todo, title: String = "Task") -> Card {
        Card(id: id, title: title, notes: "", area: "Work", importance: .medium, due: due, status: status, created: at(2026, 11, 1),
             started: nil, done: nil)
    }
    let now = at(2026, 11, 12, 8, 0)

    // The plan.
    let plan = DueReminders.plan([card(1, due: at(2026, 11, 12, 14, 30), title: "Call the bank"), card(2, due: at(2026, 11, 13)),
                                  card(3, due: at(2026, 11, 12, 15), status: .done), card(4, due: nil),
                                  card(5, due: at(2026, 11, 12, 7, 0)), card(6, due: at(2026, 11, 12, 16), status: .watch)],
                                 now: now, calendar: cal)
    let timed = plan.first { $0.cardID == 1 }
    let dayOnly = plan.first { $0.cardID == 2 }
    check(timed?.fireAt == at(2026, 11, 12, 14, 15) && timed?.title == "Call the bank" && timed?.body == "Due 14:30",
          "due_reminder_timed_15_minutes_before")
    check(dayOnly?.fireAt == at(2026, 11, 13, 9, 0) && dayOnly?.body == "Due today", "due_reminder_date_only_at_9")
    check(!plan.contains { [3, 4, 5].contains($0.cardID) } && plan.contains { $0.cardID == 6 },
          "due_reminder_only_open_tasks_with_a_due_still_ahead")
    // Late: a timed task due in 10 minutes reminds now; a date-only task today after 09:00 reminds now.
    let late = DueReminders.plan([card(7, due: at(2026, 11, 12, 10, 10)), card(8, due: at(2026, 11, 12))], now: at(2026, 11, 12, 10, 0), calendar: cal)
    check(late.count == 2 && late.allSatisfy { $0.fireAt > at(2026, 11, 12, 10, 0) && $0.fireAt <= at(2026, 11, 12, 10, 0).addingTimeInterval(5) },
          "due_reminder_late_ones_fire_now")

    // Scheduling with a fake scheduler.
    let fake = FakeScheduler()
    var kept: [String] = []   // what the app keeps in UserDefaults, kept here so the checks write no preferences
    let sync = ReminderSync(scheduler: fake, load: { kept }, save: { kept = $0 })
    var board = [card(1, due: at(2026, 11, 12, 14, 30)), card(2, due: at(2026, 11, 13))]
    sync.sync(cards: board, enabled: true, now: now, calendar: cal)
    check(Set(fake.pending.values.map(\.cardID)) == [1, 2] && fake.scheduled.count == 2, "due_reminder_scheduled_for_each_open_task")
    sync.sync(cards: board, enabled: true, now: now.addingTimeInterval(60), calendar: cal)
    check(fake.scheduled.count == 2 && fake.cancelled.isEmpty, "due_reminder_unchanged_board_schedules_nothing_again")
    // Done: removed. New due: the old one removed, a new one scheduled.
    board[0].status = .done
    board[1].due = at(2026, 11, 14)
    sync.sync(cards: board, enabled: true, now: now.addingTimeInterval(120), calendar: cal)
    check(fake.pending.count == 1 && fake.pending.values.first?.fireAt == at(2026, 11, 14, 9, 0) && fake.cancelled.count == 2,
          "due_reminder_done_task_cancelled_and_new_due_rescheduled")
    // Deleted (gone from the board): removed.
    sync.sync(cards: [], enabled: true, now: now.addingTimeInterval(180), calendar: cal)
    check(fake.pending.isEmpty, "due_reminder_deleted_task_cancelled")
    // Once only, also across a restart: a late reminder already handed over is not shown again.
    let lateBoard = [card(9, due: at(2026, 11, 12))]
    sync.sync(cards: lateBoard, enabled: true, now: at(2026, 11, 12, 10), calendar: cal)
    let restarted = ReminderSync(scheduler: fake, load: { kept }, save: { kept = $0 })
    restarted.sync(cards: lateBoard, enabled: true, now: at(2026, 11, 12, 11), calendar: cal)
    check(fake.scheduled.filter { $0.cardID == 9 }.count == 1, "due_reminder_once_only_across_restart")
    // Turned off: everything removed; back on: scheduled again.
    restarted.sync(cards: board, enabled: false, now: now, calendar: cal)
    check(fake.pending.isEmpty, "due_reminder_setting_off_removes_all")
    restarted.sync(cards: [card(1, due: at(2026, 11, 12, 14, 30))], enabled: true, now: now, calendar: cal)
    check(fake.pending.count == 1, "due_reminder_setting_on_schedules_again")
    // At most 60 waiting at once (macOS keeps 64 per app), soonest first.
    let many = (1...80).map { card(Int64(100 + $0), due: at(2026, 11, 20).addingTimeInterval(Double($0) * 3600 + 60)) }
    check(DueReminders.plan(many, now: now, calendar: cal).count == 60, "due_reminder_at_most_60_pending")
    check(DueReminders.enabled(stored: nil) && !DueReminders.enabled(stored: false), "due_reminder_setting_default_on")
}
