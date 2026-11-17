import Foundation

/// One thing the link picker offers: a task or an event, with what the list needs to show it.
public struct LinkCandidate: Equatable {
    public let id: ShortID
    public let title: String
    /// An event's start (nil for a task).
    public let start: Date?
    public let done: Bool
}

/// What the "Link a task…" / "Link a meeting…" picker offers for what was typed. Pure, so it can be checked without a screen.
public enum LinkPickerSearch {
    /// Candidates of `kind`, best first, never more than `limit`.
    /// - A typed id ("t-142", "E-37") gives exactly that item (or nothing), never a longer number that starts the same.
    /// - Otherwise every word must be in the title. Events: those starting from `now` on, soonest first, then earlier ones, most
    ///   recent first. Tasks: open before done, titles that start with the text first, then newer first.
    /// - Items in `exclude` (already linked) and events Google has dropped are left out.
    public static func candidates(kind: ItemKind, cards: [Card], events: [CalEvent], query: String, now: Date,
                                  exclude: Set<ShortID> = [], limit: Int = 8) -> [LinkCandidate] {
        let all: [LinkCandidate]
        switch kind {
        case .task:
            all = cards.filter { !$0.withdrawn }.map {
                LinkCandidate(id: ShortID(kind: .task, number: $0.id), title: $0.title, start: nil, done: $0.status == .done)
            }
        case .event:
            all = events.filter { !$0.gone && !$0.cancelled }.map {
                LinkCandidate(id: $0.id, title: $0.title, start: $0.start, done: false)
            }
        default:
            all = []
        }
        let pool = all.filter { !exclude.contains($0.id) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed = ShortID.parse(text) {
            return pool.filter { $0.id == typed }
        }
        let words = Search.words(text)
        let hits = pool.filter { c in
            words.allSatisfy { c.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let ranked: [LinkCandidate]
        switch kind {
        case .event:
            let upcoming = hits.filter { $0.start! >= now }.sorted { $0.start! < $1.start! }
            let past = hits.filter { $0.start! < now }.sorted { $0.start! > $1.start! }
            ranked = upcoming + past
        case .task:
            let first = words.first ?? ""
            func starts(_ c: LinkCandidate) -> Bool { !first.isEmpty && c.title.lowercased().hasPrefix(first) }
            ranked = hits.sorted { a, b in
                if a.done != b.done { return !a.done }
                if starts(a) != starts(b) { return starts(a) }
                return a.id.number > b.id.number
            }
        default:
            ranked = hits
        }
        return Array(ranked.prefix(limit))
    }
}
