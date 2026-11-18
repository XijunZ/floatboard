import Foundation

/// Which tiers the Circle list shows (the toggle chips above it), kept on the board so the choice survives a relaunch.
/// Click: hide or show one tier (the last one shown can't be hidden: the list would be empty for no reason). Option-click:
/// show only that tier, or, when it already is the only one, all of them again.
public struct CircleTierFilter: Equatable {
    public private(set) var shown: Set<PersonTier>
    static let key = "circle.hidden_tiers"

    public init(shown: Set<PersonTier> = Set(PersonTier.allCases)) { self.shown = shown.isEmpty ? Set(PersonTier.allCases) : shown }

    public func shows(_ t: PersonTier) -> Bool { shown.contains(t) }

    /// The "Due this week" entries the list shows (and counts). A view filter only: reminders and notifications still go
    /// out for every tier.
    public func visible(_ due: [DueEntry]) -> [DueEntry] { due.filter { shows($0.person.tier) } }
    public var showsAll: Bool { shown.count == PersonTier.allCases.count }

    public mutating func toggle(_ t: PersonTier) {
        if shown.contains(t) { if shown.count > 1 { shown.remove(t) } } else { shown.insert(t) }
    }

    public mutating func only(_ t: PersonTier) {
        shown = shown == [t] ? Set(PersonTier.allCases) : [t]
    }

    /// Hidden tiers are stored (a tier added later is shown).
    @MainActor public static func load(store: Store) -> CircleTierFilter {
        let raw = (try? store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) })?.first ?? "" // try?-ok: unreadable = all shown
        let hidden = Set(raw.split(separator: ",").compactMap { PersonTier(rawValue: String($0)) })
        return CircleTierFilter(shown: Set(PersonTier.allCases).subtracting(hidden))
    }

    @MainActor public func save(store: Store) {
        let hidden = PersonTier.allCases.filter { !shown.contains($0) }.map(\.rawValue).joined(separator: ",")
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.key, hidden]) }
    }
}
