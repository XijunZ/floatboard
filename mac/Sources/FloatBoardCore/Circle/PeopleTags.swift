import Foundation

/// The tags offered for people (owner, round 8): Investor and Prospect, plus any tag already used on at least one person.
/// The board's groups are not offered (they stay on tasks and jots); a tag already on a person is never taken off by this.
@MainActor public enum PeopleTags {
    /// Investor, Prospect, then tags used on people, in the tags' order, each once.
    public static func offered(store: Store) -> [String] {
        let used: Set<String>
        do {
            used = Set(try store.db.query("""
                SELECT DISTINCT lower(a.name) FROM item_tags t JOIN areas a ON a.id=t.tag_id WHERE t.item LIKE 'P-%'
                """) { DB.text($0, 0) })
        } catch {
            store.activity("circle", .error, "Could not read people's tags", detail: "\(error)")
            used = []
        }
        var out = TagRules.fixed
        for t in store.tags.map(\.name) where used.contains(t.lowercased()) && !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            out.append(t)
        }
        return out
    }

    /// "New tag…": a tag for people that is not a board group (kept like Investor and Prospect, outside the board's groups).
    /// Returns a problem, or nil when made.
    public static func add(store: Store, _ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the tag a name." }
        guard name.utf16.count <= 60 else { return "A tag name is at most 60 characters." }
        guard !store.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return "There's already a tag called \(name)." }
        let pos = (store.tags.map(\.position).max() ?? 0) + 1
        var failed = false
        do {
            try store.performThrowing {
                try store.db.run("INSERT INTO areas(name, color, position, fixed) VALUES(?,?,?,1)", [name, "#8E8E93", pos])
            }
        } catch {
            failed = true
            store.activity("circle", .error, "Could not make the tag \(name)", detail: "\(error)")
        }
        return failed ? "Couldn't make the tag; see Activity." : nil
    }

    /// Adds one tag to one person (the detail pane's +); the fixed-tag and tier rules apply. Returns a problem, or nil.
    public static func addTo(store: Store, person: Int64, _ tag: String) -> String? {
        CircleStore(store: store).addTags([person], [tag]).first
    }

    /// Removes one tag from one person (a chip's ✕). Returns a problem, or nil.
    public static func removeFrom(store: Store, person: Int64, _ tag: String) -> String? {
        CircleStore(store: store).removeTags([person], [tag]).first
    }
}
