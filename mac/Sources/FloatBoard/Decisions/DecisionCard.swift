import FloatBoardCore
import SwiftUI

/// One decision's card (features §4 D3, D5, D6, D7): what was decided, both dates, the exact quote and its source, why,
/// expected outcome and confidence (marked "added later" when added after recording), type, status, tags, people, the
/// review, suggestions, links and past reviews. Edits are saved with Save.
struct DecisionCard: View {
    let decision: Decision
    @EnvironmentObject var store: Store
    @ObservedObject var dui = DecisionsUI.shared
    @State private var draft: Decision?

    var body: some View {
        let d = draft ?? decision
        let ds = DecisionStore(store: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(d)
                TextField("The decision", text: bind(\.text), axis: .vertical).font(.system(size: 15, weight: .semibold)).textFieldStyle(.plain)
                Text(dates(d)).font(.system(size: 11)).foregroundStyle(.secondary)
                if !d.quote.isEmpty { quote(d, note: ds.sourceNote(d)) }
                field("Why", placeholder: "not recorded", text: bind(\.why))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        field("Expected outcome", placeholder: "not recorded", text: bind(\.expected))
                        if d.expectedAdded != nil { laterTag }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Confidence").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        Picker("", selection: bind(\.confidence)) {
                            Text("Not set").tag(Confidence?.none)
                            ForEach(Confidence.allCases, id: \.self) { Text($0.title).tag(Confidence?.some($0)) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                        if d.confidenceAdded != nil { laterTag }
                    }
                }
                if d.needsPrediction {
                    Text("Found by Claude: add your expected outcome and confidence (they are never guessed).")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                field("Alternatives (optional)", placeholder: "none recorded", text: bind(\.alternatives))
                tagsAndPeople(d)
                review(d)
                suggestions(d)
                LinkChips(item: d.shortID, except: [.person])
                pastReviews(d)
                HStack {
                    Button("Not a decision") { dui.notADecision(d.id, store: store) }
                        .help("Removes it and teaches the Decisions rulebook (Undo for a few seconds).")
                    Spacer()
                    if draft != nil && draft != decision {
                        Button("Revert") { draft = nil }
                        Button("Save") { if let e = draft { ds.update(e) }; draft = nil }.keyboardShortcut(.defaultAction)
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<Decision, T>) -> Binding<T> {
        Binding(get: { (draft ?? decision)[keyPath: kp] }, set: { var e = draft ?? decision; e[keyPath: kp] = $0; draft = e })
    }

    private var laterTag: some View { Text("added later").font(.system(size: 10)).foregroundStyle(.secondary) }

    private func header(_ d: Decision) -> some View {
        HStack(spacing: 8) {
            Text(d.shortID.text).monospacedDigit().foregroundStyle(.secondary)
            if d.status == .maybe {
                Text("Maybe").padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.2)))
                Button("Record") { ds.setStatus(d.id, .decided); draft = nil }.controlSize(.small)
            } else {
                Dropdown(options: DecisionStatus.owned, selection: bind(\.status), title: { $0.title })
            }
            Dropdown(options: DecisionType.allCases, selection: bind(\.type), title: { $0.title })
            Spacer()
            Text(d.foundByClaude ? "found by Claude" : "recorded by you").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var ds: DecisionStore { DecisionStore(store: store) }

    private func dates(_ d: Decision) -> String {
        let decided = d.decided.isEmpty ? "unknown" : Due.startOfDay(d.decided).map(Fmt.short) ?? d.decided
        return "Recorded \(Fmt.short(d.recorded)) (when the source was written) · Decided: \(decided)"
    }

    private func quote(_ d: Decision, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SelectableText("“\(d.quote)”", source: d.sourceItem ?? d.shortID, fontSize: 12)
            HStack(spacing: 6) {
                Text("from \(d.sourceLabel)").monospacedDigit()
                if let s = d.sourceItem, let item = store.item(s) { Text(item.title).lineLimit(1) }
                if let note { Text("· \(note); the quote is kept").foregroundStyle(.orange) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            TextField(placeholder, text: text, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }

    private func tagsAndPeople(_ d: Decision) -> some View {
        let tags = store.itemTags(d.shortID).all
        let people = ds.people(of: d.id)
        return HStack(spacing: 6) {
            Text("Tags").foregroundStyle(.secondary)
            if tags.isEmpty { Text("untagged").foregroundStyle(.tertiary) }
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) { Circle().fill(store.color(t)).frame(width: 7, height: 7); Text(t) }
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Text("People").foregroundStyle(.secondary).padding(.leading, 10)
            if people.isEmpty { Text("none named").foregroundStyle(.tertiary) }
            ForEach(people, id: \.id) { p in Text("\(p.shortID.text) \(p.name)") }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private func review(_ d: Decision) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            switch d.reviewState {
            case .done: Text("Reviewed \(Fmt.short(d.reviewed ?? d.updated))")
            case .off:
                Text("Review turned off for this decision").foregroundStyle(.secondary)
                Button("Turn on") { DecisionReviews.setOn(d.id, true, store: store); draft = nil }.controlSize(.small)
            case .scheduled:
                Text("Review \(Fmt.short(d.reviewDue ?? d.recorded)) (\(d.type.title.lowercased()): \(d.type.reviewDays) days after recorded)")
                Button("Review now") { dui.review = .init(id: d.id) }.controlSize(.small)
                Button("Snooze a week") { DecisionReviews.snooze(d.id, store: store); draft = nil }.controlSize(.small)
                Button("Turn off") { DecisionReviews.setOn(d.id, false, store: store); draft = nil }.controlSize(.small)
            }
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private func suggestions(_ d: Decision) -> some View {
        let list = ds.suggestions(d.id)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestions").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(list) { s in
                    HStack(spacing: 6) {
                        switch s.kind {
                        case .supersedes:
                            Text("May replace \(s.target.text) · \(store.item(s.target)?.title ?? "")").lineLimit(1)
                            Button("Yes, it replaces it") { ds.acceptSupersedes(d.id, replaces: s.target.number); draft = nil }.controlSize(.small)
                        case .tell, .ask:
                            Text(s.text).lineLimit(1)
                            Button("Make task") { ds.acceptTask(s); draft = nil }.controlSize(.small)
                        }
                        Button { ds.setSuggestion(d.id, kind: s.kind, target: s.target, state: "dismissed"); draft = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Not useful")
                    }
                }
            }
            .font(.system(size: 11))
        }
    }

    @ViewBuilder private func pastReviews(_ d: Decision) -> some View {
        let reviews = ds.reviews(of: d.id)
        if !reviews.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(reviews) { j in
                    SelectableText(j.text, source: j.shortID, fontSize: 12)
                        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }
}
