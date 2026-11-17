import FloatBoardCore
import SwiftUI

/// Pictures of the Resolutions area for review (`FLOATBOARD_RESOLUTIONSHOTS=1 … FloatBoard --snapshot <dir>`), light and
/// dark. Only on a scratch database: it switches the area on and adds made-up goals and tasks.
@MainActor enum ResolutionsSnapshots {
    static func run(dir: String, store: Store, ui: UIState, google: Google) {
        guard ProcessInfo.processInfo.environment["FLOATBOARD_RESOLUTIONSHOTS"] != nil, LocalData.isScratchDatabase else { return }
        Resolutions.register()
        store.setModule(.jots, on: true)
        store.setModule(.resolutions, on: true)
        let r = ResolutionStore(store: store)
        let cal = AppTime.calendar
        // A fixed day near a quarter's end, so the review banner shows.
        let now = cal.date(from: DateComponents(year: 2026, month: 12, day: 22, hour: 10)) ?? Date()
        let q = GoalPeriod.current(.quarter, now: now), y = GoalPeriod.current(.year, now: now)
        func made(_ res: Result<Goal, GoalRefusal>) -> Goal? { if case .success(let g) = res { return g } else { return nil } }
        let five = made(r.create(level: .fiveYear, period: GoalPeriod.current(.fiveYear, now: now),
                                 title: "Run a small, calm studio that pays for itself.\nLive half the year near family; write every week.", now: now))
        let y1 = made(r.create(level: .year, period: y, title: "Ship the assistant: jots, circle, decisions and goals", parent: five?.id, now: now))
        let y2 = made(r.create(level: .year, period: y, title: "Read 20 books, half of them in Chinese 读二十本书", parent: five?.id, now: now))
        let q1 = made(r.create(level: .quarter, period: q, title: "Jots and Circle live on the Mac and the phone", notes: "Done = used daily for two weeks.",
                               parent: y1?.id, now: now))
        let q2 = made(r.create(level: .quarter, period: q,
                               title: "A very long quarterly goal that goes on and on to show how the row wraps when it is expanded and clips when it is not",
                               parent: y2?.id, now: now))
        _ = made(r.create(level: .quarter, period: q.next, title: "Decisions recorder in daily use", parent: nil, now: now))
        var tasks: [ShortID] = []
        for (title, done) in [("Write the jots design", true), ("Capture window", true), ("Phone jots screen", false), ("Circle due list", false)] {
            store.add(title: title, area: store.areas.first?.name ?? "Personal", importance: .medium, due: nil, status: done ? .done : .todo)
            if let c = store.cards.last { tasks.append(ShortID(kind: .task, number: c.id)) }
        }
        if let q1 {
            for t in tasks { _ = r.linkWork(t, to: q1.id, now: now) }
            if let j = JotStore(store: store).create(text: "The capture window should stay out of the way.", now: now) { _ = r.linkWork(j.shortID, to: q1.id, now: now) }
            store.setTags(q1.shortID, primary: store.areas.first?.name, others: [])
        }
        if let q2 { _ = r.linkWork(tasks[0], to: q2.id, now: now) }
        _ = y2
        func shot<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: v.environmentObject(store).environmentObject(ui).environmentObject(google)
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.appearance = host.appearance
                w.contentView = host
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                defer { w.close() }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let file = name + (scheme == .dark ? "-dark" : "-light") + ".png"
                do { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file)) } catch {
                    store.activity("snapshot", .error, "Could not write the snapshot image \(file)", detail: "\(error)")
                }
            }
        }
        shot(ResolutionsTab(now: now).padding(12), "resolutions-tab", CGSize(width: 800, height: 720))
        if let q1 {
            shot(ResolutionsTab(now: now, expanded: [q1.id, q2?.id ?? 0]).padding(12), "resolutions-tab-expanded", CGSize(width: 800, height: 1100))
        }
        shot(ReviewSheet(period: q, close: {}, now: now), "resolutions-review", CGSize(width: 600, height: 560))
        if let t = tasks.last, let card = store.card(t.number) {
            shot(EditCardView(draft: card) {}, "resolutions-task-editor", CGSize(width: 420, height: 600))
        }
        if let q1 {
            ui.goalFilter = q1.shortID
            shot(VStack(alignment: .leading) {
                GoalFilterChip()
                HStack(alignment: .top, spacing: 10) { ForEach(Status.allCases) { Column(status: $0) } }
            }.padding(12), "resolutions-board-filter", CGSize(width: 900, height: 360))
            ui.goalFilter = nil
        }
    }
}
