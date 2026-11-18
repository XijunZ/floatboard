import Foundation
import SQLite3

// MARK: Review nudges

/// The quarterly and yearly review nudges (R4, §9): outside the reminder budget, at most one per period each, never in quiet
/// hours, only while the area is on and the ending period still has active goals.
public enum ResolutionNudges {
    public struct Due: Equatable {
        public let level: GoalLevel
        public let period: GoalPeriod
    }
    /// The review is open from 14 days before a period ends until 21 days into the next.
    public static let daysBefore = 14
    public static let daysAfter = 21

    static func nudgedKey(_ level: GoalLevel) -> String { "resolutions_nudged_\(level.rawValue)" }

    /// The period of this level whose review is open at `now`, if any.
    public static func reviewPeriod(_ level: GoalLevel, now: Date) -> GoalPeriod? {
        let cal = AppTime.calendar
        let cur = GoalPeriod.current(level, now: now)
        if let from = cal.date(byAdding: .day, value: -daysBefore, to: cur.interval.end), now >= from { return cur }
        let prev = cur.previous
        if let until = cal.date(byAdding: .day, value: daysAfter, to: prev.interval.end), now < until { return prev }
        return nil
    }

    /// Reviews in their window at `now` whose period still has an active goal (quarter first): the ones nudged.
    @MainActor static func windowReviews(store: Store, now: Date) -> [GoalPeriod] {
        guard store.isOn(.resolutions) else { return [] }
        let r = ResolutionStore(store: store)
        return [GoalLevel.quarter, .year].compactMap { reviewPeriod($0, now: now) }
            .filter { p in r.goals(in: p).contains { $0.status == .active } }
    }

    /// Every review that can be done at `now`: those in their window (quarter first), then any ended period that still has
    /// an active goal because its window was missed (overdue, oldest first). Never closed until done.
    @MainActor public static func openReviews(store: Store, now: Date) -> [GoalPeriod] {
        let window = windowReviews(store: store, now: now)
        guard store.isOn(.resolutions) else { return [] }
        let r = ResolutionStore(store: store)
        var overdue: [GoalPeriod] = []
        for level in [GoalLevel.quarter, .year] {
            for g in r.goals(level: level) where g.reviewOverdue(now: now) && !window.contains(g.period) && !overdue.contains(g.period) {
                overdue.append(g.period)
            }
        }
        return window + overdue.sorted { ($0.interval.start, $0.level == .quarter ? 0 : 1) < ($1.interval.start, $1.level == .quarter ? 0 : 1) }
    }


    /// Nudges to give now: open reviews not nudged for their period yet, outside quiet hours.
    @MainActor public static func due(store: Store, now: Date) -> [Due] {
        guard !inQuietHours(ReminderBudget(store: store).settings, now: now) else { return [] }
        return windowReviews(store: store, now: now).filter { p in
            let last = (try? store.db.query("SELECT value FROM meta WHERE key=?", [nudgedKey(p.level)]) { DB.text($0, 0) })?.first // try?-ok: unreadable = not nudged; at worst one extra nudge
            return last != p.key
        }.map { Due(level: $0.level, period: $0) }
    }

    /// Records that these were given, so each period is nudged once.
    @MainActor public static func markNudged(_ dues: [Due], store: Store) {
        store.perform {
            for d in dues { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [nudgedKey(d.level), d.period.key]) }
        }
    }

    /// The notification's text: one for both when a quarter and its year end together.
    public static func text(_ dues: [Due]) -> String {
        "Time to review " + dues.map(\.period.title).joined(separator: " and ") + "."
    }

    static func inQuietHours(_ s: ReminderSettings, now: Date) -> Bool {
        let c = AppTime.calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if s.quietStart == s.quietEnd { return false }
        return s.quietStart > s.quietEnd ? (m >= s.quietStart || m < s.quietEnd) : (m >= s.quietStart && m < s.quietEnd)
    }
}
