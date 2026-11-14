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
    @State private var newDue = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var hasTime = false
    @State private var newTime = Due.nextHour
    enum AddField: String, Hashable { case status, title, importance, group }
    /// Which add-row control has keyboard focus (drives ← → across the whole row).
    @State private var nav: String?
    @FocusState private var addField: AddField?
    @FocusState private var searchFocused: Bool
    @State private var showGuide = false
    @State private var searchShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch ui.tab {
            case .board:
                addRow
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Status.allCases) { Column(status: $0) }
                }
            case .bar:
                BarSettingsView()
            case .groups:
                GroupsView()
            case .connectors:
                ConnectorsView()
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { UndoDeleteBar() }
        .toolbar { toolbarContent }
        .onChange(of: ui.search) { _, q in
            if !q.isEmpty { ui.tab = .board }
            ui.currentMatch = orderedMatches.first
        }
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
            Picker("View", selection: $ui.tab) {
                ForEach(UIState.Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        // Push search / Guide / Pin to the right edge.
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItem(placement: .primaryAction) {
            // Always-visible search field (⌘F focuses it).
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks", text: $ui.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { stepMatch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                    .onExitCommand { endSearch() }
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

    /// Esc / ✕: clear the search and leave the search box entirely (cursor out of it).
    private func endSearch() {
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
        return Status.allCases.flatMap { store.cards(in: $0) }.filter { Search.matches($0, ui.search) }.map(\.id)
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
                  due: hasDue ? Due.combine(day: newDue, time: hasTime ? newTime : nil) : nil, status: newStatus)
        newTitle = ""
        newStatus = .todo
        // Next task starts fresh: no due date or time.
        hasDue = false
        hasTime = false
        newDue = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
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
        let cards = sort.apply(store.cards(in: status), groupOrder: store.areas.map(\.name))
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
                        let groups = Dictionary(grouping: cards) { Calendar.current.startOfDay(for: $0.done ?? $0.created) }
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

struct CardView: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: Store
    let card: Card
    @State private var hover = false
    @State private var editing = false

    private var searching: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isMatch: Bool { searching && Search.matches(card, ui.search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(store.color(card.area)).frame(width: 8, height: 8).padding(.top, 4)
                Text(searching ? Search.highlighted(card.title, ui.search) : AttributedString(card.title))
                    .font(.system(size: 13, weight: .medium)).lineLimit(3)
                    .strikethrough(card.status == .done, color: .secondary)
                Spacer(minLength: 4)
                if let meet = card.meetingLink {
                    Button { NSWorkspace.shared.open(meet) } label: {
                        Label("Join", systemImage: "video.fill").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Join call: \(meet.absoluteString)")
                } else if let other = card.otherLink {
                    Button { NSWorkspace.shared.open(other) } label: {
                        Label("Open", systemImage: "link").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Open link: \(other.absoluteString)")
                }
                // Importance tag: monochrome "!" marks in an outlined capsule
                // (groups are filled, coloured pills, so the two don't look alike or clash).
                Text(card.importance.marks)
                    .font(.system(size: 11, weight: card.importance.weight, design: .rounded))
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(card.importance.color.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(card.importance.color)
                    .contentShape(Rectangle())
                    // Click: Low → Medium → High → Low. Right-click: pick one.
                    .onTapGesture {
                        let all = Importance.allCases
                        let next = all[((all.firstIndex(of: card.importance) ?? 0) + 1) % all.count]
                        store.setImportance(card, next)
                    }
                    .contextMenu {
                        ForEach(Importance.allCases) { imp in
                            Button { store.setImportance(card, imp) } label: {
                                if imp == card.importance { Label(imp.title, systemImage: "checkmark") } else { Text(imp.title) }
                            }
                        }
                    }
                    .help("\(card.importance.title) importance: click to change, right-click to choose")
            }
            if !card.notes.isEmpty {
                Text(card.notes).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            if !card.aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI summary").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(card.aiSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            FlowLayout(hSpacing: 10, vSpacing: 3) {
                Text(card.area)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(store.color(card.area).opacity(0.18)))
                    .foregroundStyle(store.color(card.area))
                    .contentShape(Capsule())
                    // Click: next group. Right-click: pick one.
                    .onTapGesture { store.setArea(card, store.shift(card.area, by: 1)) }
                    .contextMenu {
                        ForEach(store.areas) { a in
                            Button { store.setArea(card, a.name) } label: {
                                if a.name == card.area { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                            }
                        }
                    }
                    .help("Click to change group (right-click to choose)")
                if card.showsSourceChip { ProposalChip(card: card) }
                if card.status == .watch, card.watchSince != nil {
                    // Time on Watch, updated every minute; amber from 3 days (when a chase reminder goes out).
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let late = Watch.isLate(card, now: ctx.date)
                        Label(Watch.line(card, now: ctx.date) ?? "", systemImage: "hourglass")
                            .fontWeight(late ? .semibold : .regular)
                            .foregroundStyle(late ? Color.orange : Color.secondary)
                            .fixedSize()
                            .help((card.watchPerson.isEmpty ? "Waiting" : "Waiting on \(card.watchPerson)") + " since it went to Watch. "
                                  + (card.watchContact.isEmpty ? "No contact: it won't move back by itself when they reply. Add one in the task (double-click)."
                                     : "Moves back to To do when they reply (\(card.watchContact.hasPrefix("wa:") ? "on WhatsApp" : "by email")). A reminder every 3 days until then."))
                    }
                }
                Text("Added \(Fmt.short(card.created))").fixedSize()
                if let due = card.due {
                    Text("Due \(Fmt.due(due))")
                        .foregroundStyle(card.isOverdue ? Color.red : Color.secondary)
                        .fontWeight(card.isOverdue ? .semibold : .regular)
                        .fixedSize()
                }
                if let d = card.done { Text("Done \(Fmt.withTime(d))").fixedSize() }
                if !card.gcalAccount.isEmpty {
                    Button { if let u = URL(string: card.gcalLink) { NSWorkspace.shared.open(u) } } label: {
                        Image(systemName: "calendar.badge.checkmark")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("In Google Calendar (\(card.gcalAccount)). Click to open the event.")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if hover {
                HStack(spacing: 2) {
                    if let p = card.status.prev {
                        BarButton("arrow.left", "Move to \(p.title)") { store.move(card, to: p) }
                    }
                    if let n = card.status.next {
                        BarButton(n == .done ? "checkmark" : "arrow.right", "Move to \(n.title)") { store.move(card, to: n) }
                    }
                    if card.status == .todo || card.status == .doing {
                        BarButton("eye", "Move to Watch (waiting on someone else)") { store.move(card, to: .watch) }
                    }
                    Spacer()
                    if card.due != nil { CalendarMenu(card: card) }
                    BarButton("pencil", "Edit") { editing = true }
                    DeleteControl(card: card)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isMatch ? Color.accentColor.opacity(0.14)
                  : UrgencyStyle.fill(card.urgency, neutral: Color.primary.opacity(hover ? 0.10 : 0.06))))
        .overlay {
            if !isMatch {
                if card.urgency == .overdue {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(UrgencyStyle.ringColor, style: UrgencyStyle.ringStyle)
                } else if let tint = UrgencyStyle.tint(card.urgency) {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(tint, lineWidth: 1)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isMatch ? Color.accentColor : Color.clear, lineWidth: ui.currentMatch == card.id && isMatch ? 3.5 : 2))
        .id(card.id)
        .opacity(searching && !isMatch ? 0.3 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if isMatch { ui.searchCommitted = true }; editing = true }
        .draggable(String(card.id))
        .contextMenu {
            ForEach(Status.allCases.filter { $0 != card.status }) { s in
                Button("Move to \(s.title)") { store.move(card, to: s) }
            }
            Divider()
            Button("Edit…") { editing = true }
            if card.teachOnDelete {
                Menu("Delete") { ConnectorDeleteChoices(card: card) }
            } else {
                Button("Delete") { store.deleteCard(card, verdict: nil) }
            }
        }
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            EditCardView(draft: card) { editing = false }
        }
    }
}

/// "Deleted “…” · Undo" at the bottom of the board for 8 seconds after a delete (Edit → Undo Delete works after).
struct UndoDeleteBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let d = store.lastDeleted, d.barShown {
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text("Deleted “\(d.title)”").lineLimit(1).truncationMode(.tail)
                Button("Undo") { store.undoDelete() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Bring the task back (also Edit → Undo Delete, ⌥⌘Z)")
                Button { store.dismissUndoBar(for: d) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: d.at) {
                try? await Task.sleep(for: .seconds(8)) // try?-ok: cancelled when another delete replaces this bar
                if !Task.isCancelled { withAnimation { store.dismissUndoBar(for: d) } }
            }
        }
    }
}

/// Text with its web addresses turned into clickable links.
enum LinkedText {
    static func make(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out } // try?-ok: no detector = plain text
        for m in det.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let url = m.url, let r = Range(m.range, in: s), let ar = Range(r, in: out) else { continue }
            out[ar].link = url
        }
        return out
    }
}

struct EditCardView: View {
    @EnvironmentObject var store: Store
    @State var draft: Card
    var close: () -> Void
    @State private var hasDue = false
    @State private var day = Date()
    @State private var hasTime = false
    @State private var time = Due.nextHour

    /// Set when the pop-up closed via Save, Cancel or Delete (so closing it doesn't save again).
    @State private var finished = false
    @State private var replyDraftRefusal: String?
    /// "Link an email…" search shown in place; and why a link change was refused.
    @State private var linkingEmail = false
    @State private var linkRefusal: String?
    /// Size of the pop-up, set by dragging its corner (remembered).
    @AppStorage("editorWidth") private var width: Double = 420
    @AppStorage("editorExtraHeight") private var extraHeight: Double = 0
    @State private var dragStart: (w: Double, h: Double)?

    private func save() {
        finished = true
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft.due = hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil
        if let saved = store.card(draft.id) {
            // Don't overwrite calendar info that may have been set while the pop-up was open.
            draft.gcalAccount = saved.gcalAccount.isEmpty ? draft.gcalAccount : saved.gcalAccount
            // Reply draft fields are changed by the app and the engine, never by this editor.
            draft.replyDraftState = saved.replyDraftState; draft.replyDraftLink = saved.replyDraftLink
            draft.replyDraftError = saved.replyDraftError; draft.replyDraftRequest = saved.replyDraftRequest
            draft.replyDraftSentAt = saved.replyDraftSentAt
            draft.watchSince = saved.watchSince
            if saved.watchPerson != draft.watchPerson || saved.watchContact != draft.watchContact {
                store.setWatch(saved, person: draft.watchPerson, contact: draft.watchContact)
                guard let fresh = store.card(draft.id) else { return }
                draft.watchPerson = fresh.watchPerson; draft.watchContact = fresh.watchContact
            }
        }
        guard store.card(draft.id).map({ $0 != draft }) ?? false else { return }
        store.update(draft)
    }

    /// The task as currently edited (unsaved), for calendar/Join actions.
    private var pending: Card {
        var c = draft
        c.due = hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil
        return c
    }

    /// The stored card's reply draft state (the editor's own copy is a snapshot taken when it opened).
    private var replyDraftCard: Card { store.card(draft.id) ?? draft }

    private var notesEmpty: Bool { draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func requestReplyDraft() {
        replyDraftRefusal = nil
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { replyDraftRefusal = "Give the task a title first."; return }
        save()
        finished = false   // the editor stays open, so clicking away must still keep later edits
        do {
            try store.requestReplyDraft(cardID: draft.id)
            ConnectorRunner.shared?.trigger("reply draft")
        } catch {
            replyDraftRefusal = "\(error)"
        }
    }

    /// Draft reply button (cards made from an email) and the status of the latest request.
    @ViewBuilder private var replyDraftSection: some View {
        let card = replyDraftCard
        let waiting = card.replyDraftState == .requested
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Button { requestReplyDraft() } label: {
                    Label(card.replyDraftState == .failed ? "Try again" : "Draft reply", systemImage: "arrowshape.turn.up.left")
                }
                .disabled(notesEmpty || waiting)
                .help(notesEmpty ? "Write what to say in Notes first." : "Turn your Notes into a reply draft")
                if notesEmpty && card.replyDraftState == nil {
                    Text("Write what to say in Notes first").foregroundStyle(.secondary)
                } else if card.replyDraftState == .ready, let u = URL(string: card.replyDraftLink) {
                    Text("Draft ready").foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open draft", systemImage: "arrow.up.forward.square") }
                } else if waiting {
                    Text("Drafting reply…").foregroundStyle(.secondary)
                } else if card.replyDraftState == .failed {
                    Text("Couldn't draft: \(card.replyDraftError)").foregroundStyle(.red)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let r = replyDraftRefusal { Text(r).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    /// The stored card's email link (the editor's copy is a snapshot): copied in after a link change, so Save never
    /// compares against stale link fields.
    private func takeLink(from c: Card) {
        draft.connector = c.connector; draft.source = c.source; draft.sourceKey = c.sourceKey; draft.sourceLink = c.sourceLink
        draft.sourceMeta = c.sourceMeta; draft.externalID = c.externalID
        draft.replyDraftState = c.replyDraftState; draft.replyDraftLink = c.replyDraftLink; draft.replyDraftError = c.replyDraftError
        draft.replyDraftRequest = c.replyDraftRequest; draft.replyDraftSentAt = c.replyDraftSentAt
    }

    /// Open email, "Link an email…" (a task with no email that the sorting did not make), "Remove email link" (one the
    /// user linked), and the search when it is open.
    @ViewBuilder private var emailSection: some View {
        let card = replyDraftCard
        if linkingEmail {
            LinkEmailSearch(cardID: draft.id) { linked in
                linkingEmail = false
                if let linked { takeLink(from: linked) }
            }
        } else if card.emailLink != nil || card.canLinkEmail || card.emailLinkedByUser {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    if let mail = card.emailLink {
                        Button { NSWorkspace.shared.open(mail) } label: { Label("Open email", systemImage: "envelope") }
                            .help(card.sourceMeta["subject"] ?? mail.absoluteString)
                    }
                    if card.canLinkEmail {
                        Button { linkRefusal = nil; linkingEmail = true } label: { Label("Link an email…", systemImage: "envelope.badge") }
                            .help("Find an email in your Gmail and attach it to this task")
                    }
                    if card.emailLinkedByUser {
                        Button {
                            linkRefusal = nil
                            do {
                                try store.unlinkEmail(cardID: draft.id)
                                if let c = store.card(draft.id) { takeLink(from: c) }
                                ConnectorRunner.shared?.trigger("email unlinked")
                            } catch { linkRefusal = "\(error)" }
                        } label: { Label("Remove email link", systemImage: "xmark.circle") }
                    }
                }
                if let r = linkRefusal { Text(r).foregroundStyle(.red) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
    }

    /// Drag the bottom-right corner to make the pop-up wider or taller (Notes and the AI section grow).
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .padding(3)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = dragStart ?? (width, extraHeight)
                    dragStart = start
                    width = min(1000, max(360, start.w + g.translation.width))
                    extraHeight = min(700, max(0, start.h + g.translation.height))
                }
                .onEnded { _ in dragStart = nil })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .help("Drag to resize")
    }

    /// Watch: whom it waits on, and the email address whose reply moves it back (a WhatsApp chat is shown, not typed).
    private var waitingOn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Waiting on").foregroundStyle(.secondary)
                TextField("Name", text: $draft.watchPerson).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                if draft.watchContact.hasPrefix("wa:") {
                    Label("WhatsApp chat", systemImage: "bubble.left.and.bubble.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Clear") { draft.watchContact = "" }.buttonStyle(.link).font(.system(size: 11))
                } else {
                    TextField("Their email, to notice the reply (optional)", text: Binding(
                        get: { draft.watchContact.hasPrefix("email:") ? String(draft.watchContact.dropFirst(6)) : "" },
                        set: { v in let t = v.trimmingCharacters(in: .whitespaces); draft.watchContact = t.isEmpty ? "" : "email:\(t)" }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let line = Watch.line(draft) {
                Text(line + " · back to To do when they reply; a reminder every \(Watch.chaseDays) days until then")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...(8 + Int(extraHeight / 16))).textFieldStyle(.roundedBorder)
            if !draft.aiSummary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From the email or meeting (AI)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    // Grows with the pop-up: drag the corner down to read more.
                    Text(LinkedText.make(draft.aiSummary)).font(.system(size: 12)).textSelection(.enabled)
                        .lineLimit(6 + Int(extraHeight / 15))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            TextField("Link: a call (Meet, Zoom, Teams) or any web page (optional)", text: $draft.link)
                .textFieldStyle(.roundedBorder)
            if draft.status == .watch { waitingOn }
            HStack(spacing: 8) {
                Text("Group").foregroundStyle(.secondary)
                Dropdown(options: store.areas.map(\.name), selection: $draft.area, dot: store.color)
                Text("Importance").foregroundStyle(.secondary).padding(.leading, 8)
                Dropdown(options: Importance.allCases, selection: $draft.importance, title: \.label)
            }
            .font(.system(size: 12))
            HStack { DueFields(hasDue: $hasDue, day: $day, hasTime: $hasTime, time: $time) }
            HStack(spacing: 14) {
                if hasDue {
                    // Uses the date/time as currently set here, even before Save.
                    CalendarMenu(card: pending, labeled: true) { account, ev in
                        draft.gcalAccount = account
                        draft.gcalLink = ev.htmlLink
                        if let meet = ev.meetLink, draft.link.trimmingCharacters(in: .whitespaces).isEmpty {
                            draft.link = meet
                        }
                    }
                }
                if let meet = pending.meetingLink {
                    Button { NSWorkspace.shared.open(meet) } label: { Label("Join call", systemImage: "video.fill") }
                        .help(meet.absoluteString)
                }
                if let other = pending.otherLink {
                    Button { NSWorkspace.shared.open(other) } label: { Label("Open link", systemImage: "link") }
                        .help(other.absoluteString)
                }
                if !draft.gcalAccount.isEmpty, let u = URL(string: draft.gcalLink) {
                    Button { NSWorkspace.shared.open(u) } label: { Label("Open event", systemImage: "arrow.up.forward.square") }
                        .help("In \(draft.gcalAccount)'s Google Calendar")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            emailSection
            if replyDraftCard.canDraftReply { replyDraftSection }
            VStack(alignment: .leading, spacing: 2) {
                Text("Added \(Fmt.withTime(draft.created))")
                if let s = draft.started { Text("Started \(Fmt.withTime(s))") }
                if let d = draft.done { Text("Done \(Fmt.withTime(d))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete", role: .destructive) { finished = true; store.deleteCard(draft, verdict: nil); close() }
                Spacer()
                Button("Cancel") { finished = true; close() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: width)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // Clicking away (or the board collapsing) closes the pop-up: keep the edits.
        .onDisappear { if !finished { save() } }
        .onAppear {
            hasDue = draft.due != nil
            if let d = draft.due {
                day = d
                hasTime = Due.hasTime(d)
                if hasTime { time = d }
            }
        }
    }
}

/// "Due ☐ [date]  Time ☐ [hh:mm]": a due date, with an optional time for meetings.
struct DueFields: View {
    @Binding var hasDue: Bool
    @Binding var day: Date
    @Binding var hasTime: Bool
    @Binding var time: Date
    var nav: NavChain? = nil

    var body: some View {
        FocusCheck(label: "Due", isOn: $hasDue, nav: nav, navID: "due")
        if hasDue {
            DateInput(date: $day, nav: nav, navID: "date")
            FocusCheck(label: "Time", isOn: $hasTime, nav: nav, navID: "timeOn")
            if hasTime { TimeInput(time: $time, nav: nav, navID: "time") }
        }
    }
}

/// A drop-down that opens beside its button (not over it, like macOS pop-up pickers do),
/// with a tick on the current choice and an optional coloured dot per option.
struct Dropdown<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    var title: (T) -> String = { "\($0)" }
    var dot: ((T) -> Color)? = nil

    init(options: [T], selection: Binding<T>, title: @escaping (T) -> String = { "\($0)" }, dot: ((T) -> Color)? = nil) {
        self.options = options; self._selection = selection; self.title = title; self.dot = dot
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot(selection)).frame(width: 7, height: 7) }
                Text(title(selection))
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

/// A keyboard-friendly, colour-coded choice button for the add row.
/// Focused: ↑↓ change the value, ←→ move to the neighbouring control, Enter submits.
/// Clicked: shows the list of choices.
struct KeyChip<T: Hashable, F: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    let color: (T) -> Color
    /// Coloured dot (groups); importance passes false and is shown by its "!" marks instead.
    var dot = true
    var focus: FocusState<F?>.Binding
    let field: F
    var onLeft: () -> Void
    var onRight: () -> Void
    var onSubmit: () -> Void

    private var focused: Bool { focus.wrappedValue == field }

    var body: some View {
        let c = color(selection)
        HStack(spacing: 5) {
            if dot { Circle().fill(c).frame(width: 8, height: 8) }
            Text(title(selection)).foregroundStyle(c)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // Same language as the cards: group = filled tinted capsule, importance = outlined capsule.
        .background(Capsule().fill(dot ? c.opacity(0.18) : Color.clear))
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor : (dot ? Color.clear : c.opacity(0.6)),
                                        lineWidth: focused ? 2 : 1))
        .fixedSize()
        .contentShape(Rectangle())
        .focusable(interactions: .edit)
        .focused(focus, equals: field)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.leftArrow) { onLeft(); return .handled }
        .onKeyPress(.rightArrow) { onRight(); return .handled }
        .onKeyPress(.return) { onSubmit(); return .handled }
        .onTapGesture { focus.wrappedValue = field; showMenu() }
    }

    private func step(_ by: Int) {
        guard let i = options.firstIndex(of: selection), !options.isEmpty else { return }
        selection = options[(i + by + options.count) % options.count]
    }

    private func showMenu() {
        let menu = NSMenu()
        for o in options {
            let item = ClosureMenuItem(title: title(o)) { selection = o }
            item.state = o == selection ? .on : .off
            if dot {
                item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                    NSColor(color(o)).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
                }
            }
            menu.addItem(item)
        }
        // Open just below the pointer, so it never covers the button itself.
        let p = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: p.x - 10, y: p.y - 14), in: nil)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

extension Notification.Name {
    static let floatBoardResetBoard = Notification.Name("FloatBoardResetBoard")
    static let floatBoardShowGuide = Notification.Name("FloatBoardShowGuide")
    static let floatBoardFocusSearch = Notification.Name("FloatBoardFocusSearch")
    static let floatBoardClearFocus = Notification.Name("FloatBoardClearFocus")
}

/// Lays out items left to right and wraps whole items onto the next line when out of room.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + vSpacing; x = 0; rowH = 0 }
            x += s.width + hSpacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - hSpacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + vSpacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + hSpacing
            rowH = max(rowH, s.height)
        }
    }
}


/// Trash button; a card made by the email sorting offers "teach" choices so the sorting learns from the delete.
struct DeleteControl: View {
    @EnvironmentObject var store: Store
    let card: Card

    var body: some View {
        if !card.teachOnDelete {
            BarButton("trash", "Delete") { store.deleteCard(card, verdict: nil) }
        } else {
            Menu {
                ConnectorDeleteChoices(card: card)
            } label: {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Delete")
        }
    }
}
