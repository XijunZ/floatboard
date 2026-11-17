import FloatBoardCore
import Foundation

/// Once a minute: shows the budget reminders that are due on this Mac (and leaves late ones to the phone), and gives the
/// Sunday weekly-review nudge once a week.
@MainActor final class AssistantTicker {
    private let store: Store
    private let ui: UIState
    private let show: (DueReminder) -> Void
    private let pushBoard: () -> Void
    private let delivery: ReminderDelivery
    private var timer: Timer?
    static let nudgedKey = "weekly_review_nudged"

    /// `showNow` hands a budget reminder to macOS and throws when it was refused; `claim` asks the engine whether this Mac
    /// may show it (one id, shown once across Mac and phone).
    init(store: Store, ui: UIState, show: @escaping (DueReminder) -> Void, showNow: @escaping (DueReminder) async throws -> Void,
         claim: @escaping (String) async -> ReminderClaim, pushBoard: @escaping () -> Void) {
        self.store = store; self.ui = ui; self.show = show; self.pushBoard = pushBoard
        delivery = ReminderDelivery(store: store, claim: claim, schedule: showNow)
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    func tick(now: Date = Date()) {
        // Budget reminders: delivered only once macOS took them (ReminderDelivery); the phone's copy then drops them.
        Task { @MainActor [delivery, pushBoard] in if await delivery.tick(now: now) { pushBoard() } }
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
