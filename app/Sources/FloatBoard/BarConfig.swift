import FloatBoardCore
import SwiftUI

/// User-configurable bar: the order tasks appear in, and which details each task shows.
/// Saved in UserDefaults; edited on the "Bar" tab with drag and drop.
struct BarConfig: Codable, Equatable {
    enum SortKey: String, Codable, CaseIterable, Identifiable {
        case due, status, importance, group, added
        var id: String { rawValue }
        var title: String {
            switch self {
            case .due: "Due date"
            case .status: "Status"
            case .importance: "Importance"
            case .group: "Group"
            case .added: "Date added"
            }
        }
        var detail: String {
            switch self {
            case .due: "Soonest first; tasks without a date after"
            case .status: "Doing before To do"
            case .importance: "High, then Medium, then Low"
            case .group: "In the order set on the Groups tab"
            case .added: "Oldest first"
            }
        }
    }

    enum Field: String, Codable, CaseIterable, Identifiable {
        case groupDot, title, dueDate, dueTime, importance, groupName
        var id: String { rawValue }
        var title: String {
            switch self {
            case .groupDot: "Group dot"
            case .title: "Title"
            case .dueDate: "Due date (MM-DD)"
            case .dueTime: "Due time (HH:MM)"
            case .importance: "Importance (! marks)"
            case .groupName: "Group name"
            }
        }
    }

    struct Item<T: Codable & Equatable>: Codable, Equatable { var key: T; var on: Bool }

    enum StatusFilter: String, Codable, CaseIterable, Identifiable {
        case both, doing, todo
        var id: String { rawValue }
        var title: String { switch self { case .both: "Both"; case .doing: "Doing only"; case .todo: "To do only" } }
    }
    enum DueFilter: String, Codable, CaseIterable, Identifiable {
        case any, today, week, hasDue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: "Any"
            case .today: "Overdue & today"
            case .week: "Next 7 days"
            case .hasDue: "Has a due date"
            }
        }
    }
    // Optional so settings saved by earlier versions still load.
    var statusFilter: StatusFilter? = .both
    var dueFilter: DueFilter? = .any
    /// Counter at the left of the bar: "7 tasks" or "4 doing · 3 to do". Always counts every open task.
    var splitCount: Bool? = false

    func countLabel(_ shown: [Card]) -> String {
        if splitCount ?? false {
            let doing = shown.filter { $0.status == .doing }.count
            return "\(doing) doing · \(shown.count - doing) to do"
        }
        return shown.count == 1 ? "1 task" : "\(shown.count) tasks"
    }

    /// Which open tasks appear on the bar.
    func filtered(_ cards: [Card]) -> [Card] {
        let cal = Calendar.current
        let endToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let endWeek = cal.date(byAdding: .day, value: 7, to: endToday)!
        return cards.filter { c in
            guard c.status != .done else { return false }
            switch statusFilter ?? .both {
            case .both: break
            case .doing: if c.status != .doing { return false }
            case .todo: if c.status != .todo { return false }
            }
            switch dueFilter ?? .any {
            case .any: return true
            case .hasDue: return c.due != nil
            case .today: return c.due.map { $0 < endToday } ?? false
            case .week: return c.due.map { $0 < endWeek } ?? false
            }
        }
    }

    var sort: [Item<SortKey>] = [
        .init(key: .due, on: true), .init(key: .status, on: true), .init(key: .importance, on: true),
        .init(key: .added, on: true), .init(key: .group, on: false),
    ]
    var fields: [Item<Field>] = [
        .init(key: .groupDot, on: true), .init(key: .title, on: true), .init(key: .dueDate, on: true),
        .init(key: .dueTime, on: false), .init(key: .importance, on: false), .init(key: .groupName, on: false),
    ]

    /// Unreadable saved settings are kept under `barConfig.broken` and logged once (see `Store.loadJSONSetting`); the bar uses defaults.
    @MainActor
    static func load(store: Store, defaults: UserDefaults = .standard) -> BarConfig {
        guard var c = store.loadJSONSetting(BarConfig.self, defaults: defaults, key: "barConfig", brokenKey: "barConfig.broken",
                                            what: "bar settings") else { return BarConfig() }
        // Add any options introduced after this config was saved.
        for k in SortKey.allCases where !c.sort.contains(where: { $0.key == k }) { c.sort.append(.init(key: k, on: false)) }
        for f in Field.allCases where !c.fields.contains(where: { $0.key == f }) { c.fields.append(.init(key: f, on: false)) }
        return c
    }

    @MainActor
    func save(store: Store?) {
        do { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "barConfig") } catch {
            store?.activity("settings", .error, "Could not save the bar settings", detail: "\(error)")
        }
    }

    var shownFields: [Field] { fields.filter(\.on).map(\.key) }

    /// Sort tasks by the enabled keys, in order; ties fall through to the next key.
    func sorted(_ cards: [Card], groupOrder: [String]) -> [Card] {
        let keys = sort.filter(\.on).map(\.key)
        return filtered(cards).sorted { a, b in
            for k in keys {
                switch k {
                case .due:
                    switch (a.dueSortKey, b.dueSortKey) {
                    case let (x?, y?) where x != y: return x < y
                    case (.some, nil): return true
                    case (nil, .some): return false
                    default: break
                    }
                case .status:
                    if a.status != b.status { return a.status == .doing }
                case .importance:
                    if a.importance != b.importance { return a.importance.rawValue > b.importance.rawValue }
                case .group:
                    let ia = groupOrder.firstIndex(of: a.area) ?? .max, ib = groupOrder.firstIndex(of: b.area) ?? .max
                    if ia != ib { return ia < ib }
                case .added:
                    if a.created != b.created { return a.created < b.created }
                }
            }
            return a.id < b.id
        }
    }
}

/// "Bar" tab: live preview + drag-and-drop order and fields.
struct BarSettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview").font(.system(size: 13, weight: .semibold))
            // Exactly as the bar shows them (full titles); scroll sideways if they don't fit.
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(barCards) { Chip(card: $0).fixedSize() }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show on the bar").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        Text("Status").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Picker("", selection: Binding(get: { ui.bar.statusFilter ?? .both }, set: { ui.bar.statusFilter = $0 })) {
                            ForEach(BarConfig.StatusFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HStack(spacing: 8) {
                        Text("Due").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Picker("", selection: Binding(get: { ui.bar.dueFilter ?? .any }, set: { ui.bar.dueFilter = $0 })) {
                            ForEach(BarConfig.DueFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Toggle("Split the count into Doing and To do (e.g. \u{201C}4 doing · 3 to do\u{201D})",
                           isOn: Binding(get: { ui.bar.splitCount ?? false }, set: { ui.bar.splitCount = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
                section("Order: what comes first",
                        "Drag to set precedence. Ties are decided by the next ticked rule.") {
                    List {
                        ForEach($ui.bar.sort, id: \.key) { $item in
                            row(on: $item.on, title: item.key.title, detail: item.key.detail,
                                index: ui.bar.sort.firstIndex(of: item) ?? 0, count: ui.bar.sort.count) { from, to in
                                ui.bar.sort.swapAt(from, to)
                            }
                        }
                        .onMove { ui.bar.sort.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                }
                section("What each task shows",
                        "Drag to arrange, tick to show.") {
                    List {
                        ForEach($ui.bar.fields, id: \.key) { $item in
                            row(on: $item.on, title: item.key.title, detail: nil,
                                index: ui.bar.fields.firstIndex(of: item) ?? 0, count: ui.bar.fields.count) { from, to in
                                ui.bar.fields.swapAt(from, to)
                            }
                        }
                        .onMove { ui.bar.fields.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
            }
            Button("Reset to defaults") { ui.bar = BarConfig() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var barCards: [Card] {
        ui.bar.sorted(store.cards.filter { $0.status != .done && !$0.withdrawn }, groupOrder: store.areas.map(\.name))
    }

    private func section<C: View>(_ title: String, _ hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 250)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(on: Binding<Bool>, title: String, detail: String?, index: Int, count: Int,
                     swap: @escaping (Int, Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on.wrappedValue ? Color.primary : Color.secondary)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            // Click-to-move, for when dragging isn't convenient.
            Button { swap(index, index - 1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0).help("Move up")
            Button { swap(index, index + 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index >= count - 1).help("Move down")
        }
        .padding(.vertical, 2)
    }
}
