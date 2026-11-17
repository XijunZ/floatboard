import Combine
import FloatBoardCore
import Foundation

/// Once a minute: the daily jot nudge on this Mac (J11). A few seconds after jots change (and at launch): the daily files
/// (J12). Both stop while Jots is off.
@MainActor final class JotsTicker {
    private let store: Store
    private let show: (DueReminder) -> Void
    private let pushBoard: () -> Void
    private var timer: Timer?
    private var watch: AnyCancellable?

    init(store: Store, show: @escaping (DueReminder) -> Void, pushBoard: @escaping () -> Void) {
        self.store = store; self.show = show; self.pushBoard = pushBoard
    }

    func start() {
        tick()
        writeFiles()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        watch = store.objectWillChange.debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.writeFiles() } }
    }

    func tick(now: Date = Date()) {
        guard store.isOn(.jots) else { return }
        let nudge = JotNudge(store: store)
        if let n = nudge.due(now: now) {
            show(DueReminder(id: "jot-nudge-\(DailyFiles.dayKey(now))", cardID: 0, title: n.title, body: n.body, fireAt: now.addingTimeInterval(1)))
            nudge.markShown(now: now)
            pushBoard()   // the engine learns it was shown here, so the phone doesn't repeat it
        }
    }

    private func writeFiles() {
        guard store.isOn(.jots) else { return }
        DailyFiles(store: store).refresh()
    }
}
