import Foundation

/// Merging two people and splitting a merge (features §3 P1, P4; §6 "Merging two people moves their links").
/// A merge keeps a record of exactly what moved, so a split puts it back.
extension CircleStore {
    private struct Moved: Codable {
        var handles: [Int64] = []
        var exchanges: [Int64] = []
        var links: [MovedLink] = []
        var aliases: [String] = []
        var tags: [String] = []
        var primaryTag: String?
        var fields: [String] = []
        var updates: [Int64] = []
        var officers: [String] = []
    }
    private struct MovedLink: Codable {
        let other: String, kind: String, madeBy: String, mergedWasSubject: Bool, keptHadIt: Bool
    }

    /// Merges `merged` into `kept`: handles, hand-made exchanges, links, tags, aliases (its name too), empty details and
    /// updates move; `merged` is removed. Returns why it was refused, or nil.
    @discardableResult
    public func merge(kept: Int64, merged: Int64, auto: Bool = false, now: Date = Date()) -> String? {
        guard kept != merged, let k = people.person(kept), !k.deleted, let m = people.person(merged), !m.deleted else {
            return "Pick two different people."
        }
        let kTags = store.itemTags(k.shortID), mTags = store.itemTags(m.shortID)
        var union = kTags.all
        for t in mTags.all where !union.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { union.append(t) }
        if let why = TagRules.problems(tags: union, tier: k.tier).first { return why }
        var moved = Moved()
        var ok = false
        do {
            try store.performThrowing {
                let db = store.db
                moved.handles = try db.query("SELECT id FROM person_handles WHERE person_id=?", [merged]) { DB.int($0, 0) }
                try db.run("UPDATE person_handles SET person_id=? WHERE person_id=?", [kept, merged])
                moved.exchanges = try db.query("SELECT id FROM circle_exchanges WHERE handle_kind='person' AND handle=?", [String(merged)]) { DB.int($0, 0) }
                try db.run("UPDATE circle_exchanges SET handle=? WHERE handle_kind='person' AND handle=?", [String(kept), String(merged)])
                moved.updates = try db.query("SELECT id FROM circle_updates WHERE person_id=?", [merged]) { DB.int($0, 0) }
                try db.run("UPDATE circle_updates SET person_id=? WHERE person_id=?", [kept, merged])
                moved.officers = try db.query("SELECT officer_id FROM officer_candidates WHERE person_id=?", [merged]) { DB.text($0, 0) }
                try db.run("UPDATE OR IGNORE officer_candidates SET person_id=? WHERE person_id=?", [kept, merged])
                // Links: each of merged's links now ends at kept (kind and maker kept).
                let keptOthers = Set(try store.storedLinks(of: k.shortID).map { $0.from == k.shortID ? $0.to : $0.from })
                for l in try store.storedLinks(of: m.shortID) {
                    let other = l.from == m.shortID ? l.to : l.from
                    let (f, t) = ShortID.ordered(m.shortID, other)
                    try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Store.pairArgs(f, t))
                    let had = keptOthers.contains(other) || other == k.shortID
                    moved.links.append(MovedLink(other: other.text, kind: l.kind.rawValue, madeBy: l.madeBy.rawValue,
                                                 mergedWasSubject: l.subject == m.shortID.text, keptHadIt: had))
                    if !had {
                        let mergedSubject = l.subject == m.shortID.text
                        _ = try store.linkRow(mergedSubject ? k.shortID : other, mergedSubject ? other : k.shortID, kind: l.kind, madeBy: l.madeBy,
                                              actor: .user, now: l.created)
                    }
                }
                // Aliases: the merged name and its aliases.
                var aliases = k.aliases
                for a in [m.name] + m.aliases where PeopleStore.key(a) != PeopleStore.key(k.name)
                    && !aliases.contains(where: { PeopleStore.key($0) == PeopleStore.key(a) }) {
                    aliases.append(a); moved.aliases.append(a)
                }
                let aj = String(decoding: try JSONSerialization.data(withJSONObject: aliases), as: UTF8.self)
                try db.run("UPDATE people SET aliases=?, updated=? WHERE id=?", [aj, now, kept])
                // Tags.
                moved.tags = mTags.all.filter { t in !kTags.all.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                if kTags.primary == nil, let p = mTags.primary { moved.primaryTag = p }
                if !moved.tags.isEmpty {
                    let primary = kTags.primary ?? mTags.primary ?? union.first
                    try store.setTagsRow(k.shortID, primary: primary, others: union.filter { $0 != primary }, now: now)
                }
                // Details: kept's empty fields take merged's.
                var kd = details(kept)
                let md = details(merged)
                for (name, path) in Self.textFields where kd[keyPath: path].isEmpty && !md[keyPath: path].isEmpty {
                    kd[keyPath: path] = md[keyPath: path]; moved.fields.append(name)
                }
                try writeDetailsRow(kept, kd)
                // The merged person goes (its links have moved, so nothing is hidden).
                try db.run("UPDATE people SET deleted=1, updated=? WHERE id=?", [now, merged])
                let json = String(decoding: try JSONEncoder().encode(moved), as: UTF8.self)
                try db.run("INSERT INTO circle_merges(kept, merged, moved, auto, at) VALUES(?,?,?,?,?)", [kept, merged, json, auto ? 1 : 0, now])
                ok = true
            }
        } catch {
            store.activity("circle", .error, "Could not merge \(m.name) into \(k.name)", detail: "\(error)")
            return "Could not merge them; see Activity."
        }
        if ok { store.activity("circle", .info, (auto ? "Merged automatically (same phone or email): " : "Merged: ") + "\(m.name) into \(k.name)") }
        return nil
    }

    static let textFields: [(String, WritableKeyPath<CircleDetails, String>)] = [
        ("how_known", \.howKnown), ("company", \.company), ("role", \.role), ("birthday", \.birthday), ("language", \.language),
        ("notes", \.notes), ("firm", \.firm), ("focus", \.focus), ("purpose", \.purpose), ("stage", \.stage), ("feed_url", \.feedURL),
    ]

    /// Merges into this person that have not been split, newest first.
    public func merges(of personID: Int64) -> [MergeRecord] {
        do {
            return try store.db.query("SELECT id, kept, merged, auto, at FROM circle_merges WHERE kept=? AND split IS NULL ORDER BY id DESC", [personID]) { s in
                MergeRecord(id: DB.int(s, 0), kept: DB.int(s, 1), merged: DB.int(s, 2), auto: DB.int(s, 3) != 0, at: DB.date(s, 4) ?? Date())
            }
        } catch {
            store.activity("circle", .error, "Could not read merges", detail: "\(error)")
            return []
        }
    }

    /// Undoes a merge: the merged person comes back with what it brought.
    public func split(_ mergeID: Int64, now: Date = Date()) {
        guard let row = ((try? store.db.query("SELECT kept, merged, moved FROM circle_merges WHERE id=? AND split IS NULL", [mergeID]) { // try?-ok: unreadable = nothing to split; reported below
            (DB.int($0, 0), DB.int($0, 1), DB.text($0, 2)) }) ?? []).first,
              let moved = try? JSONDecoder().decode(Moved.self, from: Data(row.2.utf8)) // try?-ok: reported below
        else { store.activity("circle", .error, "Could not split that merge (its record is missing)"); return }
        let (kept, merged) = (row.0, row.1)
        let k = ShortID(kind: .person, number: kept), m = ShortID(kind: .person, number: merged)
        store.perform {
            let db = store.db
            try db.run("UPDATE people SET deleted=0, updated=? WHERE id=?", [now, merged])
            for id in moved.handles { try db.run("UPDATE person_handles SET person_id=? WHERE id=?", [merged, id]) }
            for id in moved.exchanges { try db.run("UPDATE circle_exchanges SET handle=? WHERE id=?", [String(merged), id]) }
            for id in moved.updates { try db.run("UPDATE circle_updates SET person_id=? WHERE id=?", [merged, id]) }
            for o in moved.officers { try db.run("UPDATE OR IGNORE officer_candidates SET person_id=? WHERE person_id=? AND officer_id=?", [merged, kept, o]) }
            for l in moved.links {
                guard let other = ShortID.parse(l.other) else { continue }
                if !l.keptHadIt {
                    let (f, t) = ShortID.ordered(k, other)
                    try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Store.pairArgs(f, t))
                }
                let kind = ItemLinkKind(rawValue: l.kind) ?? .related, maker = LinkMaker(rawValue: l.madeBy) ?? .manual
                _ = try store.linkRow(l.mergedWasSubject ? m : other, l.mergedWasSubject ? other : m, kind: kind, madeBy: maker, actor: .user, now: now)
            }
            if let p = people.person(kept) {
                let aliases = p.aliases.filter { a in !moved.aliases.contains { PeopleStore.key($0) == PeopleStore.key(a) } }
                let aj = String(decoding: try JSONSerialization.data(withJSONObject: aliases), as: UTF8.self)
                try db.run("UPDATE people SET aliases=?, updated=? WHERE id=?", [aj, now, kept])
            }
            if !moved.tags.isEmpty || moved.primaryTag != nil {
                let now0 = store.itemTags(k)
                let left = now0.all.filter { t in !moved.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
                let primary = left.first { $0.caseInsensitiveCompare(now0.primary ?? "") == .orderedSame } ?? left.first
                try store.setTagsRow(k, primary: primary, others: left.filter { $0 != primary }, now: now)
            }
            var kd = details(kept)
            for (name, path) in Self.textFields where moved.fields.contains(name) { kd[keyPath: path] = "" }
            try writeDetailsRow(kept, kd)
            try db.run("UPDATE circle_merges SET split=? WHERE id=?", [now, mergeID])
        }
        store.activity("circle", .info, "Split \(people.person(merged)?.name ?? m.text) from \(people.person(kept)?.name ?? k.text)")
    }
}
