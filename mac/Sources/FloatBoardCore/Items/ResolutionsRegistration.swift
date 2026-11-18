import Foundation
import SQLite3

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
