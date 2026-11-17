import FloatBoardCore
import SwiftUI

/// Wires the Resolutions area into the app: the shared registries, opening a goal from search, and the review nudges.
@MainActor enum ResolutionsArea {
    static func setUp(store: Store, ui: UIState) {
        Resolutions.register()
        GlobalSearchOpen.handlers[.resolution] = { [weak ui] id in
            ui?.focusGoal = id
            ui?.tab = .resolutions
        }
    }
}

/// The quarter and year review nudges (outside the reminder budget, once per period), from the app's minute ticker.
@MainActor enum ResolutionsNudger {
    static func tick(store: Store, now: Date, show: (DueReminder) -> Void) {
        let due = ResolutionNudges.due(store: store, now: now)
        guard !due.isEmpty else { return }
        ResolutionNudges.markNudged(due, store: store)
        let title = due.count > 1 ? "Quarter and year review" : due[0].level == .quarter ? "Quarter review" : "Year review"
        show(DueReminder(id: "resolutions-review-" + due.map(\.period.key).joined(separator: "-"), cardID: 0, title: title,
                         body: ResolutionNudges.text(due) + " Open Resolutions to review your goals.", fireAt: now.addingTimeInterval(1)))
    }
}

/// The board filtered by a goal (R5): only the goal's tasks (a yearly goal's include its quarterly goals'), each once.
@MainActor enum GoalFilter {
    static func apply(_ goal: ShortID?, _ cards: [Card], store: Store) -> [Card] {
        guard let goal, goal.kind == .resolution, store.isOn(.resolutions) else { return cards }
        let ids = ResolutionStore(store: store).taskIDs(for: goal.number)
        return cards.filter { ids.contains($0.id) }
    }
}

/// "Tasks of R-2 · Ship the assistant ✕" above the columns while the board is filtered by a goal.
struct GoalFilterChip: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    var body: some View {
        if let g = ui.goalFilter {
            HStack(spacing: 6) {
                Image(systemName: "target").foregroundStyle(.secondary)
                (Text("Tasks of ") + Text(g.text).monospacedDigit() + Text(" · " + (store.item(g)?.title ?? "")))
                    .lineLimit(1)
                Button { ui.goalFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Show every task again")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
    }
}

/// "Serves a goal" menu: links this task, jot or decision to an active yearly or quarterly goal. The links themselves
/// show (with ✕) in the item's link chips. Shown only while Resolutions is on.
struct GoalPicker: View {
    let item: ShortID
    @EnvironmentObject var store: Store
    @State private var problem: String?

    var body: some View {
        if store.isOn(.resolutions) {
            let r = ResolutionStore(store: store)
            let served = Set(r.goals(servedBy: item).map(\.id))
            let choices = r.linkableGoals().filter { !served.contains($0.id) }
            HStack(spacing: 6) {
                Menu {
                    if choices.isEmpty { Text("No goals to link: set them in Resolutions") }
                    ForEach(choices) { g in
                        Button("\(g.shortID.text) · \(g.period.title) · \(ItemCatalog.firstLine(g.title))") {
                            problem = r.linkWork(item, to: g.id)
                        }
                    }
                } label: { Label("Serves a goal…", systemImage: "target").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Link this to a yearly or quarterly goal (or type its id, such as R-3, in the notes)")
                if let problem { Text(problem).foregroundStyle(.red).lineLimit(2) }
            }
            .font(.system(size: 12))
        }
    }
}
