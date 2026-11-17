import Foundation

/// An item's tags: one primary (a task's decides its colour and board group) and any number of others.
public struct ItemTags: Equatable {
    public var primary: String?
    public var others: [String]
    public init(primary: String?, others: [String]) { self.primary = primary; self.others = others }
    /// Primary first, each once.
    public var all: [String] {
        var out: [String] = []
        for t in [primary].compactMap({ $0 }) + others where !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { out.append(t) }
        return out
    }
}

/// The fixed tags' rules (features §3, §9), as one pure check used by every form, bulk edit and import.
public enum TagRules {
    public static let investor = "Investor"
    public static let prospect = "Prospect"
    public static let fixed = [investor, prospect]
    /// Fixed tags' colours (they are never board groups unless a task already uses one).
    static let fixedColors = [investor: "#FFD60A", prospect: "#40C8E0"]

    /// What is wrong with these tags on an item of this tier, worded for the owner; empty = allowed.
    public static func problems(tags: [String], tier: PersonTier?) -> [String] {
        var out: [String] = []
        if tier == .family && tags.contains(where: { $0.caseInsensitiveCompare(prospect) == .orderedSame }) {
            out.append("Prospect can't be used on Family.")
        }
        return out
    }

    /// Investor caps a person's contact interval at 3 months (Circle applies it); nil = no cap.
    public static func intervalCapMonths(tags: [String]) -> Int? {
        tags.contains { $0.caseInsensitiveCompare(investor) == .orderedSame } ? 3 : nil
    }
}

/// Filtering and counting by tag: a filter matches an item carrying any selected tag; counts count each item once per tag.
public enum TagFilter {
    public static func matches(_ tags: ItemTags, any selected: Set<String>) -> Bool {
        guard !selected.isEmpty else { return true }
        let wanted = Set(selected.map { $0.lowercased() })
        return tags.all.contains { wanted.contains($0.lowercased()) }
    }

    public static func counts(_ items: [ItemTags]) -> [String: Int] {
        var out: [String: Int] = [:]
        for i in items { for t in i.all { out[t, default: 0] += 1 } }
        return out
    }
}

extension Store {
    /// Adds the fixed tags if missing (an existing group of that name is reused) and marks them fixed. Runs at every start.
    func seedFixedTags() {
        do {
            for (i, name) in TagRules.fixed.enumerated() {
                try db.run("INSERT OR IGNORE INTO areas(name, color, position, fixed) VALUES(?,?,?,1)",
                           [name, TagRules.fixedColors[name] ?? "#8E8E93", 2000.0 + Double(i)])
                try db.run("UPDATE areas SET fixed=1 WHERE name=? COLLATE NOCASE AND fixed=0", [name])
            }
        } catch {
            activity("store", .error, "Could not set up the fixed tags", detail: "\(error)")
        }
    }

    private func tagID(_ name: String) throws -> Int64? {
        try db.query("SELECT id FROM areas WHERE name=? COLLATE NOCASE", [name]) { DB.int($0, 0) }.first
    }

    /// The item's tags. A task's primary is its group; its others, and every tag of other items, are `item_tags` rows.
    public func itemTags(_ id: ShortID) -> ItemTags {
        do {
            let rows = try db.query("""
                SELECT a.name, t.is_primary FROM item_tags t JOIN areas a ON a.id=t.tag_id WHERE t.item=? ORDER BY t.is_primary DESC, a.position, a.id
                """, [id.text]) { (DB.text($0, 0), DB.int($0, 1) != 0) }
            if id.kind == .task {
                let area = try db.query("SELECT area FROM cards WHERE id=?", [id.number]) { DB.text($0, 0) }.first
                return ItemTags(primary: area, others: rows.map(\.0).filter { $0.caseInsensitiveCompare(area ?? "") != .orderedSame })
            }
            return ItemTags(primary: rows.first(where: \.1)?.0, others: rows.filter { !$0.1 }.map(\.0))
        } catch {
            activity("store", .error, "Could not read tags", detail: "\(error)")
            return ItemTags(primary: nil, others: [])
        }
    }

    /// Replaces an item's tags. Every name must be an existing tag; the fixed tags' rules are checked (`tier` for a person).
    /// A task's primary must be one of its groups and is saved as its group (history, phone and colour follow as for any
    /// group change). Returns why it was refused, or nil.
    @discardableResult
    public func setTags(_ id: ShortID, primary: String?, others: [String], tier: PersonTier? = nil, now: Date = Date()) -> String? {
        var wanted = ItemTags(primary: primary, others: others)
        wanted.others = wanted.all.filter { $0.caseInsensitiveCompare(primary ?? "") != .orderedSame }
        if let p = TagRules.problems(tags: wanted.all, tier: tier).first { return p }
        if let unknown = wanted.all.first(where: { name in !tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) {
            return "There's no tag called \(unknown)."
        }
        if id.kind == .task {
            guard primary != nil, card(id.number) != nil else { return "A task needs a group." }
        }
        perform { try setTagsRow(id, primary: primary, others: wanted.others, now: now) }
        return nil
    }

    /// The body of `setTags` (names already checked), for callers inside a transaction.
    func setTagsRow(_ id: ShortID, primary: String?, others: [String], now: Date) throws {
        let canonical = { (n: String) in self.tags.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.name ?? n }
        if id.kind == .task, let p = primary { try setAreaRow(id.number, canonical(p), now: now) }
        let wanted = ItemTags(primary: primary, others: others)
        let before = itemTags(id)
        do {
            try db.run("DELETE FROM item_tags WHERE item=?", [id.text])
            if id.kind != .task, let p = primary, let tid = try tagID(p) {
                try db.run("INSERT INTO item_tags(item, tag_id, is_primary, added) VALUES(?,?,1,?)", [id.text, tid, now])
            }
            for name in wanted.others where name.caseInsensitiveCompare(primary ?? "") != .orderedSame {
                guard let tid = try tagID(name) else { continue }
                try db.run("INSERT OR IGNORE INTO item_tags(item, tag_id, is_primary, added) VALUES(?,?,0,?)", [id.text, tid, now])
            }
            if id.kind == .task && Set(before.others.map { $0.lowercased() }) != Set(wanted.others.map { $0.lowercased() }) {
                try db.run("UPDATE cards SET updated=? WHERE id=?", [now, id.number])
                try insertEvent(id.number, "tags: " + (wanted.others.isEmpty ? "none" : wanted.others.map(canonical).joined(separator: ", ")),
                                actor: .user, at: now)
                try stampTagsRow([id.number], now: now)
            }
        }
    }

    /// Notes that these tasks' tags (group or others) changed here at `now`, so an older phone tag edit loses. Every Mac path
    /// that changes a task's group or tags calls this (editor, board, tag editor, group rename, group delete).
    func stampTagsRow(_ cardIDs: [Int64], now: Date) throws {
        for id in cardIDs { try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", ["tags_at:\(id)", String(now.timeIntervalSince1970)]) }
    }

    /// The same for every task (deleted ones too) in the group `name`.
    func stampTagsOfGroupRow(_ name: String, now: Date) throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) SELECT 'tags_at:' || id, ? FROM cards WHERE area=?", [String(now.timeIntervalSince1970), name])
    }

    /// When a task's tags (its group or its other tags) last changed on this Mac (nil: never), so an older phone change loses.
    public func tagsChangedAt(_ cardID: Int64) -> Date? {
        let v = (try? db.query("SELECT value FROM meta WHERE key=?", ["tags_at:\(cardID)"]) { DB.text($0, 0) })?.first // try?-ok: unknown = never changed
        let group = (try? db.query("SELECT max(at) FROM events WHERE card_id=? AND kind LIKE 'group:%'", [cardID]) { DB.date($0, 0) })?.first ?? nil // try?-ok: unknown = never changed
        return [v.flatMap(Double.init).map(Date.init(timeIntervalSince1970:)), group].compactMap { $0 }.max()
    }

    /// Items carrying any of `tags` (live tasks by group or other tag; other kinds by their rows), each once, by id text.
    public func items(taggedAny names: Set<String>, kind: ItemKind? = nil) -> [ShortID] {
        guard !names.isEmpty else { return [] }
        let lower = names.map { $0.lowercased() }
        let marks = lower.map { _ in "?" }.joined(separator: ",")
        do {
            var out = Set(try db.query("""
                SELECT t.item FROM item_tags t JOIN areas a ON a.id=t.tag_id WHERE lower(a.name) IN (\(marks))
                """, lower) { ShortID.parse(DB.text($0, 0)) }.compactMap { $0 })
            out.formUnion(cards.filter { lower.contains($0.area.lowercased()) }.map { ShortID(kind: .task, number: $0.id) })
            let live = out.filter { id in id.kind != .task || card(id.number) != nil }
            return live.filter { kind == nil || $0.kind == kind }.sorted { ($0.kind.rawValue, $0.number) < ($1.kind.rawValue, $1.number) }
        } catch {
            activity("store", .error, "Could not read tagged items", detail: "\(error)")
            return []
        }
    }

    /// A deleted group's `item_tags` rows go; an item whose primary it was gets its first other tag as primary.
    func dropTagRows(_ tagID: Int64, now: Date = Date()) throws {
        let tasks = try db.query("SELECT item FROM item_tags WHERE tag_id=? AND item LIKE 'T-%'", [tagID]) { ShortID.parse(DB.text($0, 0)) }
        try stampTagsRow(tasks.compactMap { $0?.number }, now: now)
        let items = try db.query("SELECT item FROM item_tags WHERE tag_id=? AND is_primary=1", [tagID]) { DB.text($0, 0) }
        try db.run("DELETE FROM item_tags WHERE tag_id=?", [tagID])
        for item in items {
            try db.run("""
                UPDATE item_tags SET is_primary=1 WHERE rowid=(SELECT rowid FROM item_tags WHERE item=? ORDER BY added, tag_id LIMIT 1)
                """, [item])
        }
    }
}

extension TagRules {
    /// The phone copy's tag rule, the same as the engine's `parseTags` (engine/src/phone/board.ts): each tag trimmed and cut to
    /// 60 UTF-16 units (never splitting a character), empty ones dropped, a repeat (case ignored, after cutting) dropped,
    /// at most 20. Keep the two equal: a list that breaks it costs the card its tags on the engine.
    public static let phoneMaxTags = 20
    public static let phoneMaxTagUnits = 60

    public static func forPhone(_ tags: [String]) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for raw in tags {
            var t = "", n = 0
            for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                if n + ch.utf16.count > phoneMaxTagUnits { break }
                t.append(ch); n += ch.utf16.count
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == phoneMaxTags { break }
        }
        return out
    }
}
