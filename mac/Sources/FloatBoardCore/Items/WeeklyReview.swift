import Foundation

/// One line on the weekly review page.
public struct ReviewItem: Identifiable, Equatable {
    public let id: String
    public let item: ShortID?
    public let title: String
    public let detail: String
    public init(id: String, item: ShortID?, title: String, detail: String) { self.id = id; self.item = item; self.title = title; self.detail = detail }
}

/// A section a module adds to the weekly review (Decisions: recorded, Maybe, due reviews; Circle: due people).
public struct ReviewSection {
    public let id: String
    public let title: String
    /// Shown only while this module is on (nil: always).
    public let module: Module?
    public let order: Int
    public let items: @MainActor (Store, DateInterval) -> [ReviewItem]
    public init(id: String, title: String, module: Module?, order: Int, items: @escaping @MainActor (Store, DateInterval) -> [ReviewItem]) {
        self.id = id; self.title = title; self.module = module; self.order = order; self.items = items
    }
}

/// The weekly review page under the bar (features §9): sections registered by modules, empty ones hidden, and a Sunday nudge.
@MainActor public enum WeeklyReview {
    private static var registered: [String: ReviewSection] = [:]
    private static var nudgeHooks: [() -> Void] = []
    /// The Sunday nudge's time in the app's zone.
    public static let nudgeHour = 18

    public static func register(_ s: ReviewSection) { registered[s.id] = s }

    /// Sections whose module is on and that have something to show this week, by order.
    public static func sections(store: Store, now: Date = Date()) -> [(ReviewSection, [ReviewItem])] {
        let w = week(containing: now)
        return registered.values.filter { $0.module.map(store.isOn) ?? true }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .map { ($0, $0.items(store, w)) }.filter { !$0.1.isEmpty }
    }

    /// Monday 00:00 to the next Monday 00:00 in the app's zone.
    public static func week(containing date: Date) -> DateInterval {
        let cal = AppTime.calendar
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day)          // 1 = Sunday
        let back = (weekday + 5) % 7                              // days since Monday
        let monday = cal.date(byAdding: .day, value: -back, to: day) ?? day
        let next = cal.date(byAdding: .day, value: 7, to: monday) ?? monday
        return DateInterval(start: monday, end: next)
    }

    /// True from Sunday 18:00 (app zone) until the nudge has been given once that week.
    public static func nudgeDue(now: Date, lastNudged: Date?) -> Bool {
        let cal = AppTime.calendar
        guard cal.component(.weekday, from: now) == 1, cal.component(.hour, from: now) >= nudgeHour else { return false }
        guard let last = lastNudged else { return true }
        return week(containing: last).start != week(containing: now).start
    }

    /// Hooks run when the Sunday nudge fires (modules prepare their sections; the app shows the nudge).
    public static func onNudge(_ f: @escaping () -> Void) { nudgeHooks.append(f) }
    public static func fireNudge() { nudgeHooks.forEach { $0() } }
}
