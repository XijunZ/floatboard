import Foundation

/// One local notification for a task's due: shown at `fireAt` with the task's title and "Due 14:30" or "Due today".
public struct DueReminder: Equatable {
    /// Unique per task and due value ("due-<task>-<due seconds>"), so a new due is a new reminder.
    public var id: String
    public var cardID: Int64
    public var title: String
    public var body: String
    public var fireAt: Date
    public init(id: String, cardID: Int64, title: String, body: String, fireAt: Date) {
        self.id = id; self.cardID = cardID; self.title = title; self.body = body; self.fireAt = fireAt
    }
}

/// Shows reminders (UserNotifications in the app; a fake in the checks).
@MainActor public protocol ReminderScheduler: AnyObject {
    func schedule(_ r: DueReminder)
    func cancel(_ ids: [String])
}

/// Due reminders on this Mac, from its own board (no engine needed), and Watch chase reminders: an open task (To do, Doing, Watch) with a due
/// time is reminded 15 minutes before it, one with a due date only at 09:00 that day. A reminder whose time has passed
/// while its due is still ahead (a task due in 10 minutes, the app started after 09:00) is shown at once.
public enum DueReminders {
    public static let lead: TimeInterval = 15 * 60
    public static let dayHour = 9
    /// macOS keeps at most 64 waiting notifications per app.
    public static let maxPending = 60
    /// The setting ("Due reminders on this Mac"), on unless turned off.
    public static let settingKey = "dueRemindersOn"

    public static func enabled(_ defaults: UserDefaults) -> Bool { enabled(stored: defaults.object(forKey: settingKey)) }
    public static func enabled(stored: Any?) -> Bool { stored as? Bool ?? true }

    public static func plan(_ cards: [Card], now: Date, calendar: Calendar = .current) -> [DueReminder] {
        var out: [DueReminder] = []
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX"); clock.timeZone = calendar.timeZone; clock.dateFormat = "HH:mm"
        for c in cards where c.status != .done && !c.withdrawn {
            // A Watch task with no reply: the next chase ("Still waiting on Anna · 3 days"), every 3 days.
            if c.status == .watch, let since = c.watchSince, let next = Watch.nextChases(since: since, now: now, count: 1).first {
                out.append(DueReminder(id: "chase-\(c.id)-\(Int(since.timeIntervalSince1970))-\(Int(next.timeIntervalSince1970))", cardID: c.id,
                                       title: c.title, body: Watch.chaseText(person: c.watchPerson, at: next, since: since), fireAt: next))
            }
            guard let due = c.due else { continue }
            let t = calendar.dateComponents([.hour, .minute], from: due)
            let timed = (t.hour ?? 0) != 0 || (t.minute ?? 0) != 0   // as Due.hasTime, in this calendar
            let fire: Date, until: Date, body: String
            if timed {
                fire = due.addingTimeInterval(-lead); until = due; body = "Due " + clock.string(from: due)
            } else {
                let start = calendar.startOfDay(for: due)
                fire = calendar.date(bySettingHour: dayHour, minute: 0, second: 0, of: start) ?? start
                until = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                body = "Due today"
            }
            guard now < until else { continue }
            out.append(DueReminder(id: "due-\(c.id)-\(Int(due.timeIntervalSince1970))", cardID: c.id, title: c.title, body: body,
                                   fireAt: max(fire, now.addingTimeInterval(1))))
        }
        return Array(out.sorted { $0.fireAt < $1.fireAt }.prefix(maxPending))
    }
}

/// Keeps the scheduled reminders in step with the board. It remembers (in UserDefaults) every reminder it handed to
/// the scheduler, so a reminder is shown once, also across restarts; one no longer wanted (task done, deleted, moved
/// to Done, due changed or passed) is cancelled and forgotten.
@MainActor public final class ReminderSync {
    let scheduler: ReminderScheduler
    private let load: () -> [String]
    private let save: ([String]) -> Void
    static let memoryKey = "dueRemindersScheduled"

    /// `load` / `save` keep the ids handed to the scheduler (the app keeps them in UserDefaults).
    public init(scheduler: ReminderScheduler, load: @escaping () -> [String], save: @escaping ([String]) -> Void) {
        self.scheduler = scheduler; self.load = load; self.save = save
    }

    public convenience init(scheduler: ReminderScheduler, defaults: UserDefaults) {
        self.init(scheduler: scheduler, load: { defaults.stringArray(forKey: ReminderSync.memoryKey) ?? [] },
                  save: { defaults.set($0, forKey: ReminderSync.memoryKey) })
    }

    private var memory: Set<String> {
        get { Set(load()) }
        set { save(newValue.sorted()) }
    }

    public func sync(cards: [Card], enabled: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let wanted = enabled ? DueReminders.plan(cards, now: now, calendar: calendar) : []
        let ids = Set(wanted.map(\.id))
        var known = memory
        let gone = known.subtracting(ids)
        if !gone.isEmpty { scheduler.cancel(gone.sorted()) }
        known.subtract(gone)
        for r in wanted where !known.contains(r.id) {
            scheduler.schedule(r)
            known.insert(r.id)
        }
        memory = known
    }
}
