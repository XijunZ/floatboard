import FloatBoardCore
import SwiftUI

/// A decision's review (features §4 D6): the original card with its expected outcome beside it, then "What happened?" and
/// "Was the thinking sound?". The answer is saved as a jot linked to the decision. Right-click in the text → Make task.
/// For each person on the decision: "Check in with <name> about how it went" (D7).
struct DecisionReviewSheet: View {
    let decisionID: Int64
    var close: () -> Void
    @EnvironmentObject var store: Store
    @State private var happened = ""
    @State private var sound = ""
    @State private var made: Set<Int64> = []

    var body: some View {
        let ds = DecisionStore(store: store)
        VStack(alignment: .leading, spacing: 12) {
            if let d = ds.decision(decisionID) {
                Text("Review \(d.shortID.text)").font(.system(size: 13, weight: .semibold))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The decision").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        SelectableText(d.text, source: d.shortID, fontSize: 13)
                        if !d.quote.isEmpty { SelectableText("“\(d.quote)” (\(d.sourceLabel))", source: d.sourceItem ?? d.shortID, fontSize: 11) }
                        Text("Why: \(d.why.isEmpty ? "not recorded" : d.why)").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(d.type.title) · recorded \(Fmt.short(d.recorded))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What you expected").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(d.expected.isEmpty ? "No expected outcome was recorded." : d.expected).font(.system(size: 12))
                            .foregroundStyle(d.expected.isEmpty ? .secondary : .primary)
                        Text("Confidence: \(d.confidence?.title ?? "not set")").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(width: 200, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
                }
                answer("What happened?", $happened, source: d.shortID)
                answer("Was the thinking sound?", $sound, source: d.shortID)
                let checkIns = DecisionReviews.checkInTitles(d.id, store: store)
                if !checkIns.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(checkIns, id: \.0.id) { p, title in
                            HStack {
                                Text(title).font(.system(size: 11))
                                if made.contains(p.id) { Text("task made").font(.system(size: 11)).foregroundStyle(.secondary) } else {
                                    Button("Make task") {
                                        if let t = store.makeTask(TaskDraft(title: title, notes: "", primaryTag: nil, others: []), due: nil, dueHasTime: false, from: d.shortID) {
                                            store.link(ShortID(kind: .task, number: t), p.shortID, kind: .related, madeBy: .suggested, actor: .user)
                                            made.insert(p.id)
                                        }
                                    }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("Snooze a week") { DecisionReviews.snooze(d.id, store: store); close() }
                    Button("Turn off for this decision") { DecisionReviews.setOn(d.id, false, store: store); close() }
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Save review") {
                        DecisionReviews.answer(d.id, happened: happened, sound: sound, store: store)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((happened + sound).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d.reviewState == .done)
                }
                .font(.system(size: 12))
            } else {
                Text("This decision is gone.").foregroundStyle(.secondary)
                Button("Close") { close() }
            }
        }
        .padding(14)
        .frame(width: 560)
    }

    private func answer(_ title: String, _ text: Binding<String>, source: ShortID) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold))
            SelectableTextEditor(text: text, source: source)
                .frame(height: 60)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        }
    }
}

/// A Decisions row on the weekly review page (D4): recorded this week (Not a decision; for screened ones a prompt to add the
/// expected outcome and confidence), Maybe (Record / Not a decision), and due reviews (Review).
struct DecisionReviewRow: View {
    enum Kind { case recorded, maybe, review }
    let item: ReviewItem
    let kind: Kind
    @EnvironmentObject var store: Store
    @State private var dismissed = false
    @State private var recorded = false
    @State private var predicting = false
    @State private var reviewing = false
    @State private var expected = ""
    @State private var confidence: Confidence?

    var body: some View {
        let id = item.item?.number ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let s = item.item { Text(s.text).monospacedDigit().foregroundStyle(.secondary) }
                Text(item.title).lineLimit(1).strikethrough(dismissed)
                Spacer(minLength: 4)
                if dismissed {
                    Text("not a decision").foregroundStyle(.secondary)
                    Button("Undo") { DecisionStore(store: store).undoNotADecision(id); dismissed = false }.controlSize(.small)
                } else {
                    switch kind {
                    case .recorded:
                        Button("Not a decision") { DecisionStore(store: store).notADecision(id); dismissed = true }.controlSize(.small)
                    case .maybe:
                        if recorded { Text("recorded").foregroundStyle(.secondary) } else {
                            Button("Record") { DecisionStore(store: store).setStatus(id, .decided); recorded = true }.controlSize(.small)
                            Button("Not a decision") { DecisionStore(store: store).notADecision(id); dismissed = true }.controlSize(.small)
                        }
                    case .review:
                        Button("Review") { reviewing = true }.controlSize(.small)
                            .popover(isPresented: $reviewing) { DecisionReviewSheet(decisionID: id) { reviewing = false }.environmentObject(store) }
                    }
                }
            }
            HStack(spacing: 6) {
                Text(item.detail).foregroundStyle(.secondary).lineLimit(1)
                if kind == .recorded, !dismissed, DecisionStore(store: store).decision(id)?.needsPrediction == true {
                    Button("Add expected outcome and confidence") { predicting = true }
                        .buttonStyle(.link).font(.system(size: 11))
                        .popover(isPresented: $predicting) { predictionForm(id) }
                }
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
    }

    private func predictionForm(_ id: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            TextField("Expected outcome", text: $expected, axis: .vertical).textFieldStyle(.roundedBorder)
            Picker("Confidence", selection: $confidence) {
                Text("Not set").tag(Confidence?.none)
                ForEach(Confidence.allCases, id: \.self) { Text($0.title).tag(Confidence?.some($0)) }
            }.pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Save") {
                    let ds = DecisionStore(store: store)
                    if var d = ds.decision(id) {
                        if !expected.trimmingCharacters(in: .whitespaces).isEmpty { d.expected = expected }
                        if let confidence { d.confidence = confidence }
                        ds.update(d)
                    }
                    predicting = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12).frame(width: 340)
    }
}
