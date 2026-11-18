import Foundation
import SQLite3

// Resolutions (features §5, §9; docs/superpowers/specs/2026-11-17-resolutions-design.md): a five-year picture, yearly and
// quarterly goals (`R-n`), work linked to them with `serves`, progress counted by code, and a review at each period's end.

/// A goal's level: the five-year picture (a few lines), a yearly goal or a quarterly goal.
public enum GoalLevel: String, CaseIterable {
    case fiveYear = "five_year", year, quarter
    /// Live goals one period can hold (R1).
    public var limit: Int { switch self { case .fiveYear: 1; case .year: 5; case .quarter: 3 } }
    public var title: String { switch self { case .fiveYear: "Five-year picture"; case .year: "Yearly goal"; case .quarter: "Quarterly goal" } }
    /// The level a goal of this level may sit under.
    public var parentLevel: GoalLevel? { switch self { case .quarter: .year; case .year: .fiveYear; case .fiveYear: nil } }
}

/// The period a goal belongs to: a quarter ("2027-Q1", shown "Q1 2027"), a year ("2027") or five years from a start year
/// ("2026-2030", shown "2026–2030"). Dates are worked out in the app's zone.
public struct GoalPeriod: Hashable {
    public let level: GoalLevel
    let year: Int
    /// 1–4 for a quarter, 0 otherwise.
    let quarter: Int

    init(level: GoalLevel, year: Int, quarter: Int = 0) { self.level = level; self.year = year; self.quarter = level == .quarter ? quarter : 0 }

    /// The period of this level that `now` falls in (a five-year picture starts in the current year).
    public static func current(_ level: GoalLevel, now: Date) -> GoalPeriod {
        let c = AppTime.calendar.dateComponents([.year, .month], from: now)
        let y = c.year ?? 2000
        return GoalPeriod(level: level, year: y, quarter: ((c.month ?? 1) - 1) / 3 + 1)
    }

    /// "2027-Q1" (quarter), "2027" (year), "2026-2030" (five years); nil when the key doesn't fit the level.
    public static func parse(level: GoalLevel, key: String) -> GoalPeriod? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let y = Int(parts.first ?? ""), (1900...9999).contains(y) else { return nil }
        switch level {
        case .year: return parts.count == 1 ? GoalPeriod(level: .year, year: y) : nil
        case .quarter:
            guard parts.count == 2, parts[1].count == 2, parts[1].hasPrefix("Q"), let q = Int(parts[1].dropFirst()), (1...4).contains(q) else { return nil }
            return GoalPeriod(level: .quarter, year: y, quarter: q)
        case .fiveYear:
            return parts.count == 2 && Int(parts[1]) == y + 4 ? GoalPeriod(level: .fiveYear, year: y) : nil
        }
    }

    public var key: String {
        switch level { case .quarter: "\(year)-Q\(quarter)"; case .year: "\(year)"; case .fiveYear: "\(year)-\(year + 4)" }
    }

    public var title: String {
        switch level { case .quarter: "Q\(quarter) \(year)"; case .year: "\(year)"; case .fiveYear: "\(year)–\(year + 4)" }
    }

    /// From the first day of the period to the first day after it, midnight in the app's zone.
    public var interval: DateInterval {
        let cal = AppTime.calendar
        let month = level == .quarter ? (quarter - 1) * 3 + 1 : 1
        let start = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let months = level == .quarter ? 3 : level == .year ? 12 : 60
        return DateInterval(start: start, end: cal.date(byAdding: .month, value: months, to: start) ?? start)
    }

    public var next: GoalPeriod {
        switch level {
        case .quarter: quarter == 4 ? GoalPeriod(level: .quarter, year: year + 1, quarter: 1) : GoalPeriod(level: .quarter, year: year, quarter: quarter + 1)
        case .year: GoalPeriod(level: .year, year: year + 1)
        case .fiveYear: GoalPeriod(level: .fiveYear, year: year + 5)
        }
    }

    public var previous: GoalPeriod {
        switch level {
        case .quarter: quarter == 1 ? GoalPeriod(level: .quarter, year: year - 1, quarter: 4) : GoalPeriod(level: .quarter, year: year, quarter: quarter - 1)
        case .year: GoalPeriod(level: .year, year: year - 1)
        case .fiveYear: GoalPeriod(level: .fiveYear, year: year - 5)
        }
    }

    /// True when `other` lies wholly inside this period (a year contains its quarters).
    public func contains(_ other: GoalPeriod) -> Bool {
        interval.start <= other.interval.start && other.interval.end <= interval.end
    }
}

/// Where a goal stands: active, or how its review ended. A reviewed goal is never edited again.
public enum GoalStatus: String, CaseIterable {
    case active, kept, changed, dropped
    public var title: String { switch self { case .active: "Active"; case .kept: "Kept"; case .changed: "Changed"; case .dropped: "Dropped" } }
}

/// What the review decided for a goal.
public enum ReviewOutcome: String, CaseIterable {
    case kept, changed, dropped
    public var status: GoalStatus { GoalStatus(rawValue: rawValue) ?? .active }
    public var title: String { status.title }
}

/// One goal (`R-n`).
public struct Goal: Identifiable, Equatable {
    public let id: Int64
    public var level: GoalLevel
    public var period: GoalPeriod
    public var title: String
    public var notes: String
    public var status: GoalStatus
    /// The goal of the previous period this one carries on.
    public var carriedFrom: Int64?
    public var position: Double
    public var source: ItemSource
    public var added: Date
    public var updated: Date
    public var reviewed: Date?
    public var deleted: Bool
    public var shortID: ShortID { ShortID(kind: .resolution, number: id) }
    /// True for an active goal whose period has ended: it still waits for its review (which stays possible however late).
    public func reviewOverdue(now: Date) -> Bool { status == .active && level != .fiveYear && now >= period.interval.end }
}

/// An earlier wording of a goal.
public struct GoalVersion: Equatable {
    public let title: String
    public let notes: String
    public let at: Date
}

/// Why a change to goals was refused, worded for the owner.
public struct GoalRefusal: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// A goal's progress, without scoring (R3): its tasks done and open (card ids), its recent jots and its decisions.
public struct GoalProgress: Equatable {
    public var done: [Int64]
    public var open: [Int64]
    public var jots: [ShortID]
    public var decisions: [ShortID]
    public init(done: [Int64], open: [Int64], jots: [ShortID], decisions: [ShortID]) {
        self.done = done; self.open = open; self.jots = jots; self.decisions = decisions
    }

    /// "3 done · 2 open · 1 jot · 1 decision"; "Nothing linked yet" when empty. Counts only, no percentages.
    public var summary: String {
        var parts: [String] = []
        if !done.isEmpty || !open.isEmpty { parts += ["\(done.count) done", "\(open.count) open"] }
        if !jots.isEmpty { parts.append("\(jots.count) jot\(jots.count == 1 ? "" : "s")") }
        if !decisions.isEmpty { parts.append("\(decisions.count) decision\(decisions.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing linked yet" : parts.joined(separator: " · ")
    }
}
