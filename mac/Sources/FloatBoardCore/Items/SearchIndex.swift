import Foundation

/// One searchable entry: what is shown for it and the text its words are matched in.
public struct SearchEntry: Sendable {
    public let hit: SearchHitData
    public let text: String
}

/// A search hit as plain values (safe to hand to another thread).
public struct SearchHitData: Sendable {
    public let kind: ItemKind, number: Int64, title: String, detail: String, date: Date?
    public var hit: SearchHit { SearchHit(id: ShortID(kind: kind, number: number), title: title, detail: detail, date: date) }
}

/// Search everything's text per person, kept until the board changes (`Store.reloads` moves on every write), so typing
/// doesn't rebuild it per keystroke; matching over it is plain values and can run off the main thread.
@MainActor public enum SearchIndex {
    private static var peopleCache: [ObjectIdentifier: (Int, [SearchEntry])] = [:]
    /// How many times an index was built (checks).
    public private(set) static var builds = 0

    public static func people(store: Store) -> [SearchEntry] {
        let key = ObjectIdentifier(store)
        if let (gen, entries) = peopleCache[key], gen == store.reloads { return entries }
        builds += 1
        let c = CircleStore(store: store)
        let details = c.allDetails(), handles = c.allHandles()
        let entries = PeopleStore(store: store).people().map { p -> SearchEntry in
            let d = details[p.id] ?? CircleDetails()
            let text = ([p.name] + p.aliases + [d.company, d.role, d.firm, d.howKnown] + (handles[p.id] ?? []).map(\.value)).joined(separator: " ")
            return SearchEntry(hit: SearchHitData(kind: .person, number: p.id, title: p.name,
                                                  detail: [p.tier.title, d.company].filter { !$0.isEmpty }.joined(separator: " · "), date: p.added), text: text)
        }
        peopleCache[key] = (store.reloads, entries)
        return entries
    }

    /// The entries whose text has every word of the query (any order, case and accents ignored).
    public nonisolated static func match(_ entries: [SearchEntry], _ query: String) -> [SearchHitData] {
        let w = Search.words(query)
        guard !w.isEmpty else { return [] }
        return entries.filter { e in w.allSatisfy { e.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }.map(\.hit)
    }
}
