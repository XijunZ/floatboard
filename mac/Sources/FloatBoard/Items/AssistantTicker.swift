import FloatBoardCore
import Foundation

/// Once a minute: shows the budget reminders that are due on this Mac (and leaves late ones to the phone), and gives the
/// Sunday weekly-review nudge once a week.
@MainActor final class AssistantTicker {
    private let store: Store
    private let ui: UIState
    private let show: (DueReminder) -> Void
    private let pushBoard: () -> Void
    private var timer: Timer?
    static let nudgedKey = "weekly_review_nudged"

    init(store: Store, ui: UIState, show: @escaping (DueReminder) -> Void, pushBoard: @escaping () -> Void) {
        self.store = store; self.ui = ui; self.show = show; self.pushBoard = pushBoard
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    func tick(now: Date = Date()) {
        let budget = ReminderBudget(store: store)
        var changed = false
        for r in budget.pending() {
            if ReminderBudget.macShows(r, now: now) {
                let title = ShortID.parse(r.item).flatMap { store.item($0)?.title } ?? "FloatBoard"
                show(DueReminder(id: r.id, cardID: 0, title: title, body: r.text, fireAt: now.addingTimeInterval(1)))
                budget.markDelivered(r.id, by: "mac", at: now)
                changed = true
            } else if ReminderBudget.phoneTakesOver(r, now: now) {
                budget.markDelivered(r.id, by: "phone", at: now)
                changed = true
            }
        }
        if changed { pushBoard() }   // the phone's copy drops what this Mac has shown
        ResolutionsNudger.tick(store: store, now: now, show: show)   // quarter and year reviews: outside the budget
        let last = UserDefaults.standard.object(forKey: Self.nudgedKey) as? Date
        if WeeklyReview.nudgeDue(now: now, lastNudged: last) {
            UserDefaults.standard.set(now, forKey: Self.nudgedKey)
            WeeklyReview.fireNudge()
            if !WeeklyReview.sections(store: store, now: now).isEmpty {
                show(DueReminder(id: "weekly-review-\(Int(now.timeIntervalSince1970))", cardID: 0, title: "Weekly review",
                                 body: "Your week is ready to review.", fireAt: now.addingTimeInterval(1)))
            }
        }
    }
}
