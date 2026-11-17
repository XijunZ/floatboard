import FloatBoardCore
import SwiftUI

/// The two buttons at the right of a column header: what to sort by (the bar's attributes) and which way.
struct ColumnSortControls: View {
    @EnvironmentObject var ui: UIState
    let status: Status

    var body: some View {
        let sort = ColumnSort.forColumn(status, saved: ui.columnSorts[status.rawValue])
        HStack(spacing: 2) {
            Menu {
                Picker("Sort by", selection: Binding(
                    get: { sort.key },
                    set: { k in ui.columnSorts[status.rawValue] = ColumnSort(key: k, ascending: k?.naturalAscending ?? false) })) {
                    if status == .done { Text("Date finished").tag(SortKey?.none) }
                    // Status is left out: every task in a column has the same one.
                    ForEach(SortKey.allCases.filter { $0 != .status }) { Text($0.columnTitle).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(sort.key?.title ?? "Date finished").font(.system(size: 10.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Sort this column by an attribute")
            Button {
                var s = sort; s.ascending.toggle(); ui.columnSorts[status.rawValue] = s
            } label: {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(sort.ascending ? "Ascending (click for descending)" : "Descending (click for ascending)")
        }
        .foregroundStyle(.secondary)
    }
}

struct Column: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    let status: Status
    @State private var targeted = false
    /// Topmost visible task (tracked so a cancelled search can scroll back to it).
    @State private var topID: Int64?
    @State private var beforeSearch: Int64?? = nil

    var body: some View {
        let sort = ColumnSort.forColumn(status, saved: ui.columnSorts[status.rawValue])
        let cards = sort.apply(GoalFilter.apply(ui.goalFilter, store.cards(in: status), store: store), groupOrder: store.areas.map(\.name))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.title).font(.system(size: 12, weight: .semibold))
                Text("\(cards.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ColumnSortControls(status: status)
            }
            .padding(.horizontal, 4)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if status == .done && sort.key == nil {
                        // Sorted by date finished: grouped by the day they were done, newest day first (oldest when ascending).
                        let groups = Dictionary(grouping: cards) { AppTime.calendar.startOfDay(for: $0.done ?? $0.created) }
                        ForEach(groups.keys.sorted(by: sort.ascending ? (<) : (>)), id: \.self) { day in
                            let items = groups[day] ?? []
                            Text("\(Fmt.heading(day)) · \(items.count) done")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .padding(.horizontal, 2)
                            ForEach(items) { CardView(card: $0) }
                        }
                    } else {
                        ForEach(cards) { CardView(card: $0) }
                    }
                }
                .padding(.bottom, 6)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topID, anchor: .top)
            // Searching: bring this column's first match into view; Enter: follow the current match.
            // Cancelling (Esc/✕ without Enter): scroll back to where the column was before.
            .onChange(of: ui.search) { old, q in
                let wasEmpty = old.trimmingCharacters(in: .whitespaces).isEmpty
                let isEmpty = q.trimmingCharacters(in: .whitespaces).isEmpty
                if wasEmpty && !isEmpty {
                    beforeSearch = .some(topID)
                    ui.searchCommitted = false
                }
                if isEmpty {
                    if !wasEmpty, !ui.searchCommitted, let saved = beforeSearch {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if let id = saved ?? cards.first?.id { proxy.scrollTo(id, anchor: .top) }
                        }
                    }
                    beforeSearch = nil
                    return
                }
                if let first = cards.first(where: { Search.matches($0, q) }) {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(first.id, anchor: .center) }
                }
            }
            .onChange(of: ui.currentMatch) { _, id in
                if let id, cards.contains(where: { $0.id == id }) {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(targeted ? 0.10 : 0.04)))
        .dropDestination(for: String.self) { items, _ in
            for s in items { if let id = Int64(s), let c = store.card(id) { store.move(c, to: status) } }
            return true
        } isTargeted: { targeted = $0 }
    }
}

