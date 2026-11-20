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
            ui.reveals.pick(task: h.id.number)   // the column scrolls to it once it's on screen (also from another tab); replaces any older request
        case .event:
            ui.reveals.pick(event: h.id.number, day: h.date)  // its block opens its panel once the day is on screen; replaces any older request
            ui.calendarFocus = h.date
            ui.tab = .calendar
        default:
            ui.reveals.pickOther()   // nothing of the board's or the Calendar's is left waiting
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

/// Closes the search list on a click outside it without taking the click (round 24): a local monitor for mouse-down
/// that only notes where the click was; the event goes on unchanged, so what was clicked gets it and focus moves there.
@MainActor final class OutsideClickMonitor: ObservableObject {
    /// The list's frame in window coordinates (top left), kept by the list itself.
    var keep: CGRect = .zero
    var onOutside: () -> Void = {}
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                let h = e.window?.contentView?.bounds.height ?? 0
                let p = CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)
                if OutsideClick.closes(at: p, keep: [self.keep]) { self.onOutside() }
            }
            return e
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Round 24 checks in a real window (`FLOATBOARD_ROUND24SHOTS=1`, scratch database only), printed as ROUND24 lines:
/// - a click on another field while the search list is open closes the list, and typing then goes to that field;
/// - an evening event picked in search stays in view with its panel open (the request acknowledged after it opened).
@MainActor enum Round24Shots {
    final class Model: ObservableObject { @Published var add = ""; @Published var listOpen = true }

    struct Harness: View {
        @ObservedObject var m: Model
        @StateObject private var outside = OutsideClickMonitor()
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Add a task", text: $m.add).textFieldStyle(.roundedBorder).frame(width: 240)
                if m.listOpen {
                    Text("the list").frame(width: 200, height: 120).background(Color.gray.opacity(0.2))
                        .background(GeometryReader { g in Color.clear.onAppear { outside.keep = g.frame(in: .global) } })
                }
                Spacer()
            }
            .padding(20).frame(width: 400, height: 300)
            .onAppear { outside.onOutside = { m.listOpen = false }; outside.start() }
        }
    }

    static func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        guard LocalData.isScratchDatabase else { say("Round24Shots: scratch database only"); return }
        NSApp.setActivationPolicy(.accessory)
        // 1. Outside click: a titled window, so it can be key and take typing.
        let m = Model()
        let host = NSHostingView(rootView: Harness(m: m))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000)); w.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        say("ROUND24 step: window up, key \(w.isKeyWindow)")
        let field = CGPoint(x: 20 + 120, y: host.bounds.height - 20 - 11)   // the field's middle, in window coordinates
        func mouse(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: field, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // The up is queued first: a field's mouse-down tracks until it sees the up.
        if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = mouse(.leftMouseDown) { NSApp.sendEvent(down) }   // through the app, as a real click (the monitor sees it)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        say("ROUND24 step: clicked, first responder \(String(describing: type(of: w.firstResponder as Any)))")
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) {
            w.sendEvent(e)   // to the window's first responder (the window isn't key in a background run)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        say("ROUND24 outside-click: list \(m.listOpen ? "still open" : "closed"), field text \"\(m.add)\"")
        w.close()

        // 2. An evening event picked in search.
        Snapshot.seedCalendar(store)
        let cal = AppTime.calendar
        let eight = cal.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        let cache = CalendarCache(store: store)
        cache.apply(account: "me@example.com", calendarID: "me@example.com",
                    changes: [GoogleEventChange(eventID: "evening", cancelled: false,
                                                fields: CalEventFields(start: eight, end: eight.addingTimeInterval(3600), title: "Evening dinner", videoLink: "", googleUpdated: Date()))],
                    nextToken: nil)
        guard let ev = cache.event(account: "me@example.com", calendarID: "me@example.com", eventID: "evening") else { say("ROUND24 no event"); return }
        let ch = NSHostingView(rootView: CalendarView(span: .day).padding(12).frame(width: 900, height: 520)
            .environmentObject(store).environmentObject(ui).environmentObject(google))
        ch.frame = CGRect(x: 0, y: 0, width: 900, height: 520)
        let cw = NSWindow(contentRect: ch.frame, styleMask: [.titled], backing: .buffered, defer: false)
        cw.isReleasedWhenClosed = false; cw.contentView = ch
        cw.setFrameOrigin(NSPoint(x: -30000, y: -30000)); cw.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        SearchRun.open(SearchHit(id: ShortID(kind: .event, number: ev.shortID), title: ev.title, detail: "", date: ev.start), ui: ui)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        ch.layoutSubtreeIfNeeded()
        let popovers = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }.count
        if let rep = ch.bitmapImageRepForCachingDisplay(in: ch.bounds) {
            ch.cacheDisplay(in: ch.bounds, to: rep)
            let file = URL(fileURLWithPath: dir).appendingPathComponent("round24-evening-event.png")
            do { try rep.representation(using: .png, properties: [:])?.write(to: file) } catch { say("ERR: \(error)") }
        }
        say("ROUND24 evening event: request \(ui.revealEvent == nil ? "acknowledged" : "still pending"), new windows (panel) \(popovers)")
        cw.close()
    }
}
