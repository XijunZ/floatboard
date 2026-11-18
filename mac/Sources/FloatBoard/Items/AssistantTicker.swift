import FloatBoardConnectors
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
         claim: @escaping (String) async -> ReminderClaim, release: @escaping (String) async -> Bool, pushBoard: @escaping () -> Void) {
        self.store = store; self.ui = ui; self.show = show; self.pushBoard = pushBoard
        // A late reminder goes to the phone only when an engine says it can reach one (a paired phone with notifications,
        // or ntfy); otherwise (no engine, no subscribed phone, never heard from) this Mac shows it late.
        delivery = ReminderDelivery(store: store, claim: claim, schedule: showNow, release: release, phoneAvailable: { PhoneReach.any() })
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    func tick(now: Date = Date()) {
        // Budget reminders: delivered only once macOS took them (ReminderDelivery); the phone's copy then drops them.
        Task { @MainActor [store, delivery, pushBoard] in
            // Whether a phone can be reached is asked first (at most every 10 minutes per engine), so the late branch decides on it.
            for info in store.connectors where !info.baseURL.isEmpty && info.id != LocalMode.connectorID {
                if let client = ConnectorAccounts.client(for: info, store: store) { await PhoneReach.refresh(connector: info.id, client: client, now: now) }
            }
            if await delivery.tick(now: now) { pushBoard() }
        }
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
