import FloatBoardCore
import SwiftUI

/// The Decisions tab (features §4 D3, D8): the list with search and filters (tag, type, status, person) and sorting, and the
/// selected decision's card.
struct DecisionsTab: View {
    @EnvironmentObject var store: Store
    @ObservedObject var dui = DecisionsUI.shared
    @State private var filter = DecisionFilter()

    var body: some View {
        let ds = DecisionStore(store: store)
        let list = ds.list(filter)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search decisions: words, or D-12", text: $filter.query).textFieldStyle(.roundedBorder)
                filters
                if list.isEmpty {
                    Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { d in row(d) }
                    }
                }
                Text(screenedLine).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(width: 330)
            .padding(.trailing, 10)
            Divider()
            Group {
                if let id = dui.selected, let d = ds.decision(id), !d.deleted {
                    DecisionCard(decision: d).id(d.id)
                } else {
                    VStack(spacing: 6) {
                        Text("Decisions").font(.system(size: 15, weight: .semibold))
                        Text("A record of decisions already made, found in your jots each Sunday or made by hand: select text, right-click, Make decision.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 12)
        }
        .overlay(alignment: .bottom) { DecisionUndoBar() }
    }

    private var emptyText: String {
        filter == DecisionFilter(sort: filter.sort) ? "No decisions yet. Claude reads the week's jots on Sunday; you can also select text and choose Make decision."
            : "No decisions match."
    }

    private var screenedLine: String {
        guard let last = DecisionScreening.lastRun(store: store) else { return "Jots are screened for decisions on Sundays from 17:00." }
        return "Last screened \(Fmt.short(last)). Jots are screened for decisions on Sundays from 17:00."
    }

    private var filters: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Any tag") { filter.tags = [] }
                ForEach(store.tags.map(\.name), id: \.self) { t in Button(t) { filter.tags = [t] } }
            } label: { Text(filter.tags.first ?? "Tag") }
            Menu {
                Button("Any type") { filter.type = nil }
                ForEach(DecisionType.allCases, id: \.self) { t in Button(t.title) { filter.type = t } }
            } label: { Text(filter.type?.title ?? "Type") }
            Menu {
                Button("Any status") { filter.status = nil }
                ForEach(DecisionStatus.allCases, id: \.self) { s in Button(s.title) { filter.status = s } }
            } label: { Text(filter.status?.title ?? "Status") }
            Menu {
                Button("Anyone") { filter.person = nil }
                ForEach(PeopleStore(store: store).people(), id: \.id) { p in Button(p.name) { filter.person = p.shortID } }
            } label: { Text(filter.person.flatMap { store.item($0)?.title } ?? "Person") }
            Menu {
                ForEach(DecisionSort.allCases, id: \.self) { s in Button(s.title) { filter.sort = s } }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .help("Sort: \(filter.sort.title)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 11))
    }

    private func row(_ d: Decision) -> some View {
        Button { dui.selected = d.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.shortID.text).monospacedDigit().foregroundStyle(.secondary)
                    Text(d.text).lineLimit(2).foregroundStyle(d.status == .reversed || d.status == .superseded ? .secondary : .primary)
                }
                Text(rowDetail(d)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(dui.selected == d.id ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
    }

    private func rowDetail(_ d: Decision) -> String {
        var parts = [d.status.title, d.type.title, "recorded \(Fmt.short(d.recorded))"]
        if d.foundByClaude { parts.append("found by Claude") }
        if let t = store.itemTags(d.shortID).primary { parts.append(t) }
        return parts.joined(separator: " · ")
    }
}
