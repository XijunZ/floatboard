import Foundation

/// One search result: the item, a title line, a detail line, and its date (for a task, when it was added; an event, its start).
public struct SearchHit: Identifiable, Equatable {
    public var id: ShortID
    public let title: String
    public let detail: String
    public let date: Date?
    public init(id: ShortID, title: String, detail: String, date: Date?) { self.id = id; self.title = title; self.detail = detail; self.date = date }
}

/// One search across every kind of item (features: ground rules). Each area registers its kind; tasks and events are built in.
@MainActor public enum GlobalSearch {
    private struct Provider { let module: Module?; let find: @MainActor (Store, String) -> [SearchHit] }
    private static var providers: [ItemKind: Provider] = [
        .task: Provider(module: nil, find: tasks),
        .event: Provider(module: nil, find: events),
    ]

    /// Adds (or replaces) a kind's search. `module`: skipped while that module is off.
    public static func register(_ kind: ItemKind, module: Module?, _ f: @escaping @MainActor (Store, String) -> [SearchHit]) {
        providers[kind] = Provider(module: module, find: f)
    }

    /// Results by kind, in id-letter order (tasks, events, jots, people, decisions, goals), at most `limit` each; kinds with
    /// none are left out. A typed id ("T-12") finds exactly that item.
    /// `skipping`: kinds the caller searches itself (Search everything matches people off the main thread).
    public static func run(_ query: String, store: Store, limit: Int = 20, skipping: Set<ItemKind> = []) -> [(ItemKind, [SearchHit])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let id = ShortID.parse(q) {
            guard let p = providers[id.kind], p.module.map(store.isOn) ?? true, let s = store.item(id), !s.deleted else { return [] }
            return [(id.kind, [SearchHit(id: id, title: s.title, detail: "", date: s.added ?? s.updated)])]
        }
        return ItemKind.allCases.compactMap { kind in
            guard !skipping.contains(kind), let p = providers[kind], p.module.map(store.isOn) ?? true else { return nil }
            let hits = Array(p.find(store, q).prefix(limit))
            return hits.isEmpty ? nil : (kind, hits)
        }
    }

    /// Every word somewhere in the text (any order, case and accents ignored).
    public static func matches(_ text: String, _ query: String) -> Bool {
        let w = Search.words(query)
        return !w.isEmpty && w.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func tasks(_ store: Store, _ q: String) -> [SearchHit] {
        store.cards.filter { !$0.withdrawn && Search.matches($0, q) }
            .sorted { ($0.status == .done ? 1 : 0, -$0.created.timeIntervalSince1970) < ($1.status == .done ? 1 : 0, -$1.created.timeIntervalSince1970) }
            .map { SearchHit(id: ShortID(kind: .task, number: $0.id), title: $0.title, detail: $0.status.title + " · " + $0.area, date: $0.created) }
    }

    private static func events(_ store: Store, _ q: String) -> [SearchHit] {
        let cache = CalendarCache(store: store)
        let now = Date()
        return cache.events(from: now.addingTimeInterval(-365 * 86400), to: now.addingTimeInterval(365 * 86400))
            .filter { matches($0.title + " " + $0.location + " " + $0.description, q) }
            .sorted { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
            .map { SearchHit(id: $0.id, title: $0.title, detail: Fmt.meeting($0.start, now: now), date: $0.start) }
    }
}
