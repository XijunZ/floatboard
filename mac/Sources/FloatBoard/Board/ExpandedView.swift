import FloatBoardCore
import SwiftUI

/// The expanded board: add row and three columns with full details (Done grouped by day).
struct ExpandedView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState

    @State private var newTitle = ""
    @State private var newArea = ""
    @State private var newImportance: Importance = .medium
    /// Step the new task goes into; back to To do after each add.
    @State private var newStatus: Status = .todo
    @State private var hasDue = false
    @State private var newDue = AppTime.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var hasTime = false
    @State private var newTime = Due.nextHour
    enum AddField: String, Hashable { case status, title, importance, group }
    /// Which add-row control has keyboard focus (drives ← → across the whole row).
    @State private var nav: String?
    @FocusState private var addField: AddField?
    @FocusState private var searchFocused: Bool
    @State private var showGuide = false
    @State private var searchShown = false
    @State private var searchList = SearchList(results: [])   // the list under the search box (every area)
    @State private var listOpen = false
    @State private var searching = false
    @StateObject private var outside = OutsideClickMonitor()
    /// Round 37: the highlighted result shown live on its tab; Esc goes back.
    @StateObject private var previewer = SearchPreviewer<SearchPlace>()
    /// The tab a preview just switched to (that switch keeps the list open).
    @State private var previewTab: UIState.Tab?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch ui.tab {
            case .board:
                addRow
                if ui.goalFilter != nil { GoalFilterChip() }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Status.allCases) { Column(status: $0) }
                }
            case .calendar:
                CalendarView()
            case .jots:
                JotsTab()
            case .circle:
                CircleTab()
            case .decisions:
                DecisionsTab()
            case .resolutions:
                ResolutionsTab()
            case .settings:
                SettingsView()
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The search list, under the toolbar's search box (right). Shown while the box has text, until Esc or an item opens.
        .overlay(alignment: .topTrailing) {
            if listOpen && !ui.search.trimmingCharacters(in: .whitespaces).isEmpty {
                // A click anywhere else in the window closes the list, as Esc does (the query stays); the click still
                // goes to what was clicked (OutsideClickMonitor).
                SearchResultsPanel(list: $searchList, searching: searching) { activate($0) }
                    .background(GeometryReader { g in
                        Color.clear.onAppear { outside.keep = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in outside.keep = f }
                    })
                    .padding(.trailing, 10).padding(.top, 2)
            }
        }
        // Searched 150 ms after typing stops (people off the main thread): typing is never held up.
        .task(id: ui.search) {
            searching = true
            try? await Task.sleep(nanoseconds: 150_000_000) // try?-ok: a cancelled wait means a newer query replaced this one
            guard !Task.isCancelled else { return }
            let r = await SearchRun.results(ui.search, store: store)
            guard !Task.isCancelled else { return }
            searchList = SearchList(results: r)
            searchList.highlightTop()   // round 37: the top result, shown on its tab once typing has stopped
            searching = false
            if listOpen { previewer.typedTop(searchList.highlighted?.hit) }
        }
        .overlay(alignment: .bottom) { UndoDeleteBar() }
        .overlay(alignment: .bottom) { UndoUnlinkBar() }
        .sheet(isPresented: $ui.showReview) { WeeklyReviewView { ui.showReview = false } }
        .sheet(item: $ui.makeTask) { req in MakeTaskForm(request: req) { ui.makeTask = nil } }
        .decisionSheets()   // Decisions: Make decision form and review sheet
        // A tab whose area was switched off goes back to the board.
        .onChange(of: store.modules) { _, on in if let m = ui.tab.module, !on.contains(m) { ui.tab = .board } }
        .toolbar { toolbarContent }
        // No switching tabs while typing (round 22): the list shows where things are; the board still highlights its matches.
        .onChange(of: ui.search) { _, q in
            previewer.keystroke()
            listOpen = !q.trimmingCharacters(in: .whitespaces).isEmpty
            ui.currentMatch = orderedMatches.first
        }
        // Another tab picked in the toolbar: the list closes (a preview's own switch keeps it open).
        .onChange(of: ui.tab) { _, t in if t == previewTab { previewTab = nil } else { listOpen = false } }
        .onChange(of: listOpen) { _, open in
            if open { outside.onOutside = { listOpen = false }; outside.start() } else { outside.stop(); previewer.settle() }
        }
        .onDisappear { outside.stop() }
        .onChange(of: searchFocused) { _, on in if on && !ui.search.trimmingCharacters(in: .whitespaces).isEmpty { listOpen = true } }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardFocusSearch)) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardShowGuide)) { _ in showGuide = true }
        .onReceive(NotificationCenter.default.publisher(for: .floatBoardClearFocus)) { _ in
            searchFocused = false
            addField = nil
            nav = nil
        }
        .onAppear {
            wirePreviewer()
            newArea = store.resolve(newArea)
            focusIfWanted()
        }
        .onChange(of: ui.wantsAddFocus) { _, _ in focusIfWanted() }
    }

    private func focusIfWanted() {
        guard ui.wantsAddFocus else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            addField = .title
            ui.wantsAddFocus = false
        }
    }

    /// Native toolbar: tabs in the middle, Guide and pin on the right (search is the system search field).
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TabPicker(tab: $ui.tab, tabs: UIState.Tab.visible(store.modules))
        }
        // Push search / Guide / Pin to the right edge.
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItem(placement: .primaryAction) {
            // Always-visible search field (⌘F focuses it).
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $ui.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    // Enter: the highlighted result opens; with none highlighted, on the Board, the next match as before.
                    .onSubmit {
                        if listOpen, let r = searchList.highlighted { activate(r) }
                        else if ui.tab == .board { stepMatch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                        else if let first = searchList.rows.first(where: { $0.hit != nil }) { activate(first) }
                    }
                    // ↑/↓: the highlighted result shows on its tab at once (round 37); the focus stays here.
                    .onKeyPress(.downArrow) { listOpen = true; searchList.move(1); previewer.highlighted(searchList.highlighted?.hit); return .handled }
                    .onKeyPress(.upArrow) { searchList.move(-1); previewer.highlighted(searchList.highlighted?.hit); return .handled }
                    // Esc: the list closes and the tab goes back to where it was before the previews; a second Esc clears the search.
                    .onExitCommand { if listOpen { previewer.escape(); listOpen = false } else { endSearch() } }
                    .simultaneousGesture(TapGesture().onEnded { if !ui.search.isEmpty { listOpen = true } })   // a click shows the list again
                if !ui.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    // "2 of 5" (or "none") inside the field, then ✕ to exit the search.
                    let m = orderedMatches
                    Text(m.isEmpty ? "none"
                         : ui.currentMatch.flatMap { m.firstIndex(of: $0) }.map { "\($0 + 1) of \(m.count)" } ?? "\(m.count) found")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(m.isEmpty ? Color.red : Color.secondary)
                        .fixedSize()
                }
                if !ui.search.isEmpty {
                    Button { endSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Exit search (Esc)")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: ui.search.isEmpty ? 220 : 280, height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(searchFocused ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showGuide.toggle() } label: { Label("Guide", systemImage: "questionmark.circle") }
                .help("What the colours, marks and icons mean")
                .popover(isPresented: $showGuide, arrowEdge: .bottom) { GuideView() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { ui.pinned.toggle() } label: {
                Label(ui.pinned ? "Unpin" : "Pin", systemImage: ui.pinned ? "pin.fill" : "pin")
            }
            .help(ui.pinned ? "Pinned: stays on top and open when you click another app. Click to unpin."
                            : "Pin: keep the board on top and open when you click another app")
        }
    }

    /// A row of the list: a result opens on its tab (the list closes; the query stays, so the box shows the list again);
    /// "Show all N" shows that group's every result.
    private func activate(_ r: SearchList.Row) {
        if let k = r.showAll { searchList.expand(k); return }
        guard let h = r.hit else { return }
        listOpen = false
        previewer.commit(h)
    }

    /// Round 37: previews go to the result's tab (the list stays open); Enter or a click opens as before; Esc goes back.
    private func wirePreviewer() {
        previewer.here = { [weak ui] in ui.map { SearchPlace(tab: $0.tab, match: $0.currentMatch) } }
        previewer.goBack = { [weak ui] p in
            guard let ui else { return }
            ui.reveals = PendingReveals()
            ui.tab = p.tab
            ui.currentMatch = p.match
            if p.tab == .board, let m = p.match { ui.reveals.pick(task: m, opens: false) }   // the board scrolls back to it
        }
        previewer.show = { [weak ui] h, opens in
            guard let ui else { return }
            if opens { SearchRun.open(h, ui: ui); return }
            let t = SearchRun.tab(SearchDestination.of(h.id.kind))
            if t != ui.tab { previewTab = t }
            SearchRun.preview(h, ui: ui)
        }
    }

    /// Esc / ✕: clear the search and leave the search box entirely (cursor out of it).
    private func endSearch() {
        listOpen = false
        ui.search = ""
        searchFocused = false
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func stepMatch(_ by: Int) {
        let m = orderedMatches
        guard !m.isEmpty else { return }
        let i = ui.currentMatch.flatMap { m.firstIndex(of: $0) } ?? -1
        ui.currentMatch = m[(i + by + m.count) % m.count]
        ui.searchCommitted = true
    }

    /// Matching tasks in board order: To do, Doing, Done, top to bottom.
    private var orderedMatches: [Int64] {
        guard !ui.search.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Status.allCases.flatMap { GoalFilter.apply(ui.goalFilter, store.cards(in: $0), store: store) }.filter { Search.matches($0, ui.search) }.map(\.id)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            KeyChip(options: Status.allCases, selection: $newStatus, title: \.title, color: { _ in .primary }, dot: false,
                    focus: $addField, field: .status,
                    onLeft: {}, onRight: { move("status", 1) }, onSubmit: add)
                .help("Step: ↑↓ to change, → to the group, Enter to add")
            KeyChip(options: store.areas.map(\.name), selection: $newArea, title: { $0 }, color: store.color,
                    focus: $addField, field: .group,
                    onLeft: { move("group", -1) }, onRight: { move("group", 1) }, onSubmit: add)
                .help("Group: ↑↓ to change, → to the task, Enter to add")
            TextField("Add a task: ↑↓ group, → importance, Enter to add", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(addField == .title ? Color.accentColor : Color.primary.opacity(0.12),
                                                lineWidth: addField == .title ? 2 : 1))
                .focused($addField, equals: .title)
                .onSubmit(add)
                .onKeyPress(.upArrow) { newArea = store.shift(store.resolve(newArea), by: -1); return .handled }
                .onKeyPress(.downArrow) { newArea = store.shift(store.resolve(newArea), by: 1); return .handled }
                .onKeyPress(.rightArrow) {
                    // At the end of the text, → moves on to Importance; otherwise it moves the cursor as usual.
                    guard Self.caretAtEnd() else { return .ignored }
                    move("title", 1)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    // At the start of the text, ← moves back to Group.
                    guard Self.caretAtStart() else { return .ignored }
                    move("title", -1)
                    return .handled
                }
            KeyChip(options: Importance.allCases, selection: $newImportance, title: \.label, color: \.color, dot: false,
                    focus: $addField, field: .importance,
                    onLeft: { move("importance", -1) }, onRight: { move("importance", 1) }, onSubmit: add)
                .help("Importance: ↑↓ to change, ←→ to move, Enter to add")
            DueFields(hasDue: $hasDue, day: $newDue, hasTime: $hasTime, time: $newTime, nav: chain)
            FocusButton(title: "Add", enabled: !newTitle.trimmingCharacters(in: .whitespaces).isEmpty,
                        nav: chain, navID: "add", action: add)
        }
        // Esc anywhere in the row leaves it; the typed title is kept (round 38).
        .leavesOnEsc { addField = nil; nav = nil }
        // Keep the shared ← → position and the title/importance/group focus in step.
        .onChange(of: nav) { _, n in if let f = AddField(rawValue: n ?? "") { addField = f } }
        .onChange(of: addField) { _, f in if let f { nav = f.rawValue } }
    }

    /// Whether the text cursor is at the very end of the focused text field.
    static func caretAtEnd() -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let r = tv.selectedRange()
        return r.length == 0 && r.location >= (tv.string as NSString).length
    }

    static func caretAtStart() -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let r = tv.selectedRange()
        return r.length == 0 && r.location == 0
    }

    private var chain: NavChain { NavChain(current: $nav, move: move, submit: add) }

    /// Order of the add row's controls for ← →; the date/time parts only exist when ticked.
    private var navOrder: [String] {
        ["status", "group", "title", "importance", "due"]
            + (hasDue ? ["date", "timeOn"] + (hasTime ? ["time"] : []) : [])
            + ["add"]
    }

    private func move(_ from: String, _ by: Int) {
        let o = navOrder
        guard let i = o.firstIndex(of: from), o.indices.contains(i + by) else { return }
        nav = o[i + by]
    }

    private func add() {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(title: newTitle, area: store.resolve(newArea), importance: newImportance,
                  due: hasDue ? Due.combine(day: newDue, time: hasTime ? newTime : nil) : nil, dueHasTime: hasDue && hasTime, status: newStatus)
        newTitle = ""
        newStatus = .todo
        // Next task starts fresh: no due date or time.
        hasDue = false
        hasTime = false
        newDue = AppTime.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        newTime = Due.nextHour
        addField = .title
        nav = "title"
    }
}

extension SortKey {
    /// Menu wording in a column header (says what the order is, not just the attribute).
    var columnTitle: String {
        switch self {
        case .due: "Due date"
        case .importance: "Importance"
        case .group: "Group"
        case .added: "Date added"
        case .status: "Status"
        }
    }
}


/// The window's tabs (in the toolbar).
struct TabPicker: View {
    @Binding var tab: UIState.Tab
    var tabs: [UIState.Tab] = UIState.Tab.allCases
    var body: some View {
        Picker("View", selection: $tab) {
            ForEach(tabs, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}
