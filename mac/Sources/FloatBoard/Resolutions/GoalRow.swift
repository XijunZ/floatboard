import FloatBoardCore
import SwiftUI

/// One goal: id, title, parent, progress and "Show on board"; expanded, its wording, parent, tags, linked work (with ✕),
/// recent jots, review notes, "Link work" by id and Delete. A reviewed goal is read-only and says how its review ended.
struct GoalRow: View {
    let goal: Goal
    @Binding var expanded: Bool
    var onDelete: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @State private var title = ""
    @State private var notes = ""
    @State private var editing = false
    @State private var linkText = ""
    @State private var problem: String?

    var body: some View {
        let r = ResolutionStore(store: store)
        let progress = r.progress(goal.id)
        let parent = r.parent(of: goal.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Text(goal.shortID.text).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Text(goal.title).font(.system(size: 13, weight: .medium)).lineLimit(expanded ? nil : 1)
                    .foregroundStyle(goal.status == .active ? .primary : .secondary)
                if goal.status != .active { StatusBadge(goal: goal) }
                if goal.reviewOverdue(now: Date()) {
                    Text("Review overdue").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.22)))
                        .help("\(goal.period.title) has ended. Review it from the banner at the top; it carries on into the current period.")
                }
                Spacer(minLength: 8)
                if let parent {
                    Text("under \(parent.shortID.text)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .help(parent.title)
                }
            }
            HStack(spacing: 10) {
                Text(progress.summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !progress.done.isEmpty || !progress.open.isEmpty {
                    Button { ui.goalFilter = goal.shortID; ui.tab = .board } label: { Label("Show on board", systemImage: "line.3.horizontal.decrease.circle") }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .help(goal.level == .year ? "Show only this goal's tasks, and its quarterly goals' tasks, on the board" : "Show only this goal's tasks on the board")
                }
            }
            .padding(.leading, 20)
            if expanded { details(r, progress: progress, parent: parent).padding(.leading, 20) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(goal.status == .active ? 0.04 : 0.02)))
    }

    @ViewBuilder private func details(_ r: ResolutionStore, progress: GoalProgress, parent: Goal?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                TextField("Goal", text: $title).textFieldStyle(.roundedBorder)
                TextField("Notes (why it matters, what done looks like)", text: $notes, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        problem = r.update(goal.id, title: title, notes: notes)
                        if problem == nil { editing = false }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editing = false; problem = nil }.controlSize(.small)
                }
            } else if !goal.notes.isEmpty {
                SelectableText(goal.notes, source: goal.shortID).fixedSize(horizontal: false, vertical: true)
            }
            if goal.status == .active && goal.level != .fiveYear { parentMenu(r, parent: parent) }
            GoalTags(goal: goal)
            if !progress.jots.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent jots").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(progress.jots, id: \.self) { j in
                        Text("\(j.text) · \(store.item(j)?.title ?? "")").lineLimit(1).font(.system(size: 12))
                    }
                }
            }
            if !progress.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Decisions").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(progress.decisions, id: \.self) { d in
                        Text("\(d.text) · \(store.item(d)?.title ?? "")").lineLimit(1).font(.system(size: 12))
                    }
                }
            }
            LinkChips(item: goal.shortID)
            let reviewNotes = r.reviewNotes(goal.id)
            if !reviewNotes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review notes").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(reviewNotes) { j in
                        SelectableText(j.text, source: j.shortID).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if goal.status == .active && goal.level != .fiveYear {
                HStack(spacing: 6) {
                    TextField("Link work: T-12, J-7 or D-3", text: $linkText).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        .onSubmit { linkWork(r) }
                    Button("Link", action: { linkWork(r) }).controlSize(.small).disabled(ShortID.mentions(in: linkText).isEmpty)
                }
            }
            HStack(spacing: 8) {
                if goal.status == .active && !editing {
                    Button("Edit") { title = goal.title; notes = goal.notes; editing = true }.controlSize(.small)
                }
                Button("Delete", role: .destructive, action: onDelete).controlSize(.small)
                Text("Added \(Fmt.short(goal.added))" + (goal.reviewed.map { " · reviewed \(Fmt.short($0))" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private func parentMenu(_ r: ResolutionStore, parent: Goal?) -> some View {
        let level = goal.level.parentLevel ?? .fiveYear
        let candidates = r.goals(level: level).filter { $0.period.contains(goal.period) && ($0.status == .active || $0.id == parent?.id) }
        HStack(spacing: 6) {
            Text(goal.level == .quarter ? "Under yearly goal" : "Under the five-year picture").foregroundStyle(.secondary)
            Menu {
                Button("None") { problem = r.setParent(goal.id, nil) }
                ForEach(candidates) { c in
                    Button("\(c.shortID.text) · \(ItemCatalog.firstLine(c.title))") { problem = r.setParent(goal.id, c.id) }
                }
            } label: {
                Text(parent.map { "\($0.shortID.text) · \(ItemCatalog.firstLine($0.title))" } ?? "None").lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func linkWork(_ r: ResolutionStore) {
        let ids = ShortID.mentions(in: linkText)
        let problems = ids.compactMap { r.linkWork($0, to: goal.id) }
        problem = problems.first
        if problems.isEmpty { linkText = "" }
    }
}

/// "Kept → R-9", "Changed → R-10", "Dropped".
struct StatusBadge: View {
    let goal: Goal
    @EnvironmentObject var store: Store

    var body: some View {
        let next = ResolutionStore(store: store).continuation(of: goal.id)
        Text(goal.status.title + (next.map { " → \($0.shortID.text)" } ?? ""))
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(goal.status == .dropped ? Color.secondary.opacity(0.15) : Color.green.opacity(0.18)))
    }
}

/// A goal's tags: chips with ✕ and a + menu of every tag (the first one is its primary).
struct GoalTags: View {
    let goal: Goal
    @EnvironmentObject var store: Store

    var body: some View {
        let tags = store.itemTags(goal.shortID)
        HStack(spacing: 6) {
            Text("Tags").foregroundStyle(.secondary)
            ForEach(tags.all, id: \.self) { t in
                HStack(spacing: 3) {
                    Circle().fill(store.color(t)).frame(width: 7, height: 7)
                    Text(t).lineLimit(1)
                    if goal.status == .active {
                        Button { set(tags.all.filter { $0 != t }) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.borderless).help("Remove this tag")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if goal.status == .active {
                Menu {
                    ForEach(store.tags.map(\.name).filter { !tags.all.contains($0) }, id: \.self) { n in Button(n) { set(tags.all + [n]) } }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("Add a tag")
            }
        }
    }

    private func set(_ all: [String]) {
        store.setTags(goal.shortID, primary: all.first, others: Array(all.dropFirst()))
        store.objectWillChange.send()
    }
}
