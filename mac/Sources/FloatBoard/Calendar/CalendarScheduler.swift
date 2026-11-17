import AppKit
import FloatBoardConnectors
import FloatBoardCore

extension Notification.Name {
    /// Post to send waiting calendar changes and read Google's changes now (after a change the user just made).
    static let floatBoardCalendarNow = Notification.Name("floatBoardCalendarNow")
    /// Posted after each calendar run, so screens that show calendar information (the bar's next meeting) can look again.
    static let floatBoardCalendarSynced = Notification.Name("floatBoardCalendarSynced")
}

/// Owns the one calendar sender and the one calendar sync, and decides when they run: every minute while the Calendar tab or
/// the bar's next meeting is on screen (`fastMode`), every 5 minutes otherwise while the Mac is awake, once on wake, and at once
/// when asked (`.floatBoardCalendarNow`). Each run sends waiting changes first, then reads Google's, then lets tasks and events
/// catch up. The calendar list is read at start and every 6 hours, and at the next run for an account whose last read failed
/// or that was just connected again (inside `CalendarSync.tick`).
@MainActor
final class CalendarScheduler {
    static let fastInterval: TimeInterval = 60
    static let slowInterval: TimeInterval = 300

    /// Set by the Calendar tab and the bar while they show calendar information.
    var fastMode = false
    private let sender: CalendarSender
    private let sync: CalendarSync
    private var heartbeat: Timer?
    private var lastRun = Date.distantPast
    private var running = false
    /// Asked to run while a run was going: run once more right after it, so a change made meanwhile is not left for minutes.
    private var again = false
    private var soon = false

    init(store: Store, google: Google) {
        sender = CalendarSender(store: store, google: google)
        sync = CalendarSync(store: store, google: google)
    }

    func start() {
        // A beat every minute; a run happens when the interval for the current mode has passed (a little early is fine).
        let t = Timer(timeInterval: Self.fastInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNow() }
        }
        NotificationCenter.default.addObserver(forName: .floatBoardCalendarNow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runSoon() }
        }
        // Board edits, deletes and undo that queue a calendar change ask for a run right away.
        CalendarOutbox.nudge = { NotificationCenter.default.post(name: .floatBoardCalendarNow, object: nil) }
        runNow()
    }

    private func beat() {
        let interval = fastMode ? Self.fastInterval : Self.slowInterval
        if Date().timeIntervalSince(lastRun) >= interval - 5 { runNow() }
    }

    /// A run on the next turn of the main loop: several asks from one user action (the board and the calendar screen both
    /// ask) become one run.
    private func runSoon() {
        guard !soon else { return }
        soon = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.soon = false
                self?.runNow()
            }
        }
    }

    func runNow() {
        guard !running else { again = true; return }
        running = true
        again = false
        lastRun = Date()
        Task {
            await sender.drain()
            await sync.tick()
            running = false
            NotificationCenter.default.post(name: .floatBoardCalendarSynced, object: nil)
            if again { runNow() }
        }
    }
}
