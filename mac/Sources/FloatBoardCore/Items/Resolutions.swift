import Foundation
import SQLite3

// Resolutions (features §5, §9; docs/superpowers/specs/2026-11-17-resolutions-design.md): a five-year picture, yearly and
// quarterly goals (`R-n`), work linked to them with `serves`, progress counted by code, and a review at each period's end.

/// A goal's level: the five-year picture (a few lines), a yearly goal or a quarterly goal.
public enum GoalLevel: String, CaseIterable {
    case fiveYear = "five_year", year, quarter
    /// Live goals one period can hold (R1).
    public var limit: Int { switch self { case .fiveYear: 1; case .year: 5; case .quarter: 3 } }
    public var title: String { switch self { case .fiveYear: "Five-year picture"; case .year: "Yearly goal"; case .quarter: "Quarterly goal" } }
    /// The level a goal of this level may sit under.
    public var parentLevel: GoalLevel? { switch self { case .quarter: .year; case .year: .fiveYear; case .fiveYear: nil } }
}

/// The period a goal belongs to: a quarter ("2027-Q1", shown "Q1 2027"), a year ("2027") or five years from a start year
/// ("2026-2030", shown "2026–2030"). Dates are worked out in the app's zone.
public struct GoalPeriod: Hashable {
    public let level: GoalLevel
    let year: Int
    /// 1–4 for a quarter, 0 otherwise.
    let quarter: Int

    init(level: GoalLevel, year: Int, quarter: Int = 0) { self.level = level; self.year = year; self.quarter = level == .quarter ? quarter : 0 }

    /// The period of this level that `now` falls in (a five-year picture starts in the current year).
    public static func current(_ level: GoalLevel, now: Date) -> GoalPeriod {
        let c = AppTime.calendar.dateComponents([.year, .month], from: now)
        let y = c.year ?? 2000
        return GoalPeriod(level: level, year: y, quarter: ((c.month ?? 1) - 1) / 3 + 1)
    }

    /// "2027-Q1" (quarter), "2027" (year), "2026-2030" (five years); nil when the key doesn't fit the level.
    public static func parse(level: GoalLevel, key: String) -> GoalPeriod? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let y = Int(parts.first ?? ""), (1900...9999).contains(y) else { return nil }
        switch level {
        case .year: return parts.count == 1 ? GoalPeriod(level: .year, year: y) : nil
        case .quarter:
            guard parts.count == 2, parts[1].count == 2, parts[1].hasPrefix("Q"), let q = Int(parts[1].dropFirst()), (1...4).contains(q) else { return nil }
            return GoalPeriod(level: .quarter, year: y, quarter: q)
        case .fiveYear:
            return parts.count == 2 && Int(parts[1]) == y + 4 ? GoalPeriod(level: .fiveYear, year: y) : nil
        }
    }

    public var key: String {
        switch level { case .quarter: "\(year)-Q\(quarter)"; case .year: "\(year)"; case .fiveYear: "\(year)-\(year + 4)" }
    }

    public var title: String {
        switch level { case .quarter: "Q\(quarter) \(year)"; case .year: "\(year)"; case .fiveYear: "\(year)–\(year + 4)" }
    }

    /// From the first day of the period to the first day after it, midnight in the app's zone.
    public var interval: DateInterval {
        let cal = AppTime.calendar
        let month = level == .quarter ? (quarter - 1) * 3 + 1 : 1
        let start = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let months = level == .quarter ? 3 : level == .year ? 12 : 60
        return DateInterval(start: start, end: cal.date(byAdding: .month, value: months, to: start) ?? start)
    }

    public var next: GoalPeriod {
        switch level {
        case .quarter: quarter == 4 ? GoalPeriod(level: .quarter, year: year + 1, quarter: 1) : GoalPeriod(level: .quarter, year: year, quarter: quarter + 1)
        case .year: GoalPeriod(level: .year, year: year + 1)
        case .fiveYear: GoalPeriod(level: .fiveYear, year: year + 5)
        }
    }

    public var previous: GoalPeriod {
        switch level {
        case .quarter: quarter == 1 ? GoalPeriod(level: .quarter, year: year - 1, quarter: 4) : GoalPeriod(level: .quarter, year: year, quarter: quarter - 1)
        case .year: GoalPeriod(level: .year, year: year - 1)
        case .fiveYear: GoalPeriod(level: .fiveYear, year: year - 5)
        }
    }

    /// True when `other` lies wholly inside this period (a year contains its quarters).
    public func contains(_ other: GoalPeriod) -> Bool {
        interval.start <= other.interval.start && other.interval.end <= interval.end
    }
}

/// Where a goal stands: active, or how its review ended. A reviewed goal is never edited again.
public enum GoalStatus: String, CaseIterable {
    case active, kept, changed, dropped
    public var title: String { switch self { case .active: "Active"; case .kept: "Kept"; case .changed: "Changed"; case .dropped: "Dropped" } }
}

/// What the review decided for a goal.
public enum ReviewOutcome: String, CaseIterable {
    case kept, changed, dropped
    public var status: GoalStatus { GoalStatus(rawValue: rawValue) ?? .active }
    public var title: String { status.title }
}

/// One goal (`R-n`).
public struct Goal: Identifiable, Equatable {
    public let id: Int64
    public var level: GoalLevel
    public var period: GoalPeriod
    public var title: String
    public var notes: String
    public var status: GoalStatus
    /// The goal of the previous period this one carries on.
    public var carriedFrom: Int64?
    public var position: Double
    public var source: ItemSource
    public var added: Date
    public var updated: Date
    public var reviewed: Date?
    public var deleted: Bool
    public var shortID: ShortID { ShortID(kind: .resolution, number: id) }
    /// True for an active goal whose period has ended: it still waits for its review (which stays possible however late).
    public func reviewOverdue(now: Date) -> Bool { status == .active && level != .fiveYear && now >= period.interval.end }
}

/// An earlier wording of a goal.
public struct GoalVersion: Equatable {
    public let title: String
    public let notes: String
    public let at: Date
}

/// Why a change to goals was refused, worded for the owner.
public struct GoalRefusal: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// A goal's progress, without scoring (R3): its tasks done and open (card ids), its recent jots and its decisions.
public struct GoalProgress: Equatable {
    public var done: [Int64]
    public var open: [Int64]
    public var jots: [ShortID]
    public var decisions: [ShortID]
    public init(done: [Int64], open: [Int64], jots: [ShortID], decisions: [ShortID]) {
        self.done = done; self.open = open; self.jots = jots; self.decisions = decisions
    }

    /// "3 done · 2 open · 1 jot · 1 decision"; "Nothing linked yet" when empty. Counts only, no percentages.
    public var summary: String {
        var parts: [String] = []
        if !done.isEmpty || !open.isEmpty { parts += ["\(done.count) done", "\(open.count) open"] }
        if !jots.isEmpty { parts.append("\(jots.count) jot\(jots.count == 1 ? "" : "s")") }
        if !decisions.isEmpty { parts.append("\(decisions.count) decision\(decisions.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing linked yet" : parts.joined(separator: " · ")
    }
}

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

// MARK: Registration, phone copy

/// Hooks the Resolutions area into the shared registries: ids (`R-n`), search, and typed ids that serve a goal.
public enum Resolutions {
    @MainActor public static func register() {
        ItemCatalog.register(.resolution) { store, n in
            ResolutionStore(store: store).goal(n).map {
                ItemSummary(id: $0.shortID, title: ItemCatalog.firstLine($0.title), added: $0.added, updated: $0.updated, source: $0.source, deleted: $0.deleted)
            }
        }
        GlobalSearch.register(.resolution, module: .resolutions) { store, q in
            let r = ResolutionStore(store: store)
            return GoalLevel.allCases.flatMap { r.goals(level: $0) }
                .filter { GlobalSearch.matches($0.title + " " + $0.notes + " " + $0.period.title, q) }
                .sorted(by: searchOrder)
                .map { SearchHit(id: $0.shortID, title: ItemCatalog.firstLine($0.title),
                                 detail: "\($0.level.title) · \($0.period.title)" + ($0.status == .active ? "" : " · \($0.status.title.lowercased())"),
                                 date: $0.added) }
        }
        MentionKinds.register(.resolution) { store, from, to in
            guard [.task, .jot, .decision].contains(from.kind), let g = ResolutionStore(store: store).goal(to.number),
                  !g.deleted, g.status == .active, g.level != .fiveYear else { return nil }
            return .serves
        }
    }

    /// Active goals first, then the newest period first.
    private static func searchOrder(_ a: Goal, _ b: Goal) -> Bool {
        let ra = a.status == .active ? 0 : 1, rb = b.status == .active ? 0 : 1
        if ra != rb { return ra < rb }
        if a.period.interval.start != b.period.interval.start { return a.period.interval.start > b.period.interval.start }
        return a.id < b.id
    }

    /// This quarter's goals for the phone (More › Resolutions); nil while the area is off.
    @MainActor public static func phoneGoals(store: Store, now: Date) -> [BoardGoal]? {
        guard store.isOn(.resolutions) else { return nil }
        let r = ResolutionStore(store: store)
        let period = GoalPeriod.current(.quarter, now: now)
        return r.goals(in: period).prefix(GoalLevel.quarter.limit).map { g in
            let p = r.progress(g.id)
            return BoardGoal(id: g.shortID.text, title: PhoneBoard.clip(g.title), period: period.title,
                             parent: r.parent(of: g.id).map { PhoneBoard.clip("\($0.shortID.text) · \(ItemCatalog.firstLine($0.title))") },
                             done: p.done.count, open: p.open.count, tasks: Array(p.open.prefix(50)))
        }
    }
}

// MARK: Review nudges

/// The quarterly and yearly review nudges (R4, §9): outside the reminder budget, at most one per period each, never in quiet
/// hours, only while the area is on and the ending period still has active goals.
public enum ResolutionNudges {
    public struct Due: Equatable {
        public let level: GoalLevel
        public let period: GoalPeriod
    }
    /// The review is open from 14 days before a period ends until 21 days into the next.
    public static let daysBefore = 14
    public static let daysAfter = 21

    static func nudgedKey(_ level: GoalLevel) -> String { "resolutions_nudged_\(level.rawValue)" }

    /// The period of this level whose review is open at `now`, if any.
    public static func reviewPeriod(_ level: GoalLevel, now: Date) -> GoalPeriod? {
        let cal = AppTime.calendar
        let cur = GoalPeriod.current(level, now: now)
        if let from = cal.date(byAdding: .day, value: -daysBefore, to: cur.interval.end), now >= from { return cur }
        let prev = cur.previous
        if let until = cal.date(byAdding: .day, value: daysAfter, to: prev.interval.end), now < until { return prev }
        return nil
    }

    /// Reviews in their window at `now` whose period still has an active goal (quarter first): the ones nudged.
    @MainActor static func windowReviews(store: Store, now: Date) -> [GoalPeriod] {
        guard store.isOn(.resolutions) else { return [] }
        let r = ResolutionStore(store: store)
        return [GoalLevel.quarter, .year].compactMap { reviewPeriod($0, now: now) }
            .filter { p in r.goals(in: p).contains { $0.status == .active } }
    }

    /// Every review that can be done at `now`: those in their window (quarter first), then any ended period that still has
    /// an active goal because its window was missed (overdue, oldest first). Never closed until done.
    @MainActor public static func openReviews(store: Store, now: Date) -> [GoalPeriod] {
        let window = windowReviews(store: store, now: now)
        guard store.isOn(.resolutions) else { return [] }
        let r = ResolutionStore(store: store)
        var overdue: [GoalPeriod] = []
        for level in [GoalLevel.quarter, .year] {
            for g in r.goals(level: level) where g.reviewOverdue(now: now) && !window.contains(g.period) && !overdue.contains(g.period) {
                overdue.append(g.period)
            }
        }
        return window + overdue.sorted { ($0.interval.start, $0.level == .quarter ? 0 : 1) < ($1.interval.start, $1.level == .quarter ? 0 : 1) }
    }

    /// The first open review (the Resolutions tab's banner).
    @MainActor public static func openReview(store: Store, now: Date) -> GoalPeriod? { openReviews(store: store, now: now).first }

    /// Nudges to give now: open reviews not nudged for their period yet, outside quiet hours.
    @MainActor public static func due(store: Store, now: Date) -> [Due] {
        guard !inQuietHours(ReminderBudget(store: store).settings, now: now) else { return [] }
        return windowReviews(store: store, now: now).filter { p in
            let last = (try? store.db.query("SELECT value FROM meta WHERE key=?", [nudgedKey(p.level)]) { DB.text($0, 0) })?.first // try?-ok: unreadable = not nudged; at worst one extra nudge
            return last != p.key
        }.map { Due(level: $0.level, period: $0) }
    }

    /// Records that these were given, so each period is nudged once.
    @MainActor public static func markNudged(_ dues: [Due], store: Store) {
        store.perform {
            for d in dues { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [nudgedKey(d.level), d.period.key]) }
        }
    }

    /// The notification's text: one for both when a quarter and its year end together.
    public static func text(_ dues: [Due]) -> String {
        "Time to review " + dues.map(\.period.title).joined(separator: " and ") + "."
    }

    static func inQuietHours(_ s: ReminderSettings, now: Date) -> Bool {
        let c = AppTime.calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if s.quietStart == s.quietEnd { return false }
        return s.quietStart > s.quietEnd ? (m >= s.quietStart || m < s.quietEnd) : (m >= s.quietStart && m < s.quietEnd)
    }
}
