import Foundation

/// Where an item came from (the item standard: features, ground rules).
public enum ItemSource: String, CaseIterable {
    case typed, phone, meeting, message, claude
    public var title: String {
        switch self { case .typed: "Typed"; case .phone: "Phone"; case .meeting: "Meeting"; case .message: "Message"; case .claude: "Claude" }
    }
}

/// What every item shows wherever it is listed or linked: its id, a title line, its dates and where it came from.
public struct ItemSummary: Equatable {
    public let id: ShortID
    public let title: String
    public let added: Date?
    public let updated: Date?
    public let source: ItemSource?
    public let deleted: Bool
    public init(id: ShortID, title: String, added: Date?, updated: Date?, source: ItemSource?, deleted: Bool) {
        self.id = id; self.title = title; self.added = added; self.updated = updated; self.source = source; self.deleted = deleted
    }
}

extension Card {
    /// The task's source: what was recorded (`item_source`, e.g. "phone"), else typed for a task of the owner's, meeting for one
    /// made from meeting notes, message for one a connector made from an email or chat.
    public var itemSource: ItemSource {
        if let s = ItemSource(rawValue: itemSourceRaw) { return s }
        if connector.isEmpty && source.isEmpty { return .typed }
        let key = sourceKey?.messageID ?? ""
        if key.hasPrefix("fathom:") || sourceLink.contains("fathom.video") || source == "meeting" { return .meeting }
        return .message
    }
}

/// The kinds of item the app knows how to look up. Tasks, events, jots and people are built in; Decisions and Resolutions
/// register theirs when their module is built.
@MainActor public enum ItemCatalog {
    private static var lookups: [ItemKind: (Store, Int64) -> ItemSummary?] = [:]

    /// Adds (or replaces) the lookup for a kind.
    public static func register(_ kind: ItemKind, _ lookup: @escaping (Store, Int64) -> ItemSummary?) { lookups[kind] = lookup }

    static func lookup(_ id: ShortID, store: Store) -> ItemSummary? {
        if let f = lookups[id.kind] { return f(store, id.number) }
        return builtin(id, store: store)
    }

    static func isDeleted(_ id: ShortID, store: Store) throws -> Bool { lookup(id, store: store)?.deleted ?? false }

    private static func builtin(_ id: ShortID, store: Store) -> ItemSummary? {
        switch id.kind {
        case .task:
            if let c = store.card(id.number) {
                return ItemSummary(id: id, title: c.title, added: c.created, updated: store.updatedAt(id.number), source: c.itemSource, deleted: false)
            }
            let row = try? store.db.query("SELECT title, created, updated FROM cards WHERE id=?", [id.number]) { // try?-ok: unreadable = unknown item
                (DB.text($0, 0), DB.date($0, 1), DB.date($0, 2)) }.first
            return row.map { ItemSummary(id: id, title: $0.0, added: $0.1, updated: $0.2, source: nil, deleted: true) }
        case .event:
            let cache = CalendarCache(store: store)
            if let e = cache.event(shortID: id.number) {
                return ItemSummary(id: id, title: e.title, added: nil, updated: e.googleUpdated, source: nil, deleted: e.cancelled)
            }
            return cache.kept(shortID: id.number).map { ItemSummary(id: id, title: $0.title, added: nil, updated: nil, source: nil, deleted: true) }
        case .jot:
            return JotStore(store: store).jot(id.number).map {
                ItemSummary(id: id, title: Self.firstLine($0.text), added: $0.added, updated: $0.updated, source: $0.source, deleted: $0.deleted)
            }
        case .person:
            return PeopleStore(store: store).person(id.number).map {
                ItemSummary(id: id, title: $0.name, added: $0.added, updated: $0.updated, source: $0.source, deleted: $0.deleted)
            }
        case .decision, .resolution:
            return nil
        }
    }

    /// The first non-empty line of a text, at most 120 characters: how a jot is named in a chip or a list.
    public static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}

extension Store {
    /// Any item by id; nil when unknown. Deleted items come back with `deleted` set (a chip can say so).
    public func item(_ id: ShortID) -> ItemSummary? { ItemCatalog.lookup(id, store: self) }

    /// True for a known item that is not deleted.
    public func itemExists(_ id: ShortID) -> Bool { item(id).map { !$0.deleted } ?? false }

    /// When the task was last changed (the `updated` column; the card model does not carry it).
    func updatedAt(_ cardID: Int64) -> Date? {
        (try? db.query("SELECT updated FROM cards WHERE id=?", [cardID]) { DB.date($0, 0) })?.first ?? nil // try?-ok: unknown = no date shown
    }
}
