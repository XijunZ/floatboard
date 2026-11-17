import Foundation

/// What a jot is (features §2): one the owner wrote, a task's notes, or a meeting's notes.
public enum JotKind: String, CaseIterable {
    case jot, taskNote = "task_note", meetingNotes = "meeting_notes"
    public var title: String { switch self { case .jot: "Jot"; case .taskNote: "Task note"; case .meetingNotes: "Meeting notes" } }
}

/// One saved capture (`J-n`).
public struct Jot: Identifiable, Equatable {
    public let id: Int64
    public var text: String
    public var kind: JotKind
    public var source: ItemSource
    public var added: Date
    public var updated: Date
    public var deleted: Bool
    public var shortID: ShortID { ShortID(kind: .jot, number: id) }
}

/// One earlier text of a jot and when it was replaced.
public struct JotVersion: Equatable {
    public let text: String
    public let at: Date
}

/// The jots table: the minimal core the Jots tab, Decisions and Circle build on. Every change is one transaction; a
/// failure goes to Activity and changes nothing.
@MainActor public struct JotStore {
    let store: Store
    public init(store: Store) { self.store = store }

    /// Saves a new jot. Empty text saves nothing (nil). Ids typed in it are linked.
    @discardableResult
    public func create(text: String, kind: JotKind = .jot, source: ItemSource = .typed, now: Date = Date()) -> Jot? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var id: Int64?
        store.perform {
            let n = try store.db.run("INSERT INTO jots(text, kind, source, added, updated) VALUES(?,?,?,?,?)",
                                     [text, kind.rawValue, source.rawValue, now, now])
            try store.linkMentionsRow(in: text, previous: "", from: ShortID(kind: .jot, number: n), now: now)
            id = n
        }
        return id.flatMap { jot($0) }
    }

    /// Replaces a jot's text; the previous text goes to its history. Same text: nothing changes (false). Ids newly typed are linked.
    @discardableResult
    public func update(_ id: Int64, text: String, now: Date = Date()) -> Bool {
        var changed = false
        store.perform {
            guard let old = try store.db.query("SELECT text FROM jots WHERE id=? AND deleted=0", [id], { DB.text($0, 0) }).first,
                  old != text else { return }
            try store.db.run("INSERT INTO jot_history(jot_id, text, at) VALUES(?,?,?)", [id, old, now])
            try store.db.run("UPDATE jots SET text=?, updated=? WHERE id=?", [text, now, id])
            try store.linkMentionsRow(in: text, previous: old, from: ShortID(kind: .jot, number: id), now: now)
            changed = true
        }
        return changed
    }

    /// Soft delete: the row and its history stay; its links are hidden until `undoDelete`.
    public func delete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM jots WHERE id=?", [id], { DB.int($0, 0) }).first == 0 else { return }
            try store.db.run("UPDATE jots SET deleted=1, updated=? WHERE id=?", [now, id])
            try store.hideLinks(of: ShortID(kind: .jot, number: id))
        }
    }

    public func undoDelete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM jots WHERE id=?", [id], { DB.int($0, 0) }).first == 1 else { return }
            try store.db.run("UPDATE jots SET deleted=0, updated=? WHERE id=?", [now, id])
            try store.unhideLinks(of: ShortID(kind: .jot, number: id))
        }
    }

    /// Any jot by id, deleted ones too.
    public func jot(_ id: Int64) -> Jot? { read("WHERE id=?", [id]).first }

    /// Jots added in [from, to), newest first.
    public func jots(addedFrom from: Date, to: Date, includeDeleted: Bool = false) -> [Jot] {
        read("WHERE added>=? AND added<?\(includeDeleted ? "" : " AND deleted=0") ORDER BY added DESC, id DESC", [from, to])
    }

    /// The texts a jot had before, oldest first.
    public func history(_ id: Int64) -> [JotVersion] {
        do {
            return try store.db.query("SELECT text, at FROM jot_history WHERE jot_id=? ORDER BY at, id", [id]) {
                JotVersion(text: DB.text($0, 0), at: DB.date($0, 1) ?? Date())
            }
        } catch {
            store.activity("jots", .error, "Could not read a jot's history", detail: "\(error)")
            return []
        }
    }

    private func read(_ tail: String, _ args: [Any?]) -> [Jot] {
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
