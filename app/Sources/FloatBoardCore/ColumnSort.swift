import Foundation

/// What tasks can be sorted by: the bar's order settings and each board column's sort menu share these.
public enum SortKey: String, Codable, CaseIterable, Identifiable {
    case due, status, importance, group, added
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .due: "Due date"
        case .status: "Status"
        case .importance: "Importance"
        case .group: "Group"
        case .added: "Date added"
        }
    }
    /// The direction a column starts in when this key is picked (the same as the bar's: soonest, High first, oldest, Groups-tab order).
    public var naturalAscending: Bool { self != .importance }
}

/// One board column's sort. Ties keep the board's order (due date, then importance, then oldest).
/// `key` nil exists only in Done and means "Date finished" (the store gives Done newest first).
public struct ColumnSort: Codable, Equatable {
    public var key: SortKey?
    public var ascending: Bool
    public init(key: SortKey? = nil, ascending: Bool = true) { self.key = key; self.ascending = ascending }

    /// The sort a column starts with: Due date (soonest first) for open columns, Date finished (newest first) for Done.
    public static func initial(for status: Status) -> ColumnSort {
        status == .done ? ColumnSort(key: nil, ascending: false) : ColumnSort(key: .due, ascending: true)
    }

    /// The column's saved sort, or its initial one (also when an open column has none saved, e.g. from an earlier version).
    public static func forColumn(_ status: Status, saved: ColumnSort?) -> ColumnSort {
        guard let saved, saved.key != nil || status == .done else { return initial(for: status) }
        return saved
    }

    /// `cards` in the board's order; returns them sorted by `key` (tasks without a due date always last).
    public func apply(_ cards: [Card], groupOrder: [String]) -> [Card] {
        guard let key else { return ascending ? cards.reversed() : cards }
        let pos = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0) })
        return cards.sorted { a, b in
            if let r = Self.compare(a, b, key, ascending, groupOrder) { return r }
            return pos[a.id]! < pos[b.id]!
        }
    }

    /// true/false when a and b differ on `key`, nil when they tie.
    static func compare(_ a: Card, _ b: Card, _ key: SortKey, _ asc: Bool, _ groupOrder: [String]) -> Bool? {
        func ord<T: Comparable>(_ x: T, _ y: T) -> Bool? { x == y ? nil : (asc ? x < y : x > y) }
        switch key {
        case .due:
            switch (a.dueSortKey, b.dueSortKey) {
            case let (x?, y?): return ord(x, y)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return nil
            }
        case .status:
            let rank: [Status: Int] = [.doing: 0, .todo: 1, .watch: 2, .done: 3]
            return ord(rank[a.status]!, rank[b.status]!)
        case .importance: return ord(a.importance.rawValue, b.importance.rawValue)
        case .group: return ord(groupOrder.firstIndex(of: a.area) ?? .max, groupOrder.firstIndex(of: b.area) ?? .max)
        case .added: return ord(a.created, b.created)
        }
    }
}
