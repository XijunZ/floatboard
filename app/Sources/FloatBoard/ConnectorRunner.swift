import AppKit
import FloatBoardConnectors
import FloatBoardCore
import Foundation
import Network

/// When connectors sync: launch, wake, board open (at least 2 minutes apart), every 15 minutes, every 15 seconds while a
/// delivered reply draft waits for its answer (that connector only), and when the
/// network comes back. One sync at a time per connector. The sync itself is `ConnectorSync` (Connectors target).
/// Which connectors are being re-checked right now (read by the Connectors tab to disable the button and show progress).
@MainActor
final class RecheckState: ObservableObject {
    static let shared = RecheckState()
    @Published var active: Set<String> = []
}

@MainActor
final class ConnectorRunner {
    static weak var shared: ConnectorRunner?
    private let store: Store
    private var running = Set<String>()
    private var lastBoardOpen = Date.distantPast
    private var timer: Timer?
    private let backups = Backups.forEnvironment()
    private var healthTimer: Timer?
    private var expireTimer: Timer?
    /// Connectors asked to sync while a sync was already running: they sync again right after, so a just-queued request isn't left waiting.
    private var syncAgain = Set<String>()
    private let monitor = NWPathMonitor()
    private var wasSatisfied = false

    init(store: Store) { self.store = store; Self.shared = self }

    func start() {
        store.expireReplyDrafts(now: Date())
        trigger("launch")
        Health.refresh(store: store, backups: backups)
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { Health.refresh(store: self.store, backups: self.backups) } }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps firing while a menu is open or the window is being dragged
        healthTimer = t
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger("timer") }
        }
        // While a delivered reply draft waits for its answer, sync its connector every 15 seconds (each such sync asks the
        // engine to work on it first). A request with no answer fails after 10 minutes (a local read, checked here too).
        let e = Timer(timeInterval: ConnectorSync.replyDraftPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.expireReplyDrafts(now: Date())
                let waiting = self.store.connectorsAwaitingReplyDrafts()
                if !waiting.isEmpty { self.trigger("reply draft poll", only: waiting) }
            }
        }
        RunLoop.main.add(e, forMode: .common)
        expireTimer = e
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger("wake") }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ok && !self.wasSatisfied {
                        self.store.retryOutboxNow(now: Date())   // changes backed off while offline go out now, not up to an hour later
                        self.trigger("network")
                    }
                    self.wasSatisfied = ok
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "floatboard.network"))
    }

    func boardOpened() {
        guard Date().timeIntervalSince(lastBoardOpen) >= 120 else { return }
        lastBoardOpen = Date()
        trigger("board open")
    }

    /// Syncs every connector (or those in `only`) that has an address and a key (added from the Connectors tab).
    func trigger(_ reason: String, only: Set<String>? = nil) {
        store.expireReplyDrafts(now: Date())
        for info in store.connectors where only?.contains(info.id) ?? true {
            let id = info.id
            if running.contains(id) { if reason == "reply draft" { syncAgain.insert(id) }; continue }
            guard let client = ConnectorAccounts.client(for: info, store: store) else { continue }
            running.insert(id)
            Task { @MainActor in
                _ = await ConnectorSync.run(connector: id, store: store, client: client, now: Date())
                running.remove(id)
                store.reload()
                Health.refresh(store: store, backups: backups)
                if syncAgain.remove(id) != nil { trigger("reply draft") }
            }
        }
    }

    /// Re-check the last `days` days. Shares the one-at-a-time guard with ordinary syncs: while it runs, no other sync starts
    /// for this connector, and it refuses to start while one is already running.
    func recheck(connector id: String, days: Int) async -> ConnectorSync.RecheckOutcome {
        guard !running.contains(id) else {
            return .init(summary: nil, notice: "A sync is running right now. Try the re-check again in a minute.")
        }
        guard let info = store.connectors.first(where: { $0.id == id }), let client = ConnectorAccounts.client(for: info, store: store) else {
            store.activity("connector:\(id)", .error, "Re-check could not start: the connection has no address or key")
            return .init(summary: nil, notice: "This connection has no address or key. Reconnect it first.")
        }
        running.insert(id)
        RecheckState.shared.active.insert(id)
        let out = await ConnectorSync.recheckOutcome(connector: id, days: days, store: store, client: client, now: Date(), backups: backups)
        running.remove(id)
        RecheckState.shared.active.remove(id)
        store.reload()
        Health.refresh(store: store, backups: backups)
        return out
    }
}
