import Foundation

/// The toolbar search's list (round 22): results grouped by where they live, in tab order (Tasks, Calendar, Jots,
/// Circle, Decisions, Goals) with a count each; at most `perGroup` rows a group, then "Show all N"; ↓/↑ move one
/// highlight through every row, across groups, stopping at the ends.
public struct SearchList {
    public struct Group: Equatable { public let kind: ItemKind; public let title: String; public let count: Int }
    /// One row: a result, or a group's "Show all N".
    public struct Row: Identifiable, Equatable {
        public let hit: SearchHit?
        public let showAll: ItemKind?
        public var id: String { hit.map { $0.id.text } ?? "all-\(showAll?.rawValue ?? "")" }
    }

    public static let perGroup = 5
    public private(set) var results: [(ItemKind, [SearchHit])]
    public private(set) var expanded: Set<ItemKind> = []
    /// The highlighted row's index in `rows` (nil: none yet).
    public private(set) var highlight: Int?

    public init(results: [(ItemKind, [SearchHit])]) {
        self.results = results.filter { !$0.1.isEmpty }.sorted { ItemKind.allCases.firstIndex(of: $0.0)! < ItemKind.allCases.firstIndex(of: $1.0)! }
    }

    public static func title(_ k: ItemKind) -> String {
        switch k { case .task: "Tasks"; case .event: "Calendar"; case .jot: "Jots"; case .person: "Circle"; case .decision: "Decisions"; case .resolution: "Goals" }
    }

    public var groups: [Group] { results.map { Group(kind: $0.0, title: Self.title($0.0), count: $0.1.count) } }

    /// The rows of one group as shown.
    public func rows(of kind: ItemKind) -> [Row] {
        guard let hits = results.first(where: { $0.0 == kind })?.1 else { return [] }
        if expanded.contains(kind) || hits.count <= Self.perGroup { return hits.map { Row(hit: $0, showAll: nil) } }
        return hits.prefix(Self.perGroup).map { Row(hit: $0, showAll: nil) } + [Row(hit: nil, showAll: kind)]
    }

    /// Every row, in order (what ↓/↑ move through).
    public var rows: [Row] { results.flatMap { rows(of: $0.0) } }

    public var highlighted: Row? { highlight.flatMap { $0 < rows.count ? rows[$0] : nil } }

    public mutating func move(_ by: Int) {
        let n = rows.count
        guard n > 0 else { highlight = nil; return }
        highlight = max(0, min(n - 1, (highlight ?? (by > 0 ? -1 : 0)) + by))
    }

    /// The first result highlighted (new results while typing, round 37); none when there are none.
    public mutating func highlightTop() { highlight = rows.firstIndex { $0.hit != nil } }

    /// "Show all N": the group's every result; the highlight stays on the row that was the group's last one shown.
    public mutating func expand(_ kind: ItemKind) { expanded.insert(kind) }
}
