import FloatBoardCore
import SwiftUI

/// The Resolutions tab (features §5): the five-year picture, the year's goals and a quarter's goals (‹ › moves between
/// quarters, so next quarter's can be set ahead), each with its progress, and a banner while a review is open.
struct ResolutionsTab: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    /// Which quarter is shown (its year's goals are shown with it). Nil: the current one.
    @State private var shownQuarter: GoalPeriod?
    @State private var reviewing: ReviewRequest?
    @State private var expanded: Set<Int64> = []
    @State private var deleted: Goal?
    /// Snapshots draw at a fixed time.
    var now: Date = Date()

    init(now: Date = Date(), expanded: Set<Int64> = []) {
        self.now = now
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let r = ResolutionStore(store: store)
        let quarter = shownQuarter ?? GoalPeriod.current(.quarter, now: now)
        let year = GoalPeriod.current(.year, now: quarter.interval.start)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let reviews = ResolutionNudges.openReviews(store: store, now: now)
                if !reviews.isEmpty { ReviewBanner(periods: reviews) { reviewing = ReviewRequest(period: $0) } }
                FiveYearPicture(now: now)
                GoalSection(period: year, expanded: $expanded, onDelete: delete) { EmptyView() }
                GoalSection(period: quarter, expanded: $expanded, onDelete: delete) {
                    HStack(spacing: 2) {
                        Button { shownQuarter = quarter.previous } label: { Image(systemName: "chevron.left") }.help("Previous quarter")
                        Button { shownQuarter = quarter.next } label: { Image(systemName: "chevron.right") }.help("Next quarter")
                        if quarter != GoalPeriod.current(.quarter, now: now) {
                            Button("This quarter") { shownQuarter = nil }.controlSize(.small)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Text("Link work to a goal from a task's editor (Serves a goal), or type the goal's id, such as R-3, in a task's notes or a jot.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if let d = deleted {
                HStack(spacing: 10) {
                    Text("Deleted \(d.shortID.text)").lineLimit(1)
                    Button("Undo") { r.undoDelete(d.id); deleted = nil }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button { deleted = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .padding(.bottom, 8)
                .task(id: d.id) {
                    try? await Task.sleep(for: .seconds(Store.undoBarSeconds)) // try?-ok: cancelled when another delete replaces this bar
                    if !Task.isCancelled { deleted = nil }
                }
            }
        }
        .sheet(item: $reviewing) { req in ReviewSheet(period: req.period) { reviewing = nil } }
        .onAppear(perform: focus)
        .onChange(of: ui.focusGoal) { _, _ in focus() }
    }

    private func delete(_ g: Goal) {
        ResolutionStore(store: store).delete(g.id)
        deleted = g
    }

    /// Opens the goal search or a link asked for: shows its quarter and expands it.
    private func focus() {
        guard let id = ui.focusGoal, let g = ResolutionStore(store: store).goal(id.number) else { return }
        if g.level == .quarter { shownQuarter = g.period }
        else if g.level == .year { shownQuarter = GoalPeriod.current(.quarter, now: g.period.interval.start) }
        expanded.insert(g.id)
        ui.focusGoal = nil
    }
}

struct ReviewRequest: Identifiable {
    let period: GoalPeriod
    var id: String { period.level.rawValue + period.key }
}

/// "Time to review Q4 2026" (and the year, when both end together) while a review is open.
struct ReviewBanner: View {
    let periods: [GoalPeriod]
    let open: (GoalPeriod) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Time to review " + periods.map(\.title).joined(separator: " and ")).font(.system(size: 13, weight: .semibold))
                Text("For each goal: kept, changed or dropped, and a short note. Then set the next period's goals.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(periods, id: \.self) { p in
                Button("Review \(p.title)") { open(p) }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
    }
}

/// The five-year picture: a few lines, edited in place (earlier wordings kept).
struct FiveYearPicture: View {
    @EnvironmentObject var store: Store
    var now: Date = Date()
    @State private var editing = false
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        let r = ResolutionStore(store: store)
        let picture = r.fiveYear(now: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Five-year picture").font(.system(size: 13, weight: .semibold))
                if let p = picture {
                    Text("\(p.period.title) · \(p.shortID.text)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    let n = r.history(p.id).count
                    if n > 0 { Text("· \(n) earlier version\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                Spacer()
                if !editing {
                    Button(picture == nil ? "Write it" : "Edit") { text = picture?.title ?? ""; editing = true }.controlSize(.small)
                }
            }
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(minHeight: 70, maxHeight: 120)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                HStack {
                    Button("Save") { save(r, picture) }.buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false; problem = nil }.controlSize(.small)
                    if let problem { Text(problem).foregroundStyle(.red).font(.system(size: 11)) }
                }
            } else if let p = picture {
                SelectableText(p.title, source: p.shortID, fontSize: 13)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A few lines on where you want to be in five years. Yearly goals sit under it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func save(_ r: ResolutionStore, _ picture: Goal?) {
        if let p = picture {
            problem = r.update(p.id, title: text, notes: p.notes)
        } else {
            switch r.create(level: .fiveYear, period: GoalPeriod.current(.fiveYear, now: now), title: text, now: now) {
            case .success: problem = nil
            case .failure(let e): problem = e.message
            }
        }
        if problem == nil { editing = false }
    }
}

/// One period's goals: a header with the count and its limit, the goals, and "+ Add" while there is room.
struct GoalSection<Accessory: View>: View {
    let period: GoalPeriod
    @Binding var expanded: Set<Int64>
    var onDelete: (Goal) -> Void
    @ViewBuilder var accessory: () -> Accessory
    @EnvironmentObject var store: Store
    @State private var adding = false
    @State private var newTitle = ""
    @State private var problem: String?

    var body: some View {
        let r = ResolutionStore(store: store)
        let goals = r.goals(in: period)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(period.title) · \(period.level == .quarter ? "quarterly" : "yearly") goals").font(.system(size: 13, weight: .semibold))
                Text("\(goals.count) of \(period.level.limit)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                accessory()
                Spacer()
                if goals.count < period.level.limit && !adding {
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }.controlSize(.small)
                }
            }
            if goals.isEmpty && !adding {
                Text(period.level == .quarter ? "No goals for \(period.title) yet. Up to 3, kept light." : "No goals for \(period.title) yet. Up to 5.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(goals) { g in
                GoalRow(goal: g, expanded: Binding(get: { expanded.contains(g.id) }, set: { on in
                    if on { expanded.insert(g.id) } else { expanded.remove(g.id) }
                }), onDelete: { onDelete(g) })
            }
            if adding {
                HStack(spacing: 6) {
                    TextField(period.level == .quarter ? "A goal for \(period.title)" : "A goal for \(period.title)", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { adding = false; newTitle = ""; problem = nil }.controlSize(.small)
                }
                .font(.system(size: 13))
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
        }
    }

    private func add() {
        switch ResolutionStore(store: store).create(level: period.level, period: period, title: newTitle) {
        case .success: newTitle = ""; adding = false; problem = nil
        case .failure(let e): problem = e.message
        }
    }
}
