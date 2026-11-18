import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// Where the Circle tab is: the person shown, and a pending "Add to Circle" (from a right-click on a name).
@MainActor final class CircleNav: ObservableObject {
    static let shared = CircleNav()
    @Published var selected: Int64?
    @Published var addRequest: PersonFormRequest?
    @Published var showSuggestions = false
}

/// Circle's background work while it is on (stopped when it is switched off; data stays): every 5 minutes the Mac
/// readers, auto links, reminder tasks settled, due reminders asked of the shared budget, the monthly LinkedIn nudge, and
/// the engine side (Gmail/Outlook metadata, What's new, the phone copy and actions).
@MainActor final class CircleRunner {
    static let shared = CircleRunner()
    static let interval: TimeInterval = 5 * 60
    private var store: Store?
    private var ui: UIState?
    private var show: ((DueReminder) -> Void)?
    private var timer: Timer?
    private var running = false

    /// Called once at launch: registers Circle's hooks (weekly review, search, right-click, module switch) and starts.
    func start(store: Store, ui: UIState, show: @escaping (DueReminder) -> Void) {
        self.store = store; self.ui = ui; self.show = show
        CircleDue.register()
        SelectionActions.register(.init(id: "add_to_circle", title: "Add to Circle", module: .circle) { ctx in
            ui.mode = .expanded
            ui.tab = .circle
            CircleNav.shared.addRequest = PersonFormRequest(personID: nil, name: ctx.text.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        GlobalSearchOpen.handlers[.person] = { id in
            ui.tab = .circle
            CircleNav.shared.selected = id.number
        }
        ModuleHooks.onChange(.circle) { [weak self] on in if on { self?.schedule() } else { self?.stop() } }
        if store.isOn(.circle) { schedule() }
    }

    private func schedule() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.tick() }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    func tick(now: Date = Date()) {
        guard let store, store.isOn(.circle), !running else { return }
        running = true
        Task { @MainActor in
            // The WhatsApp and WeChat readers copy and scan off the main thread; what they found is recorded here.
            await CircleReaders.runAll(store: store, now: now)
            CircleLinker.run(store: store, now: now)
            CircleDue.settleTasks(store: store, now: now)
            CircleDue.requestReminders(store: store, now: now)
            if CircleStore(store: store).linkedInNudgeDue(now: now) {
                show?(DueReminder(id: "circle-linkedin-\(Int(now.timeIntervalSince1970))", cardID: 0, title: "LinkedIn export",
                                  body: "Time for this month's LinkedIn connections export: download it and import it in Circle › Suggestions.",
                                  fireAt: now.addingTimeInterval(1)))
            }
            for info in store.connectors where info.id != LocalMode.connectorID {
                guard let client = ConnectorAccounts.client(for: info, store: store) else { continue }
                await CircleSync.run(store: store, client: client, connector: info.id, now: now)
            }
            running = false
        }
    }

    /// The first engine that can answer Circle's on-request jobs (fill, draft).
    static func client(_ store: Store) -> ConnectorClient? {
        for info in store.connectors where info.id != LocalMode.connectorID {
            if let c = ConnectorAccounts.client(for: info, store: store) { return c }
        }
        return store.connectors.first.flatMap { ConnectorAccounts.client(for: $0, store: store) }
    }
}
