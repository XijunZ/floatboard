import FloatBoardCore
import SwiftUI

/// The toolbar search (round 22): one box for every tab. As soon as it has text a list shows under it, grouped by where
/// each result lives (Tasks, Calendar, Jots, Circle, Decisions, Goals, only areas that are on), at most 5 a group with
/// "Show all N". Clicking a row, or Enter on the highlighted one, opens it on its tab; there is no switching tabs while
/// typing. On the Board the board itself still filters and highlights matching tasks as before.
@MainActor enum SearchRun {
    /// Every kind's matches for `q` (an id finds exactly that item); people are matched off the main thread.
    static func results(_ q: String, store: Store) async -> [(ItemKind, [SearchHit])] {
        let typedID = ShortID.parse(q.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        var out = GlobalSearch.run(q, store: store, limit: 200, skipping: typedID || !store.isOn(.circle) ? [] : [.person])
        if !typedID && store.isOn(.circle) {
            let people = SearchIndex.people(store: store)
            let hits = await Task.detached { SearchIndex.match(people, q) }.value
            guard !Task.isCancelled else { return out }
            if !hits.isEmpty { out.append((.person, Array(hits.prefix(200)).map(\.hit))) }
        }
        return out
    }

    /// Opens a result where it lives: a task on the board (found and outlined; the query stays), an event on its day in
    /// the Calendar, other kinds where their area says (until an area registers, the id is copied).
    static func open(_ h: SearchHit, ui: UIState) {
        switch h.id.kind {
        case .task:
            ui.tab = .board
            ui.currentMatch = h.id.number
            ui.searchCommitted = true
            ui.revealTask = RevealRequest(h.id.number)   // the column scrolls to it once it's on screen (also from another tab)
        case .event:
            ui.revealEvent = RevealRequest(h.id.number)  // its block opens its panel once the day is on screen
            ui.calendarFocus = h.date
            ui.tab = .calendar
        default:
            if let handler = GlobalSearchOpen.handlers[h.id.kind] { handler(h.id) } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(h.id.text, forType: .string)
            }
        }
    }
}

/// How each area opens one of its items from search (registered by the area: its tab, scrolled to the item).
@MainActor enum GlobalSearchOpen {
    static var handlers: [ItemKind: (ShortID) -> Void] = [:]
}

/// The list under the search box.
struct SearchResultsPanel: View {
    @Binding var list: SearchList
    var searching: Bool
    var activate: (SearchList.Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if list.rows.isEmpty {
                Text(searching ? "Searching…" : "Nothing found in any area.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(list.groups, id: \.kind) { g in
                                Text("\(g.title) \(g.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                ForEach(list.rows(of: g.kind)) { r in row(r).id(r.id) }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .onChange(of: list.highlight) { _, _ in if let r = list.highlighted { proxy.scrollTo(r.id) } }
                }
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    @ViewBuilder private func row(_ r: SearchList.Row) -> some View {
        let on = list.highlighted == r
        Button { activate(r) } label: {
            HStack(spacing: 8) {
                if let h = r.hit {
                    Image(systemName: Self.icon(h.id.kind)).frame(width: 16).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.title).lineLimit(1)
                        if !h.detail.isEmpty { Text(h.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Text(h.id.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07)))
                } else if let k = r.showAll {
                    Text("Show all \(list.groups.first { $0.kind == k }?.count ?? 0)").foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.18) : Color.clear))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    static func icon(_ k: ItemKind) -> String {
        switch k {
        case .task: "checklist"; case .event: "calendar"; case .jot: "square.and.pencil"; case .person: "person"
        case .decision: "arrow.triangle.branch"; case .resolution: "target"
        }
    }
}

/// Round 22 pictures (`FLOATBOARD_ROUND22SHOTS=1 FloatBoard --snapshot <dir>`): the list with results from several areas
/// (one group past 5, one row highlighted) and with none, light and dark.
@MainActor enum Round22Shots {
    static func run(dir: String) {
        func hit(_ k: ItemKind, _ n: Int64, _ t: String, _ d: String) -> SearchHit { SearchHit(id: ShortID(kind: k, number: n), title: t, detail: d, date: nil) }
        var mixed = SearchList(results: [
            (.task, [hit(.task, 142, "Send the revised budget to the team", "To do · Work"), hit(.task, 97, "Budget review with finance", "Done · Work")]),
            (.event, [hit(.event, 37, "Budget planning", "Tue 24 Nov 10:00")]),
            (.jot, (1...7).map { hit(.jot, Int64(10 + $0), "Budget note \($0): costs for the offsite", "\($0) Nov · Work") }),
            (.person, [hit(.person, 4, "Ann Example", "Close friend · Northwind")]),
            (.decision, [hit(.decision, 3, "Keep the budget flat this quarter", "Strategic · recorded 18 Nov")]),
            (.resolution, [hit(.resolution, 2, "Keep costs flat this quarter", "Q4 2026")]),
        ])
        mixed.move(1); mixed.move(1); mixed.move(1)
        let none = SearchList(results: [])
        for (name, list) in [("round22-search-mixed", mixed), ("round22-search-none", none)] {
            for scheme in [ColorScheme.light, .dark] {
                let v = SearchResultsPanel(list: .constant(list), searching: false) { _ in }
                    .padding(20).frame(width: 400, height: name.hasSuffix("none") ? 120 : 500, alignment: .top)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: v)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(x: 0, y: 0, width: 400, height: name.hasSuffix("none") ? 120 : 500)
                let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false; w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000)); w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let file = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                    do { try rep.representation(using: .png, properties: [:])?.write(to: file) } catch { print("ERR: \(name): \(error)") }
                }
                w.close()
            }
        }
    }
}

/// Round 23 picture (`FLOATBOARD_ROUND23SHOTS=1`, scratch database only): a task far down the To do column picked in
/// search while the Calendar tab shows; the board then appears scrolled to it (outlined as the current match).
@MainActor enum Round23Shots {
    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        guard LocalData.isScratchDatabase else { print("Round23Shots: scratch database only"); return }
        for i in 1...40 { store.add(title: String(format: "Task %02d", i), area: store.areas.first?.name ?? "Work", importance: .medium, due: nil) }
        guard let target = store.cards.first(where: { $0.title == "Task 38" }) else { print("Round23Shots: no task"); return }
        struct Root: View {
            @EnvironmentObject var ui: UIState
            var body: some View {
                Group { if ui.tab == .board { Column(status: .todo) } else { Text("Calendar").frame(maxWidth: .infinity, maxHeight: .infinity) } }
                    .frame(width: 320, height: 420)
            }
        }
        ui.tab = .calendar
        ui.search = "Task 38"
        let host = NSHostingView(rootView: Root().environmentObject(store).environmentObject(ui).environmentObject(google))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
        let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000)); w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        SearchRun.open(SearchHit(id: ShortID(kind: .task, number: target.id), title: target.title, detail: "", date: nil), ui: ui)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = URL(fileURLWithPath: dir).appendingPathComponent("round23-task-from-calendar.png")
            do { try rep.representation(using: .png, properties: [:])?.write(to: file) } catch { print("ERR: \(error)") }
        }
        print("ROUND23 revealTask pending after: \(ui.revealTask == nil ? "taken" : "still pending")")
        w.close()
    }
}
