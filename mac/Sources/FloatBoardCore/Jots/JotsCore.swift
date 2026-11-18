import Foundation

/// How the Jots tab orders its list (features: ground rules: by date added, date updated or tag).
public enum JotSort: String, CaseIterable {
    case added, updated, tag
    public var title: String { switch self { case .added: "Date added"; case .updated: "Date updated"; case .tag: "Tag" } }
}

/// What the Jots tab shows: search words (in the text or the tags; or a typed `J-n`), tags (any), kinds, and the order.
public struct JotQuery: Equatable {
    public var text = ""
    public var tags: Set<String> = []
    public var kinds: Set<JotKind> = []
    public var sort: JotSort = .added
    public var limit = 500
    /// Only jots with no tags (shown as "untagged").
    public var untagged = false
    public init(text: String = "", tags: Set<String> = [], kinds: Set<JotKind> = [], sort: JotSort = .added, limit: Int = 500, untagged: Bool = false) {
        self.text = text; self.tags = tags; self.kinds = kinds; self.sort = sort; self.limit = limit; self.untagged = untagged
    }
}

/// A jot as listed: the jot and its tags (primary first).
public struct JotRow: Identifiable, Equatable {
    public let jot: Jot
    public let tags: ItemTags
    public var id: Int64 { jot.id }
    public var untagged: Bool { tags.all.isEmpty }
}

/// The Jots area's additions to the foundation's JotStore (docs/superpowers/specs/2026-11-17-jots-design.md §2).
extension JotStore {
    /// Saves a new jot with where it came from (`origin`, unique: a repeat returns the jot already saved), its task (a task
    /// note) and its tags (the first is primary; unknown names are left out), in one transaction. Ids typed in it are linked.
    @discardableResult
    public func add(_ text: String, kind: JotKind = .jot, source: ItemSource = .typed, origin: String = "", taskID: Int64? = nil,
                    tags: [String] = [], now: Date = Date()) -> Jot? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !origin.isEmpty, let existing = jot(origin: origin) { return existing }
        var id: Int64?
        store.perform { id = try addRow(text, kind: kind, source: source, origin: origin, taskID: taskID, tags: tags, now: now) }
        return id.flatMap { jot($0) }
    }

    /// The body of `add`, for callers inside a transaction.
    func addRow(_ text: String, kind: JotKind, source: ItemSource, origin: String, taskID: Int64?, tags: [String], now: Date) throws -> Int64 {
        let n = try store.db.run("INSERT INTO jots(text, kind, source, added, updated, task_id, origin) VALUES(?,?,?,?,?,?,?)",
                                 [text, kind.rawValue, source.rawValue, now, now, taskID, origin])
        let me = ShortID(kind: .jot, number: n)
        try store.linkMentionsRow(in: text, previous: "", from: me, now: now)
        let known = store.knownTags(tags)
        if let p = known.first { try store.setTagsRow(me, primary: p, others: Array(known.dropFirst()), now: now) }
        return n
    }

    /// The capture window's save (J1, J8): a typed or dictated jot; "about" a task, it takes the task's tags and is linked to it.
    @discardableResult
    public func capture(_ text: String, aboutTask task: Int64? = nil, now: Date = Date()) -> Jot? {
        let tags = task.map { store.itemTags(ShortID(kind: .task, number: $0)).all } ?? []
        guard let jot = add(text, tags: tags, now: now) else { return nil }
        if let t = task { store.link(jot.shortID, ShortID(kind: .task, number: t), kind: .related, madeBy: .manual, actor: .user, now: now) }
        return jot
    }

    /// Puts texts the engine kept (earlier phone versions) into a jot's history, oldest first; a text equal to the jot's current
    /// one or already in its history is not added twice.
    public func keepInHistory(_ id: Int64, _ texts: [EarlierText]) {
        store.perform { try keepInHistoryRow(id, texts) }
    }

    /// The body of `keepInHistory`, inside the caller's transaction; throws on any failure (never swallowed).
    func keepInHistoryRow(_ id: Int64, _ texts: [EarlierText]) throws {
        guard !texts.isEmpty, let current = try store.db.query("SELECT text FROM jots WHERE id=?", [id], { DB.text($0, 0) }).first else { return }
        var have = Set(try store.db.query("SELECT text FROM jot_history WHERE jot_id=?", [id]) { DB.text($0, 0) } + [current])
        for t in texts.sorted(by: { $0.at < $1.at }) where !have.contains(t.text) {
            try store.db.run("INSERT INTO jot_history(jot_id, text, at) VALUES(?,?,?)", [id, t.text, t.at])
            have.insert(t.text)
        }
    }

    /// The jot that arrived with this engine key, if any (deleted ones too).
    /// The id of the jot saved under this origin key, nil when none; throws when it can't be read.
    public func jotIDOrThrow(origin: String) throws -> Int64? {
        guard !origin.isEmpty else { return nil }
        return try store.db.query("SELECT id FROM jots WHERE origin=?", [origin]) { DB.int($0, 0) }.first
    }

    public func jot(origin: String) -> Jot? {
        guard !origin.isEmpty else { return nil }
        let id = (try? store.db.query("SELECT id FROM jots WHERE origin=?", [origin]) { DB.int($0, 0) })?.first // try?-ok: unreadable = not found; the caller saves it again under its unique key, which the database refuses
        return id.flatMap { jot($0) }
    }

    /// Replaces a jot's tags: the first is primary. Unknown names are refused (the reason comes back). A change counts as an
    /// update of the jot (its date updated moves, and the online copy gets the new tags).
    @discardableResult
    public func setTags(_ id: Int64, _ tags: [String], now: Date = Date()) -> String? {
        let me = ShortID(kind: .jot, number: id)
        let before = store.itemTags(me).all
        if let why = store.setTags(me, primary: tags.first, others: Array(tags.dropFirst()), now: now) { return why }
        if store.itemTags(me).all != before { store.perform { try store.db.run("UPDATE jots SET updated=? WHERE id=?", [now, id]) } }
        return nil
    }

    /// Jots for the list: not deleted, matching the query, in its order.
    public func list(_ q: JotQuery) -> [JotRow] {
        let words = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = "WHERE deleted=0"
        var args: [Any?] = []
        if let id = ShortID.parse(words), id.kind == .jot { sql += " AND id=?"; args.append(id.number) }
        if !q.kinds.isEmpty {
            sql += " AND kind IN (" + q.kinds.map { _ in "?" }.joined(separator: ",") + ")"
            args += q.kinds.map(\.rawValue).sorted()
        }
        sql += q.sort == .updated ? " ORDER BY updated DESC, id DESC" : " ORDER BY added DESC, id DESC"
        let isID = ShortID.parse(words)?.kind == .jot
        var out: [JotRow] = []
        for j in rows(sql, args) {
            let tags = store.itemTags(j.shortID)
            if !words.isEmpty && !isID && !GlobalSearch.matches(j.text + " " + tags.all.joined(separator: " "), words) { continue }
            if !TagFilter.matches(tags, any: q.tags) || (q.untagged && !tags.all.isEmpty) { continue }
            out.append(JotRow(jot: j, tags: tags))
            if out.count >= q.limit && q.sort != .tag { break }
        }
        if q.sort == .tag {
            // By primary tag (A–Z, untagged last), newest first within a tag.
            out.sort { a, b in
                let ta = a.tags.primary?.lowercased() ?? "\u{10FFFF}", tb = b.tags.primary?.lowercased() ?? "\u{10FFFF}"
                return ta != tb ? ta < tb : (a.jot.added, a.id) > (b.jot.added, b.id)
            }
            out = Array(out.prefix(q.limit))
        }
        return out
    }

    /// The task note of a task (not deleted), if it has one.
    public func taskNote(forTask taskID: Int64) -> Jot? {
        let id = (try? store.db.query("SELECT id FROM jots WHERE task_id=? AND kind='task_note' AND deleted=0 ORDER BY id DESC LIMIT 1", [taskID]) { // try?-ok: unreadable = no note jot; the task's notes still show
            DB.int($0, 0) })?.first
        return id.flatMap { jot($0) }
    }

    /// The task a task note belongs to (also when that task was deleted).
    public func taskID(ofNote id: Int64) -> Int64? {
        let v = (try? store.db.query("SELECT task_id FROM jots WHERE id=?", [id]) { DB.isNull($0, 0) ? nil : DB.int($0, 0) })?.first // try?-ok: unknown = no task shown
        return v ?? nil
    }

    /// True when a jot the owner wrote (typed, dictated or on the phone; not meeting or task notes) was added on `now`'s day.
    public func ownJotAdded(on now: Date) -> Bool {
        guard let day = AppTime.calendar.dateInterval(of: .day, for: now) else { return false }
        return jots(addedFrom: day.start, to: day.end).contains { $0.kind == .jot && ($0.source == .typed || $0.source == .phone) }
    }

    /// Restores an earlier text: saved as an edit, so the current text goes to the history and can be restored the same way.
    @discardableResult
    public func restore(_ id: Int64, to version: JotVersion, now: Date = Date()) -> Bool { update(id, text: version.text, now: now) }

    /// Jots changed (added, edited, deleted or restored) since `date`, deleted ones too.
    public func changed(since date: Date) -> [Jot] { rows("WHERE updated>? ORDER BY updated", [date]) }

    /// Jots written on this Mac after write-order mark `seq` (`lastChangeSeq`), whatever their own times say.
    public func changed(afterSeq seq: Int64) -> [Jot] { rows("WHERE change_seq>? ORDER BY change_seq", [seq]) }

    /// The newest write-order mark (0 with no jots); nil when it can't be read.
    public func lastChangeSeq() -> Int64 {
        do { return try store.db.query("SELECT coalesce(max(change_seq), 0) FROM jots") { DB.int($0, 0) }.first ?? 0 } catch {
            store.activity("jots", .error, "Could not read the jots' change order", detail: "\(error)")
            return 0
        }
    }

    func rows(_ tail: String, _ args: [Any?]) -> [Jot] {
        do {
            return try store.db.query("SELECT id, text, kind, source, added, updated, deleted FROM jots \(tail)", args) { s in
                Jot(id: DB.int(s, 0), text: DB.text(s, 1), kind: JotKind(rawValue: DB.text(s, 2)) ?? .jot,
                    source: ItemSource(rawValue: DB.text(s, 3)) ?? .typed, added: DB.date(s, 4) ?? Date(), updated: DB.date(s, 5) ?? Date(),
                    deleted: DB.int(s, 6) != 0)
            }
        } catch {
            store.activity("jots", .error, "Could not read jots", detail: "\(error)")
            return []
        }
    }
}

extension Store {
    /// The names that are tags here (canonical spelling), each once, in the given order.
    func knownTags(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            guard let t = tags.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }),
                  !out.contains(where: { $0.caseInsensitiveCompare(t.name) == .orderedSame }) else { continue }
            out.append(t.name)
        }
        return out
    }
}
