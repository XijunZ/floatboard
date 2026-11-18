import Foundation
import SQLite3

/// The goals table and the rules around it. Every change is one transaction; a failure goes to Activity and changes nothing.
@MainActor public struct ResolutionStore {
    let store: Store
    public init(store: Store) { self.store = store }

    /// The most recent jots a goal shows.
    public static let recentJots = 5

    // MARK: Goals

    /// Adds a goal to a period, optionally under a parent. Refused: empty title, a period of another level, a full period
    /// (five-year: any picture overlapping it), or a parent the rules don't allow.
    public func create(level: GoalLevel, period: GoalPeriod, title: String, notes: String = "", parent: Int64? = nil,
                       source: ItemSource = .typed, now: Date = Date()) -> Result<Goal, GoalRefusal> {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(GoalRefusal("A goal needs a few words.")) }
        guard period.level == level else { return .failure(GoalRefusal("\(period.title) isn't a period for a \(level.title.lowercased()).")) }
        if let full = fullRefusal(period) { return .failure(full) }
        if let parent, let r = parentRefusal(level: level, period: period, child: nil, parent: parent) { return .failure(r) }
        var newID: Int64?
        store.perform {
            newID = try insertRow(level: level, period: period, title: t, notes: notes, carriedFrom: nil, source: source, now: now)
            if let parent, let n = newID {
                try store.linkRow(ShortID(kind: .resolution, number: n), ShortID(kind: .resolution, number: parent), kind: .serves,
                                  madeBy: .manual, actor: .user, now: now)
            }
        }
        changed()
        guard let id = newID, let g = goal(id) else { return .failure(GoalRefusal("Could not save the goal; see Activity.")) }
        return .success(g)
    }

    /// Rewords an active goal; the previous wording goes to its history. A reviewed goal stays as it was.
    public func update(_ id: Int64, title: String, notes: String, now: Date = Date()) -> String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let g = goal(id), !g.deleted else { return "There's no R-\(id)." }
        guard g.status == .active else { return "\(g.shortID.text) was reviewed and stays as it was." }
        guard !t.isEmpty else { return "A goal needs a few words." }
        guard t != g.title || notes != g.notes else { return nil }
        store.perform {
            try store.db.run("INSERT INTO resolution_history(goal_id, title, notes, at) VALUES(?,?,?,?)", [id, g.title, g.notes, now])
            try store.db.run("UPDATE resolutions SET title=?, notes=?, updated=? WHERE id=?", [t, notes, now, id])
        }
        changed()
        return nil
    }

    /// Soft delete: the row stays and its links are hidden until `undoDelete`.
    public func delete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM resolutions WHERE id=?", [id], { DB.int($0, 0) }).first == 0 else { return }
            try store.db.run("UPDATE resolutions SET deleted=1, updated=? WHERE id=?", [now, id])
            try store.hideLinks(of: ShortID(kind: .resolution, number: id))
        }
        changed()
    }

    public func undoDelete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM resolutions WHERE id=?", [id], { DB.int($0, 0) }).first == 1 else { return }
            try store.db.run("UPDATE resolutions SET deleted=0, updated=? WHERE id=?", [now, id])
            try store.unhideLinks(of: ShortID(kind: .resolution, number: id))
            // A goal has one parent. A child put under another goal while this one was deleted keeps that later choice:
            // the restored link to this goal goes. Likewise this goal keeps only its newest parent link.
            let me = ShortID(kind: .resolution, number: id)
            for l in store.itemLinks(of: me) where l.other.kind == .resolution && l.kind == .serves {
                let child = l.isSubject ? me : l.other
                let all = store.itemLinks(of: child).filter { $0.other.kind == .resolution && $0.kind == .serves && $0.isSubject }
                guard all.count > 1 else { continue }
                let keep = l.isSubject ? newest(all.map { ($0.other, $0.created) }) : newest(all.filter { $0.other != me }.map { ($0.other, $0.created) })
                for p in all where p.other != keep { try deleteLink(child, p.other) }
            }
        }
        changed()
    }

    /// The most recently made of these links' other ends (a later link is a later choice).
    private func newest(_ links: [(ShortID, Date)]) -> ShortID? { links.max { $0.1 < $1.1 }?.0 }

    /// Any goal by id, deleted ones too.
    public func goal(_ id: Int64) -> Goal? { read("WHERE id=?", [id]).first }

    /// A period's goals in their order (deleted ones left out unless asked for).
    public func goals(in period: GoalPeriod, includeDeleted: Bool = false) -> [Goal] {
        read("WHERE level=? AND period=?\(includeDeleted ? "" : " AND deleted=0") ORDER BY position, id", [period.level.rawValue, period.key])
    }

    /// Every live goal of a level, oldest period first.
    public func goals(level: GoalLevel) -> [Goal] {
        read("WHERE level=? AND deleted=0 ORDER BY period, position, id", [level.rawValue])
    }

    /// The five-year picture in force at `now` (else the latest one).
    public func fiveYear(now: Date = Date()) -> Goal? {
        let all = goals(level: .fiveYear)
        return all.last { $0.period.interval.contains(now) } ?? all.last
    }

    /// Earlier wordings, oldest first.
    public func history(_ id: Int64) -> [GoalVersion] {
        do {
            return try store.db.query("SELECT title, notes, at FROM resolution_history WHERE goal_id=? ORDER BY at, id", [id]) {
                GoalVersion(title: DB.text($0, 0), notes: DB.text($0, 1), at: DB.date($0, 2) ?? Date())
            }
        } catch {
            store.activity("resolutions", .error, "Could not read a goal's history", detail: "\(error)")
            return []
        }
    }

    /// The live goal that carries this one on (made at its review), if any.
    public func continuation(of id: Int64) -> Goal? { read("WHERE carried_from=? AND deleted=0 ORDER BY id", [id]).first }

    /// Active yearly and quarterly goals of this and the next period: what work can be linked to.
    public func linkableGoals(now: Date = Date()) -> [Goal] {
        [GoalLevel.quarter, .year].flatMap { level -> [Goal] in
            let p = GoalPeriod.current(level, now: now)
            return (goals(in: p) + goals(in: p.next)).filter { $0.status == .active }
        }
    }

    // MARK: Parents

    /// Puts a goal under a parent (nil: under none). Quarter → year → five-year only; the parent's period must contain the
    /// child's; one parent per goal; no loops.
    public func setParent(_ child: Int64, _ parent: Int64?, now: Date = Date()) -> String? {
        guard let c = goal(child), !c.deleted else { return "There's no R-\(child)." }
        guard c.status == .active else { return "\(c.shortID.text) was reviewed and stays as it was." }
        if let parent, let r = parentRefusal(level: c.level, period: c.period, child: child, parent: parent) { return r.message }
        store.perform {
            // Every parent link this goal has (visible or hidden by a delete), not just the newest: no stale parent can come back.
            try Self.deleteParentLinksRow(store, child: c.shortID, except: parent.map { ShortID(kind: .resolution, number: $0) })
            if let parent {
                try store.linkRow(c.shortID, ShortID(kind: .resolution, number: parent), kind: .serves, madeBy: .manual, actor: .user, now: now)
            }
        }
        changed()
        return nil
    }

    /// The goal this one sits under.
    public func parent(of id: Int64) -> Goal? {
        parentLinks(of: id).lazy.compactMap { goal($0.number) }.first { !$0.deleted }
    }

    /// The live goals sitting under this one, by period and order.
    public func children(of id: Int64) -> [Goal] {
        store.itemLinks(of: ShortID(kind: .resolution, number: id))
            .filter { $0.other.kind == .resolution && $0.kind == .serves && !$0.isSubject && parentLinks(of: $0.other.number).first?.number == id }
            .compactMap { goal($0.other.number) }.filter { !$0.deleted }
            .sorted { ($0.period.key, $0.position, $0.id) < ($1.period.key, $1.position, $1.id) }
    }

    /// The goal's parent link (the newest one, should more than one ever exist, e.g. a link put back by Undo on its chip).
    private func parentLinks(of id: Int64) -> [ShortID] {
        let all = store.itemLinks(of: ShortID(kind: .resolution, number: id))
            .filter { $0.other.kind == .resolution && $0.kind == .serves && $0.isSubject }
        return newest(all.map { ($0.other, $0.created) }).map { [$0] } ?? []
    }

    private func parentRefusal(level: GoalLevel, period: GoalPeriod, child: Int64?, parent: Int64) -> GoalRefusal? {
        guard let p = goal(parent), !p.deleted else { return GoalRefusal("There's no R-\(parent).") }
        guard level.parentLevel == p.level else {
            return GoalRefusal("A quarterly goal sits under a yearly goal, and a yearly goal under the five-year picture.")
        }
        guard p.period.contains(period) else { return GoalRefusal("\(p.shortID.text) is for \(p.period.title); \(period.title) isn't in it.") }
        if let child {
            // Walk up from the parent: reaching the child would make a loop (links made elsewhere could allow it).
            var seen: Set<Int64> = [], cur: Int64? = parent
            while let n = cur, !seen.contains(n) {
                if n == child { return GoalRefusal("That would make a loop: a goal can't sit under itself.") }
                seen.insert(n)
                cur = parentLinks(of: n).first?.number
            }
        }
        return nil
    }

    // MARK: Work

    /// Links a task, jot or decision to an active yearly or quarterly goal (`serves`, the item as subject, by the owner).
    public func linkWork(_ item: ShortID, to goalID: Int64, now: Date = Date()) -> String? {
        guard [.task, .jot, .decision].contains(item.kind) else { return "Only tasks, jots and decisions can serve a goal." }
        guard let g = goal(goalID), !g.deleted else { return "There's no R-\(goalID)." }
        guard g.level != .fiveYear else { return "Link work to a yearly or quarterly goal; the five-year picture holds goals." }
        guard g.status == .active else { return "\(g.shortID.text) was reviewed; link the work to the goal that carries it on." }
        guard store.itemExists(item) else { return "There's no \(item.text)." }
        store.link(item, g.shortID, kind: .serves, madeBy: .manual, actor: .user, now: now)
        changed()
        return nil
    }

    /// The live goals an item serves.
    public func goals(servedBy item: ShortID) -> [Goal] {
        store.itemLinks(of: item).filter { $0.other.kind == .resolution && $0.kind == .serves && $0.isSubject }
            .compactMap { goal($0.other.number) }.filter { !$0.deleted }
    }

    /// The items (not goals) linked as serving this goal itself.
    public func work(of id: Int64) -> [ShortID] {
        store.itemLinks(of: ShortID(kind: .resolution, number: id))
            .filter { $0.kind == .serves && !$0.isSubject && $0.other.kind != .resolution }.map(\.other)
    }

    /// This goal and every live goal under it, at any depth.
    private func withDescendants(_ id: Int64) -> [Int64] {
        var out: [Int64] = [], queue = [id]
        while let n = queue.first {
            queue.removeFirst()
            guard !out.contains(n) else { continue }
            out.append(n)
            queue += children(of: n).map(\.id)
        }
        return out
    }

    /// Done and open tasks, recent jots and decisions. A yearly goal counts its own and its quarterly goals' items, each once.
    public func progress(_ id: Int64) -> GoalProgress {
        var items = Set<ShortID>()
        for g in withDescendants(id) { items.formUnion(work(of: g)) }
        let tasks = items.filter { $0.kind == .task }.map(\.number)
        var done: [Int64] = [], open: [Int64] = []
        if !tasks.isEmpty {
            do {
                let marks = tasks.map { _ in "?" }.joined(separator: ",")
                let rows = try store.db.query("SELECT id, status FROM cards WHERE id IN (\(marks)) AND deleted=0 AND withdrawn=0 ORDER BY id",
                                              tasks.map { $0 as Any? }) { (DB.int($0, 0), DB.text($0, 1)) }
                done = rows.filter { $0.1 == Status.done.rawValue }.map(\.0)
                open = rows.filter { $0.1 != Status.done.rawValue }.map(\.0)
            } catch {
                store.activity("resolutions", .error, "Could not read a goal's tasks", detail: "\(error)")
            }
        }
        let jotStore = JotStore(store: store)
        let jots = items.filter { $0.kind == .jot }.compactMap { jotStore.jot($0.number) }.filter { !$0.deleted }
            .sorted { ($0.updated, $0.id) > ($1.updated, $1.id) }.prefix(Self.recentJots).map(\.shortID)
        let decisions = items.filter { $0.kind == .decision && store.item($0)?.deleted != true }.sorted { $0.number > $1.number }
        return GoalProgress(done: done, open: open, jots: Array(jots), decisions: decisions)
    }

    /// The tasks the board shows when filtered by this goal (R5): done and open, its own and its sub-goals', each once.
    public func taskIDs(for id: Int64) -> Set<Int64> {
        let p = progress(id)
        return Set(p.done + p.open)
    }

    // MARK: Review and rollover

    /// Reviews an active goal (R4): it becomes kept, changed or dropped and is read-only from then on. Kept and changed
    /// carry on as a new goal in the next period (changed with `newTitle`), with its tags, its parent when that still
    /// covers the new period (else the parent's own continuation), and its open tasks. A note is saved as a jot linked
    /// `review-of` to the goal. Returns the new goal (nil when dropped).
    public func review(_ id: Int64, outcome: ReviewOutcome, note: String, newTitle: String?, now: Date = Date()) -> Result<Goal?, GoalRefusal> {
        guard let g = goal(id), !g.deleted else { return .failure(GoalRefusal("There's no R-\(id).")) }
        guard g.status == .active else { return .failure(GoalRefusal("\(g.shortID.text) was already reviewed.")) }
        guard g.level != .fiveYear else { return .failure(GoalRefusal("The five-year picture is rewritten, not reviewed.")) }
        let wording = (outcome == .changed ? newTitle ?? "" : g.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wording.isEmpty else { return .failure(GoalRefusal("Write the new wording for the changed goal.")) }
        let np = rolloverPeriod(of: g.period, now: now)
        var newParent: Int64?
        if outcome != .dropped {
            if let full = fullRefusal(np) { return .failure(GoalRefusal(full.message + " Make room there first, or drop this goal.")) }
            if let p = parent(of: id) {
                if p.period.contains(np) { newParent = p.id }
                else if let pc = continuation(of: p.id), pc.period.contains(np) { newParent = pc.id }
            }
        }
        // The note first, so it is never lost even if the rest fails (the jot then says what was decided).
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            let head = "Review of “\(g.title)” (\(g.period.title)): \(outcome.title.lowercased())"
                + (outcome == .changed ? " to “\(wording)”" : "")
            // The review-of link is made with the jot, before ids typed in the note (even this goal's own) are linked.
            guard JotStore(store: store).create(text: head + "\n\n" + trimmedNote, kind: .jot, source: .typed, now: now,
                                                linkFirst: [(g.shortID, .reviewOf, .auto)]) != nil else {
                return .failure(GoalRefusal("Could not save the review note; see Activity."))
            }
        }
        let openTasks = Set(progressOwnOpenTasks(id))
        // Goals of the new period with no parent yet whose chain of earlier versions (carried on, perhaps several times,
        // before this review) goes back to one that sat under this goal: they move under this goal's continuation, reviewed
        // ones too (their ancestry, not their content, is completed).
        let adopt = outcome == .dropped ? [] : GoalLevel.allCases.filter { $0.parentLevel == g.level }
            .flatMap { goals(level: $0) }
            .filter { c in np.contains(c.period) && parent(of: c.id) == nil && chainParent(c) == id }
        var newID: Int64?
        store.perform {
            try store.db.run("UPDATE resolutions SET status=?, reviewed=?, updated=? WHERE id=?", [outcome.status.rawValue, now, now, id])
            if outcome != .dropped {
                let n = try insertRow(level: g.level, period: np, title: wording, notes: g.notes, carriedFrom: id, source: g.source, now: now)
                let new = ShortID(kind: .resolution, number: n)
                try store.db.run("""
                    INSERT OR IGNORE INTO item_tags(item, tag_id, is_primary, added) SELECT ?, tag_id, is_primary, ? FROM item_tags WHERE item=?
                    """, [new.text, now, g.shortID.text])
                if let newParent { try store.linkRow(new, ShortID(kind: .resolution, number: newParent), kind: .serves, madeBy: .auto, actor: .user, now: now) }
                for c in adopt {
                    try store.linkRow(c.shortID, new, kind: .serves, madeBy: .auto, actor: .user, now: now)
                }
                for t in openTasks.sorted() {
                    try store.linkRow(ShortID(kind: .task, number: t), new, kind: .serves, madeBy: .auto, actor: .user, now: now)
                }
                newID = n
            }
        }
        changed()
        guard goal(id)?.status == outcome.status else { return .failure(GoalRefusal("Could not save the review; see Activity.")) }
        return .success(newID.flatMap { goal($0) })
    }

    /// Where a kept or changed goal of `period` carries on when reviewed at `now`: the next period, or, for a review made
    /// late (the next period is already over), the current period of that level.
    public func rolloverPeriod(of period: GoalPeriod, now: Date) -> GoalPeriod {
        let cur = GoalPeriod.current(period.level, now: now)
        return period.next.interval.start >= cur.interval.start ? period.next : cur
    }

    /// Walking back through the goals this one carries on (`carried_from`), the parent of the first one that has a parent.
    private func chainParent(_ g: Goal) -> Int64? {
        var seen: Set<Int64> = [g.id], cur = g.carriedFrom
        while let n = cur, !seen.contains(n), let prev = goal(n) {
            if let p = parentLinks(of: n).first { return p.number }
            seen.insert(n)
            cur = prev.carriedFrom
        }
        return nil
    }

    /// The open tasks linked to this goal itself (not its sub-goals): what follows a kept goal into the next period.
    private func progressOwnOpenTasks(_ id: Int64) -> [Int64] {
        let own = Set(work(of: id).filter { $0.kind == .task }.map(\.number))
        return progress(id).open.filter(own.contains)
    }

    /// The review notes saved for a goal (jots linked `review-of`), newest first.
    public func reviewNotes(_ id: Int64) -> [Jot] {
        let jots = JotStore(store: store)
        return store.itemLinks(of: ShortID(kind: .resolution, number: id)).filter { $0.kind == .reviewOf && !$0.isSubject && $0.other.kind == .jot }
            .compactMap { jots.jot($0.other.number) }.filter { !$0.deleted }.sorted { $0.added > $1.added }
    }

    // MARK: Rows

    private func fullRefusal(_ period: GoalPeriod) -> GoalRefusal? {
        if period.level == .fiveYear {
            if let other = goals(level: .fiveYear).first(where: { $0.period.interval.intersects(period.interval) && $0.period.interval.end != period.interval.start
                                                                   && period.interval.end != $0.period.interval.start }) {
                return GoalRefusal("There's already a five-year picture for \(other.period.title) (\(other.shortID.text)); rewrite that one.")
            }
            return nil
        }
        let n = goals(in: period).count
        guard n >= period.level.limit else { return nil }
        return GoalRefusal("\(period.title) already has \(n) \(period.level == .quarter ? "quarterly" : "yearly") goals; keep it light.")
    }

    private func insertRow(level: GoalLevel, period: GoalPeriod, title: String, notes: String, carriedFrom: Int64?, source: ItemSource,
                           now: Date) throws -> Int64 {
        let pos = (try store.db.query("SELECT max(position) FROM resolutions WHERE level=? AND period=?", [level.rawValue, period.key]) {
            DB.isNull($0, 0) ? 0 : sqlite3_column_double($0, 0) }.first ?? 0) + 1
        return try store.db.run("""
            INSERT INTO resolutions(level, period, title, notes, status, carried_from, position, source, added, updated) VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [level.rawValue, period.key, title, notes, GoalStatus.active.rawValue, carriedFrom, pos, source.rawValue, now, now])
    }

    /// Deletes every `serves` link from goal `child` (as subject) to another goal, except the one to `except`. One parent per
    /// goal; used by setParent and by Undo of a ✕ that brings a parent back (inside the caller's transaction).
    static func deleteParentLinksRow(_ store: Store, child: ShortID, except: ShortID?) throws {
        let c = String(child.number)
        let rows = try store.db.query("""
            SELECT from_type, from_id, to_type, to_id FROM links WHERE kind='serves' AND subject=? AND from_type='R' AND to_type='R'
            AND (from_id=? OR to_id=?)
            """, [child.text, c, c]) { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2), DB.text($0, 3)) }
        for r in rows {
            let other = r.1 == c ? r.3 : r.1
            if let except, other == String(except.number) { continue }
            try store.db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", [r.0, r.1, r.2, r.3])
        }
    }

    private func deleteLink(_ a: ShortID, _ b: ShortID) throws {
        let (from, to) = ShortID.ordered(a, b)
        try store.db.run("DELETE FROM links WHERE from_type=? AND from_id=? AND to_type=? AND to_id=?", Store.pairArgs(from, to))
    }

    private func changed() { store.objectWillChange.send() }

    private func read(_ tail: String, _ args: [Any?]) -> [Goal] {
        do {
            return try store.db.query("""
                SELECT id, level, period, title, notes, status, carried_from, position, source, added, updated, reviewed, deleted FROM resolutions \(tail)
                """, args) { s -> Goal? in
                guard let level = GoalLevel(rawValue: DB.text(s, 1)), let period = GoalPeriod.parse(level: level, key: DB.text(s, 2)) else { return nil }
                return Goal(id: DB.int(s, 0), level: level, period: period, title: DB.text(s, 3), notes: DB.text(s, 4),
                            status: GoalStatus(rawValue: DB.text(s, 5)) ?? .active, carriedFrom: DB.isNull(s, 6) ? nil : DB.int(s, 6),
                            position: sqlite3_column_double(s, 7), source: ItemSource(rawValue: DB.text(s, 8)) ?? .typed,
                            added: DB.date(s, 9) ?? Date(), updated: DB.date(s, 10) ?? Date(), reviewed: DB.date(s, 11), deleted: DB.int(s, 12) != 0)
            }.compactMap { $0 }
        } catch {
            store.activity("resolutions", .error, "Could not read goals", detail: "\(error)")
            return []
        }
    }
}
