import Foundation

/// A person's tier in Circle (features §3): one each.
public enum PersonTier: String, CaseIterable {
    case family, close, network
    public var title: String { switch self { case .family: "Family"; case .close: "Close friend"; case .network: "Network" } }
}

/// One person (`P-n`). `aliases` are other names the person goes by, used to match names in text by code.
public struct Person: Identifiable, Equatable {
    public let id: Int64
    public var name: String
    public var aliases: [String]
    public var tier: PersonTier
    public var source: ItemSource
    public var added: Date
    public var updated: Date
    public var deleted: Bool
    public var shortID: ShortID { ShortID(kind: .person, number: id) }
}

/// The people table: the minimal core Circle builds on (and Jots and Decisions use to match names).
@MainActor public struct PeopleStore {
    let store: Store
    public init(store: Store) { self.store = store }

    /// Adds a person. An empty name adds nobody (nil).
    @discardableResult
    public func create(name: String, aliases: [String] = [], tier: PersonTier = .network, source: ItemSource = .typed, now: Date = Date()) -> Person? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        var id: Int64?
        store.perform {
            id = try store.db.run("INSERT INTO people(name, aliases, tier, source, added, updated) VALUES(?,?,?,?,?,?)",
                                  [n, Self.encode(aliases), tier.rawValue, source.rawValue, now, now])
        }
        return id.flatMap { person($0) }
    }

    /// Saves the name, aliases and tier. Returns false when nothing changed or the name is empty.
    @discardableResult
    public func update(_ p: Person, now: Date = Date()) -> Bool {
        let n = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let old = person(p.id), !old.deleted else { return false }
        guard old.name != n || old.aliases != Self.clean(p.aliases) || old.tier != p.tier else { return false }
        store.perform {
            try store.db.run("UPDATE people SET name=?, aliases=?, tier=?, updated=? WHERE id=?", [n, Self.encode(p.aliases), p.tier.rawValue, now, p.id])
        }
        return true
    }

    /// Soft delete: the row stays; links are hidden until `undoDelete`.
    public func delete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM people WHERE id=?", [id], { DB.int($0, 0) }).first == 0 else { return }
            try store.db.run("UPDATE people SET deleted=1, updated=? WHERE id=?", [now, id])
            try store.hideLinks(of: ShortID(kind: .person, number: id))
        }
    }

    public func undoDelete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM people WHERE id=?", [id], { DB.int($0, 0) }).first == 1 else { return }
            try store.db.run("UPDATE people SET deleted=0, updated=? WHERE id=?", [now, id])
            try store.unhideLinks(of: ShortID(kind: .person, number: id))
        }
    }

    public func person(_ id: Int64) -> Person? { read("WHERE id=?", [id]).first }

    /// Everyone, by name.
    public func people(includeDeleted: Bool = false) -> [Person] {
        read(includeDeleted ? "" : "WHERE deleted=0", []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Live people whose name or an alias is exactly `nameOrAlias` (ignoring case, accents and outer spaces).
    public func find(nameOrAlias: String) -> [Person] {
        let key = Self.key(nameOrAlias)
        guard !key.isEmpty else { return [] }
        return people().filter { p in Self.key(p.name) == key || p.aliases.contains { Self.key($0) == key } }
    }

    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func clean(_ aliases: [String]) -> [String] {
        aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func encode(_ aliases: [String]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: clean(aliases)) else { return "[]" } // try?-ok: an array of strings always encodes
        return String(decoding: d, as: UTF8.self)
    }

    private func read(_ tail: String, _ args: [Any?]) -> [Person] {
        do {
            return try store.db.query("SELECT id, name, aliases, tier, source, added, updated, deleted FROM people \(tail)", args) { s in
                let aliases = (try? JSONSerialization.jsonObject(with: Data(DB.text(s, 2).utf8))) as? [String] ?? [] // try?-ok: unreadable aliases read as none; the stored text is untouched
                return Person(id: DB.int(s, 0), name: DB.text(s, 1), aliases: aliases, tier: PersonTier(rawValue: DB.text(s, 3)) ?? .network,
                              source: ItemSource(rawValue: DB.text(s, 4)) ?? .typed, added: DB.date(s, 5) ?? Date(),
                              updated: DB.date(s, 6) ?? Date(), deleted: DB.int(s, 7) != 0)
            }
        } catch {
            store.activity("people", .error, "Could not read people", detail: "\(error)")
            return []
        }
    }
}
