import Foundation

/// What a link means (features §6). Directed kinds are said of one end, the link's subject: `source` (the subject was made
/// from the other), `notes-of` (the subject holds the other's notes), `review-of`, `supersedes` (the subject replaces the
/// other), `serves` (the subject works towards the other goal), `own-event` (the subject task's own Google event).
public enum ItemLinkKind: String, CaseIterable {
    case ownEvent = "own-event", related, source, notesOf = "notes-of", reviewOf = "review-of", supersedes, serves
    public var directed: Bool { self != .related }
    /// How a chip names the other end, seen from the subject ("made from") and from the other end ("made into").
    public func label(isSubject: Bool) -> String {
        switch self {
        case .ownEvent: isSubject ? "own event" : "event of"
        case .related: "related"
        case .source: isSubject ? "made from" : "made into"
        case .notesOf: isSubject ? "notes of" : "notes"
        case .reviewOf: isSubject ? "review of" : "reviewed in"
        case .supersedes: isSubject ? "replaces" : "replaced by"
        case .serves: isSubject ? "serves" : "served by"
        }
    }
}

/// What kind of link a typed id makes. Related unless the area that owns the typed id's kind says otherwise (Resolutions:
/// a task, jot or decision typing a goal's id serves that goal).
@MainActor public enum MentionKinds {
    private static var rules: [ItemKind: (Store, ShortID, ShortID) -> ItemLinkKind?] = [:]
    /// `f(store, typedIn, typedID)`: the kind for an id of `target`'s kind typed into another item's text; nil = related.
    public static func register(_ target: ItemKind, _ f: @escaping (Store, ShortID, ShortID) -> ItemLinkKind?) { rules[target] = f }
    static func kind(store: Store, from: ShortID, to: ShortID) -> ItemLinkKind { rules[to.kind]?(store, from, to) ?? .related }
}

/// Who made a link: code on its own (`auto`), a suggestion the owner accepted (`suggested`), or the owner (`manual`).
public enum LinkMaker: String, CaseIterable { case auto, suggested, manual }

/// One visible link as seen from one item.
public struct ItemLink: Equatable {
    public let other: ShortID
    public let kind: ItemLinkKind
    public let madeBy: LinkMaker
    /// True when the item asked about is the one the kind is said of (the task in "task made from jot").
    public let isSubject: Bool
    public let created: Date
}

/// The link the last ✕ removed, for Undo.
public struct UnlinkedLink: Equatable {
    let row: StoredLink
    public var a: ShortID { row.from }
    public var b: ShortID { row.to }
}

/// A link as stored: `from` is the one with the smaller text, so a pair has one row whichever way round it is made.
struct StoredLink: Equatable {
    let from: ShortID, to: ShortID, created: Date, actor: String
    var kind: ItemLinkKind = .related
    var madeBy: LinkMaker = .manual
    /// The id text the kind is said of ("" for related).
    var subject: String = ""
    var hiddenBy: String = ""
}

extension ShortID {
    /// The pair in storage order (smaller text first).
    static func ordered(_ a: ShortID, _ b: ShortID) -> (ShortID, ShortID) { a.text <= b.text ? (a, b) : (b, a) }
}

extension Store {
    /// Links two items; `a` is the subject of a directed kind (`link(task, jot, kind: .source)`: the task was made from the jot).
    /// A pair already linked keeps its one row: a manual link is never replaced by an auto or suggested one; otherwise the
    /// kind, subject and maker are replaced. Linking an item to itself, or to a deleted item, changes nothing.
    /// Returns true when something was written.
    @discardableResult
    public func link(_ a: ShortID, _ b: ShortID, kind: ItemLinkKind = .related, madeBy: LinkMaker = .manual, actor: Actor, now: Date = Date()) -> Bool {
        var wrote = false
        perform { wrote = try linkRow(a, b, kind: kind, madeBy: madeBy, actor: actor, now: now) }
        return wrote
    }

    /// The body of `link`, for callers inside a transaction.
    @discardableResult
    func linkRow(_ a: ShortID, _ b: ShortID, kind: ItemLinkKind, madeBy: LinkMaker, actor: Actor, now: Date) throws -> Bool {
        guard a != b, try !isDeletedItem(a), try !isDeletedItem(b) else { return false }
        let (from, to) = ShortID.ordered(a, b)
        let subject = kind.directed ? a.text : ""
        let existing = try db.query("""
            SELECT made_by, kind, subject, hidden_by FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?
            """, Self.pairArgs(from, to)) { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2), DB.text($0, 3)) }.first
        if let e = existing {
            guard e.3.isEmpty else { return false }   // hidden: one end is deleted
            if e.0 == LinkMaker.manual.rawValue && madeBy != .manual { return false }
            if e.0 == madeBy.rawValue && e.1 == kind.rawValue && e.2 == subject { return false }
            try db.run("UPDATE links SET kind=?, made_by=?, subject=? WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?",
                       [kind.rawValue, madeBy.rawValue, subject] + Self.pairArgs(from, to))
            return true
        }
        try db.run("""
            INSERT INTO links(from_type, from_id, to_type, to_id, created, actor, kind, made_by, subject) VALUES(?,?,?,?,?,?,?,?,?)
            """, Self.pairArgs(from, to) + [now, actor.stored, kind.rawValue, madeBy.rawValue, subject])
        return true
    }

    /// Removes the link between two items, whichever way round it was made (no Undo).
    public func unlink(_ a: ShortID, _ b: ShortID) {
        let (from, to) = ShortID.ordered(a, b)
        perform { try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Self.pairArgs(from, to)) }
    }

    /// The ✕ on a link chip: removes the link and keeps it for `undoUnlink`.
    public func unlinkWithUndo(_ a: ShortID, _ b: ShortID) {
        let (from, to) = ShortID.ordered(a, b)
        var removed: StoredLink?
        perform {
            removed = try storedRows(where: "from_type=? AND from_id=? AND to_type=? AND to_id=? AND hidden_by=''", Self.pairArgs(from, to)).first
            try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Self.pairArgs(from, to))
        }
        if let removed { lastUnlinked = UnlinkedLink(row: removed) }
    }

    /// Hides the Undo for the last ✕ (its time is up).
    public func clearUnlinkUndo() { lastUnlinked = nil }

    /// Puts back the link the last ✕ removed, as it was (kind, maker, date).
    public func undoUnlink() {
        guard let u = lastUnlinked else { return }
        perform {
            // A goal's parent (a serves link between two goals, the child as subject) comes back in place of any parent set
            // since: a goal never has two.
            if u.row.kind == .serves, u.row.from.kind == .resolution, u.row.to.kind == .resolution, let child = ShortID.parse(u.row.subject) {
                try ResolutionStore.deleteParentLinksRow(self, child: child, except: child == u.row.from ? u.row.to : u.row.from)
            }
            try restoreLinks([u.row])
        }
        lastUnlinked = nil
    }

    /// The other end of every visible link that touches `id`, oldest link first.
    public func links(of id: ShortID) -> [ShortID] { itemLinks(of: id).map(\.other) }

    /// Every visible link that touches `id`, oldest first, as seen from `id`.
    public func itemLinks(of id: ShortID) -> [ItemLink] {
        do {
            return try storedLinks(of: id).map { l in
                ItemLink(other: l.from == id ? l.to : l.from, kind: l.kind, madeBy: l.madeBy, isSubject: l.subject == id.text, created: l.created)
            }
        } catch {
            activity("store", .error, "Could not read links", detail: "\(error)")
            return []
        }
    }

    /// Visible links of `id`.
    func storedLinks(of id: ShortID) throws -> [StoredLink] {
        let k = id.kind.rawValue, n = String(id.number)
        return try storedRows(where: "((from_type=? AND from_id=?) OR (to_type=? AND to_id=?)) AND hidden_by=''", [k, n, k, n])
    }

    private func storedRows(where clause: String, _ args: [Any?]) throws -> [StoredLink] {
        try db.query("""
            SELECT from_type, from_id, to_type, to_id, created, actor, kind, made_by, subject, hidden_by FROM links WHERE \(clause) ORDER BY id
            """, args) { s in
            guard let ft = ItemKind(rawValue: DB.text(s, 0)), let f = Int64(DB.text(s, 1)),
                  let tt = ItemKind(rawValue: DB.text(s, 2)), let t = Int64(DB.text(s, 3)) else { return nil }
            return StoredLink(from: ShortID(kind: ft, number: f), to: ShortID(kind: tt, number: t), created: DB.date(s, 4) ?? Date(),
                              actor: DB.text(s, 5), kind: ItemLinkKind(rawValue: DB.text(s, 6)) ?? .related,
                              madeBy: LinkMaker(rawValue: DB.text(s, 7)) ?? .manual, subject: DB.text(s, 8), hiddenBy: DB.text(s, 9))
        }.compactMap { $0 }
    }

    /// Deleting an item (inside a transaction): its visible links are hidden, marked with its id, and stay in the table, so a
    /// restore brings them back even after a restart. Returns how many were hidden.
    @discardableResult
    func hideLinks(of id: ShortID) throws -> Int {
        let rows = try storedLinks(of: id)
        let k = id.kind.rawValue, n = String(id.number)
        try db.run("UPDATE links SET hidden_by=? WHERE ((from_type=? AND from_id=?) OR (to_type=? AND to_id=?)) AND hidden_by=''",
                   [id.text, k, n, k, n])
        return rows.count
    }

    /// Restoring an item (inside a transaction): the links it hid come back, except one whose other end is deleted
    /// meanwhile, which stays hidden, now by that item (so restoring that one brings it back).
    func unhideLinks(of id: ShortID) throws {
        let rows = try storedRows(where: "hidden_by=?", [id.text])
        for l in rows {
            let other = l.from == id ? l.to : l.from
            let by = try isDeletedItem(other) ? other.text : ""
            try db.run("UPDATE links SET hidden_by=? WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", [by] + Self.pairArgs(l.from, l.to))
        }
    }

    /// Takes every link off a deleted task and returns them (kept for callers that still remove instead of hiding).
    func removeLinks(of id: ShortID) throws -> [StoredLink] {
        let removed = try storedLinks(of: id)
        for l in removed {
            try db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Self.pairArgs(l.from, l.to))
        }
        return removed
    }

    func restoreLinks(_ links: [StoredLink]) throws {
        for l in links {
            try db.run("""
                INSERT OR IGNORE INTO links(from_type, from_id, to_type, to_id, created, actor, kind, made_by, subject) VALUES(?,?,?,?,?,?,?,?,?)
                """, Self.pairArgs(l.from, l.to) + [l.created, l.actor, l.kind.rawValue, l.madeBy.rawValue, l.subject])
            try db.run("UPDATE links SET hidden_by='' WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Self.pairArgs(l.from, l.to))
        }
    }

    /// Ids typed into a saved text (`text`, which was `previous`): each id that is new in the text, exists and is not the
    /// item itself is linked (related, manual, or the kind the id's area registered in `MentionKinds`). An id already in
    /// `previous` is left alone, so one the owner unlinked with ✕ stays unlinked until it is typed again. A pair that is
    /// already linked keeps its link as it is (a typed id never downgrades or replaces a link of another kind).
    public func linkMentions(in text: String, previous: String, from item: ShortID, now: Date = Date()) {
        perform { try linkMentionsRow(in: text, previous: previous, from: item, now: now) }
    }

    func linkMentionsRow(in text: String, previous: String, from item: ShortID, now: Date) throws {
        let before = Set(ShortID.mentions(in: previous))
        for id in ShortID.mentions(in: text) where id != item && !before.contains(id) && itemExists(id) {
            // A typed id only adds a link: one the two items already have (any kind, visible or hidden) is never replaced.
            let (from, to) = ShortID.ordered(item, id)
            guard try db.query("SELECT 1 FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?",
                               Self.pairArgs(from, to), { _ in 1 }).isEmpty else { continue }
            try linkRow(item, id, kind: MentionKinds.kind(store: self, from: item, to: id), madeBy: .manual, actor: .user, now: now)
        }
    }

    static func pairArgs(_ from: ShortID, _ to: ShortID) -> [Any?] {
        [from.kind.rawValue, String(from.number), to.kind.rawValue, String(to.number)]
    }

    /// True for a task, jot or person whose row is deleted. Other kinds count as live (their areas check their own).
    func isDeletedItem(_ id: ShortID) throws -> Bool {
        let table: String
        switch id.kind {
        case .task: table = "cards"
        case .jot: table = "jots"
        case .person: table = "people"
        default: return try ItemCatalog.isDeleted(id, store: self)
        }
        return try db.query("SELECT deleted FROM \(table) WHERE id=?", [id.number]) { DB.int($0, 0) != 0 }.first ?? false
    }
}
