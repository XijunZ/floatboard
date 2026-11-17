import FloatBoardCore
import SwiftUI

/// The quarterly or yearly review (R4): for each active goal of the period, kept / changed / dropped and a short note (saved
/// as a jot linked to the goal); then the next period's goals, where new ones can be added. The yearly review also shows
/// the five-year picture.
struct ReviewSheet: View {
    let period: GoalPeriod
    var close: () -> Void
    var now: Date = Date()
    @EnvironmentObject var store: Store
    @State private var choices: [Int64: Choice] = [:]
    @State private var saved = false
    @State private var problems: [String] = []
    @State private var expanded: Set<Int64> = []

    struct Choice { var outcome: ReviewOutcome = .kept; var newTitle = ""; var note = "" }

    var body: some View {
        let r = ResolutionStore(store: store)
        let active = r.goals(in: period).filter { $0.status == .active }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review \(period.title)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(saved ? "Done" : "Close", action: close).keyboardShortcut(saved ? .defaultAction : .cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if period.level == .year { FiveYearPicture(now: now) }
                    if !saved {
                        if active.isEmpty { Text("Every goal of \(period.title) is reviewed.").foregroundStyle(.secondary) }
                        ForEach(active) { g in goalReview(g, r) }
                    }
                    ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red).font(.system(size: 11)) }
                    if saved || active.isEmpty {
                        Text("Next: \(r.rolloverPeriod(of: period, now: now).title)").font(.system(size: 13, weight: .semibold))
                        Text("Kept and changed goals carry on here with their open tasks. Add new ones if there is room.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        GoalSection(period: r.rolloverPeriod(of: period, now: now), expanded: $expanded, onDelete: { r.delete($0.id) }) { EmptyView() }
                    }
                }
                .padding(.vertical, 2)
            }
            if !saved && !active.isEmpty {
                HStack {
                    Spacer()
                    Button("Save review") { save(active, r) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 600, height: 560)
    }

    @ViewBuilder private func goalReview(_ g: Goal, _ r: ResolutionStore) -> some View {
        let c = Binding(get: { choices[g.id] ?? Choice() }, set: { choices[g.id] = $0 })
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(g.shortID.text).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Text(g.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(r.progress(g.id).summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("", selection: c.outcome) {
                ForEach(ReviewOutcome.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            if c.wrappedValue.outcome == .changed {
                TextField("The goal's new wording for \(r.rolloverPeriod(of: period, now: now).title)", text: c.newTitle).textFieldStyle(.roundedBorder)
            }
            TextField("A short note: what happened, what you learned (saved as a jot)", text: c.note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .font(.system(size: 12))
    }

    private func save(_ goals: [Goal], _ r: ResolutionStore) {
        problems = []
        for g in goals {
            let c = choices[g.id] ?? Choice()
            if case .failure(let e) = r.review(g.id, outcome: c.outcome, note: c.note, newTitle: c.newTitle) {
                problems.append("\(g.shortID.text): \(e.message)")
            }
        }
        saved = problems.isEmpty
    }
}
