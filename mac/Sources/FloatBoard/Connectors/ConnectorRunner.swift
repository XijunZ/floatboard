import AppKit
import Combine
import FloatBoardConnectors
import FloatBoardCore
import Foundation
import Network

/// When connectors sync: launch, wake, board open (at least 2 minutes apart), every 5 minutes, every 15 seconds while a
/// delivered reply draft waits for its answer (that connector only), and when the
/// network comes back. The phone step alone runs every 2 minutes and 10 seconds after local board changes.
/// One sync at a time per connector. The sync itself is `ConnectorSync` (Connectors target).
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
    private var phoneTimer: Timer?
    private var whatsappTimer: Timer?
    private var whatsappRunning = Set<String>()
    private var boardWatch: AnyCancellable?
    /// Connectors whose phone step is running (a full sync may still start: it does the phone step too, and actions apply once).
    private var phoneRunning = Set<String>()

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
        // Every 5 minutes, matching the engine's schedule, so new tasks reach the board soon after the engine finds them.
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
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

        // Phone app: poll for phone actions every 2 minutes, and send the board 10 seconds after local changes settle.
        // Only engines that have the phone app (or haven't been asked yet) are polled; a full sync asks again.
        let p = Timer(timeInterval: ConnectorSync.phonePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.phoneTick(skipUnknown: false) }
        }
        RunLoop.main.add(p, forMode: .common)
        phoneTimer = p
        // WhatsApp screening (only connections where it is turned on): every 5 minutes.
        let w = Timer(timeInterval: WhatsAppSync.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.whatsappTick() }
        }
        RunLoop.main.add(w, forMode: .common)
        whatsappTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.whatsappTick() }
        boardWatch = Publishers.Merge(store.$cards.map { _ in () }, store.$areas.map { _ in () })
            .debounce(for: .seconds(ConnectorSync.phonePushDebounce), scheduler: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.phoneTick(skipUnknown: true) } }
    }

    /// The phone step alone (actions, then the board if it changed) for each connector not already syncing. With
    /// `skipUnknown`, only engines known to have the phone app. Actions that queued engine events start a sync to send them.
    private func phoneTick(skipUnknown: Bool) {
        for info in store.connectors {
            let id = info.id
            let support = ConnectorSync.phoneSupport[id]
            if support == false || (skipUnknown && support == nil) || running.contains(id) || phoneRunning.contains(id) { continue }
            guard let client = ConnectorAccounts.client(for: info, store: store) else { continue }
            phoneRunning.insert(id)
            Task { @MainActor in
                let r = await ConnectorSync.phoneTick(connector: id, store: store, client: client, now: Date())
                phoneRunning.remove(id)
                if r.queuedEvents { trigger("phone", only: [id]) }
            }
        }
    }

    /// Reads unread WhatsApp chats for each connection that has screening on, and sends new ones to its engine.
    func whatsappTick() {
        for info in store.connectors where WhatsAppSync.isOn(connector: info.id, store: store) && !whatsappRunning.contains(info.id) {
            guard let client = ConnectorAccounts.client(for: info, store: store) else { continue }
            let id = info.id
            whatsappRunning.insert(id)
            Task { @MainActor in
                await WhatsAppSync.tick(connector: id, store: store, client: client)
                whatsappRunning.remove(id)
                NotificationCenter.default.post(name: .floatBoardWhatsAppRead, object: nil)
            }
        }
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
                let r = await ConnectorSync.run(connector: id, store: store, client: client, now: Date())
                running.remove(id)
                store.reload()
                Health.refresh(store: store, backups: backups)
                if syncAgain.remove(id) != nil { trigger("reply draft") }
                else if r.phoneQueuedEvents { trigger("phone", only: [id]) }
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
