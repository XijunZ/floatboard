import Foundation

/// A link between two items, as stored: `from` is the one with the smaller text, so a pair has one row whichever way round it is made.
struct StoredLink {
    let from: ShortID, to: ShortID, created: Date, actor: String
}

extension ShortID {
    /// The pair in storage order (smaller text first).
    static func ordered(_ a: ShortID, _ b: ShortID) -> (ShortID, ShortID) { a.text <= b.text ? (a, b) : (b, a) }
}

extension Store {
    /// Links two items. Linking an item to itself, or linking a pair twice, changes nothing.
    public func link(_ a: ShortID, _ b: ShortID, actor: Actor, now: Date = Date()) {
        guard a != b else { return }
        let (from, to) = ShortID.ordered(a, b)
        perform {
            try db.run("""
                INSERT OR IGNORE INTO links(from_type, from_id, to_type, to_id, created, actor) VALUES(?,?,?,?,?,?)
                """, [from.kind.rawValue, String(from.number), to.kind.rawValue, String(to.number), now, actor.stored])
        }
    }

    /// Removes the link between two items, whichever way round it was made.
    public func unlink(_ a: ShortID, _ b: ShortID) {
        let (from, to) = ShortID.ordered(a, b)
        perform {
            try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?",
                       [from.kind.rawValue, String(from.number), to.kind.rawValue, String(to.number)])
        }
    }

    /// The other end of every link that touches `id`, oldest link first.
    public func links(of id: ShortID) -> [ShortID] {
        do {
            return try storedLinks(of: id).map { $0.from == id ? $0.to : $0.from }
        } catch {
            activity("store", .error, "Could not read links", detail: "\(error)")
            return []
        }
    }

    func storedLinks(of id: ShortID) throws -> [StoredLink] {
        let k = id.kind.rawValue, n = String(id.number)
        return try db.query("""
            SELECT from_type, from_id, to_type, to_id, created, actor FROM links
            WHERE (from_type=? AND from_id=?) OR (to_type=? AND to_id=?) ORDER BY id
            """, [k, n, k, n]) { s in
            guard let ft = ItemKind(rawValue: DB.text(s, 0)), let f = Int64(DB.text(s, 1)),
                  let tt = ItemKind(rawValue: DB.text(s, 2)), let t = Int64(DB.text(s, 3)) else { return nil }
            return StoredLink(from: ShortID(kind: ft, number: f), to: ShortID(kind: tt, number: t),
                              created: DB.date(s, 4) ?? Date(), actor: DB.text(s, 5))
        }.compactMap { $0 }
    }

    /// Takes every link off a deleted item and returns them, so Undo Delete can put the same ones back.
    func removeLinks(of id: ShortID) throws -> [StoredLink] {
        let removed = try storedLinks(of: id)
        for l in removed {
            try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?",
                       [l.from.kind.rawValue, String(l.from.number), l.to.kind.rawValue, String(l.to.number)])
        }
        return removed
    }

    func restoreLinks(_ links: [StoredLink]) throws {
        for l in links {
            try db.run("""
                INSERT OR IGNORE INTO links(from_type, from_id, to_type, to_id, created, actor) VALUES(?,?,?,?,?,?)
                """, [l.from.kind.rawValue, String(l.from.number), l.to.kind.rawValue, String(l.to.number), l.created, l.actor])
        }
    }
}
