import Foundation

/// What the task form opens with after "Make task" on a selection.
public struct TaskDraft: Equatable {
    public var title: String
    public var notes: String
    public var primaryTag: String?
    public var others: [String]
    public init(title: String, notes: String, primaryTag: String?, others: [String]) {
        self.title = title; self.notes = notes; self.primaryTag = primaryTag; self.others = others
    }
}

/// Make task from selected text (features: ground rules, J7): by code, no AI. The title is the selection's first line (at
/// most 120 characters); the notes hold the whole selection when it is longer than the title; the tags are the source's.
public enum MakeTask {
    public static let titleLimit = 120

    public static func draft(selection: String, sourceTags: ItemTags?, groups: [String]) -> TaskDraft {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = ItemCatalog.firstLineText(text)
        if title.count > titleLimit { title = String(title.prefix(titleLimit - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        let notes = text == title ? "" : text
        let isGroup = { (t: String) in groups.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        let all = sourceTags?.all ?? []
        let primary = all.first(where: isGroup) ?? groups.first
        return TaskDraft(title: title, notes: notes, primaryTag: primary,
                         others: all.filter { $0.caseInsensitiveCompare(primary ?? "") != .orderedSame })
    }
}

extension ItemCatalog {
    /// The first non-empty line, unclipped.
    nonisolated static func firstLineText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

extension Store {
    /// Creates a typed task from a draft, with its tags and a `source` link to where the text came from (manual).
    /// Returns its id, or nil when the title is empty or the write failed.
    @discardableResult
    public func makeTask(_ d: TaskDraft, due: Date?, dueHasTime: Bool, from source: ShortID?, now: Date = Date()) -> Int64? {
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let group = resolve(d.primaryTag ?? "")
        let due = Due.stored(due, hasTime: dueHasTime)
        var id: Int64?
        perform {
            let n = try db.run("""
                INSERT INTO cards(title,notes,area,importance,due,due_day,due_has_time,status,created,updated) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, [title, d.notes, group, Importance.medium.rawValue, due.due, due.day, due.hasTime, Status.todo.rawValue, now, now])
            try insertEvent(n, "created", to: .todo, actor: .user, at: now)
            let me = ShortID(kind: .task, number: n)
            if let source { try linkRow(me, source, kind: .source, madeBy: .manual, actor: .user, now: now) }
            try linkMentionsRow(in: d.notes, previous: "", from: me, now: now)
            id = n
        }
        guard let id else { return nil }
        let others = d.others.filter { o in tags.contains { $0.name.caseInsensitiveCompare(o) == .orderedSame } }
        if !others.isEmpty { setTags(ShortID(kind: .task, number: id), primary: group, others: others, now: now) }
        return id
    }
}
