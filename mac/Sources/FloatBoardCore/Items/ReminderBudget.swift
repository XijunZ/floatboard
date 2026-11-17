import Foundation

/// What a budget reminder is about. Circle's due people and Decisions' reviews share one daily limit (features §9).
public enum ReminderKind: String, CaseIterable { case circleDue = "circle_due", decisionReview = "decision_review" }

/// The budget's settings (Settings › Areas): reminders a day, and quiet hours as minutes after midnight in the app's zone.
public struct ReminderSettings: Codable, Equatable {
    public var dailyLimit: Int
    public var quietStart: Int
    public var quietEnd: Int
    public init(dailyLimit: Int = 3, quietStart: Int = 22 * 60, quietEnd: Int = 8 * 60) {
        self.dailyLimit = dailyLimit; self.quietStart = quietStart; self.quietEnd = quietEnd
    }
}

/// The answer to a request: shown at `fireAt` under one notification id; not today (ask again from `until`); or already granted.
public enum ReminderGrant: Equatable {
    case granted(id: String, fireAt: Date)
    case deferred(until: Date)
    case duplicate(id: String)
}

/// A granted reminder.
public struct BudgetReminder: Equatable {
    public let id: String
    public let kind: String
    public let item: String
    public let text: String
    public let fireAt: Date
    public let delivered: Date?
}

/// The one reminder budget. Each (kind, item, day) has one notification id and is shown once, on the Mac when it is awake
/// at the time, otherwise on the phone (the engine sends it from the Mac's latest board copy after `phoneGrace`).
@MainActor public struct ReminderBudget {
    let store: Store
    public init(store: Store) { self.store = store }

    public static let phoneGrace: TimeInterval = 10 * 60
    static let settingsKey = "reminder_budget"

    public var settings: ReminderSettings {
        let raw = (try? store.db.query("SELECT value FROM meta WHERE key=?", [Self.settingsKey]) { DB.text($0, 0) })?.first // try?-ok: unreadable = defaults
        return raw.flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: Data($0.utf8)) } ?? ReminderSettings() // try?-ok: unreadable = defaults
    }

    public func save(_ s: ReminderSettings) {
        var c = s
        c.dailyLimit = max(0, min(20, c.dailyLimit))
        c.quietStart = max(0, min(24 * 60 - 1, c.quietStart)); c.quietEnd = max(0, min(24 * 60 - 1, c.quietEnd))
        store.perform {
            let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.settingsKey, json])
        }
    }

    /// Asks for a reminder now. Quiet hours move the time to their end (and it counts on that day). Over the day's limit:
    /// deferred to the next day's first allowed minute. The same kind and item on the same day: the reminder already granted.
    public func request(kind: ReminderKind, itemID: ShortID, text: String, now: Date = Date()) -> ReminderGrant {
        let s = settings
        let fire = Self.allowedTime(from: now, settings: s)
        let day = Due.dayString(fire)
        let id = "rb-\(kind.rawValue)-\(itemID.text)-\(day)"
        var out: ReminderGrant = .deferred(until: fire)
        store.perform {
            if try store.db.query("SELECT 1 FROM reminders WHERE id=?", [id], { DB.int($0, 0) }).first != nil { out = .duplicate(id: id); return }
            let used = try store.db.query("SELECT count(*) FROM reminders WHERE day=?", [day]) { DB.int($0, 0) }.first ?? 0
            guard used < s.dailyLimit else {
                let nextDay = AppTime.calendar.date(byAdding: .day, value: 1, to: AppTime.calendar.startOfDay(for: fire)) ?? fire
                out = .deferred(until: Self.allowedTime(from: nextDay, settings: s)); return
            }
            try store.db.run("INSERT INTO reminders(id, kind, item, text, day, fire_at, granted) VALUES(?,?,?,?,?,?,?)",
                             [id, kind.rawValue, itemID.text, text, day, fire, now])
            out = .granted(id: id, fireAt: fire)
        }
        return out
    }

    /// Granted reminders not yet delivered, by time.
    public func pending() -> [BudgetReminder] {
        do {
            return try store.db.query("SELECT id, kind, item, text, fire_at, delivered FROM reminders WHERE delivered IS NULL ORDER BY fire_at, id") { s in
                BudgetReminder(id: DB.text(s, 0), kind: DB.text(s, 1), item: DB.text(s, 2), text: DB.text(s, 3), fireAt: DB.date(s, 4) ?? Date(),
                               delivered: DB.date(s, 5))
            }
        } catch {
            store.activity("reminders", .error, "Could not read the waiting reminders", detail: "\(error)")
            return []
        }
    }

    /// What the phone's copy carries: reminders not yet shown, and those left to the phone in the last day (the engine sends
    /// each once; one the Mac showed is dropped, so the engine never sends it).
    public func forPhone(now: Date = Date()) -> [BudgetReminder] {
        do {
            return try store.db.query("""
                SELECT id, kind, item, text, fire_at, delivered FROM reminders
                WHERE delivered IS NULL OR (delivered_by='phone' AND fire_at>?) ORDER BY fire_at, id
                """, [now.addingTimeInterval(-86400)]) { s in
                BudgetReminder(id: DB.text(s, 0), kind: DB.text(s, 1), item: DB.text(s, 2), text: DB.text(s, 3), fireAt: DB.date(s, 4) ?? Date(),
                               delivered: DB.date(s, 5))
            }
        } catch {
            store.activity("reminders", .error, "Could not read the reminders for the phone", detail: "\(error)")
            return []
        }
    }

    /// Records that a reminder was shown ("mac") or left to the phone ("phone"). It is then never shown again.
    public func markDelivered(_ id: String, by: String, at: Date = Date()) {
        store.perform { try store.db.run("UPDATE reminders SET delivered=?, delivered_by=? WHERE id=? AND delivered IS NULL", [at, by, id]) }
    }

    /// The Mac shows a reminder from its time until `phoneGrace` later; after that it is the phone's.
    public static func macShows(_ r: BudgetReminder, now: Date) -> Bool { now >= r.fireAt && now < r.fireAt.addingTimeInterval(phoneGrace) }
    public static func phoneTakesOver(_ r: BudgetReminder, now: Date) -> Bool { now >= r.fireAt.addingTimeInterval(phoneGrace) }

    /// `date`, or the end of the quiet hours it falls in (quiet hours may span midnight).
    static func allowedTime(from date: Date, settings s: ReminderSettings) -> Date {
        let cal = AppTime.calendar
        let c = cal.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let start = cal.startOfDay(for: date)
        func at(_ minutes: Int, dayOffset: Int) -> Date {
            let d = cal.date(byAdding: .day, value: dayOffset, to: start) ?? start
            return cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: d) ?? d
        }
        guard s.quietStart != s.quietEnd else { return date }
        if s.quietStart < s.quietEnd {
            return m >= s.quietStart && m < s.quietEnd ? at(s.quietEnd, dayOffset: 0) : date
        }
        if m >= s.quietStart { return at(s.quietEnd, dayOffset: 1) }
        if m < s.quietEnd { return at(s.quietEnd, dayOffset: 0) }
        return date
    }
}

/// Whether this Mac may show a budget reminder: the engine's answer to "I am showing this id" (one id, shown once across Mac
/// and phone). `mine`: shown here; `phones`: the engine already sent it to the phone; `unreachable`: ask again next minute;
/// `noEngine`: no engine serves a phone (Board only, Mac only), so this Mac is the only place it can show.
public enum ReminderClaim: Equatable { case mine, phones, unreachable, noEngine }

/// Shows the budget reminders that are due on this Mac (called once a minute). A reminder counts as delivered only once
/// macOS has taken it (`schedule` returned); a refusal leaves it waiting, retried next minute, with one Activity error per
/// reminder. Past the Mac's grace it is the phone's and is never shown here.
@MainActor public final class ReminderDelivery {
    let store: Store
    let claim: (String) async -> ReminderClaim
    let schedule: (DueReminder) async throws -> Void
    private var inFlight = Set<String>()
    private var reported = Set<String>()

    public init(store: Store, claim: @escaping (String) async -> ReminderClaim, schedule: @escaping (DueReminder) async throws -> Void) {
        self.store = store; self.claim = claim; self.schedule = schedule
    }

    /// Returns true when a reminder changed state (the board copy for the phone should be sent again).
    @discardableResult
    public func tick(now: Date = Date()) async -> Bool {
        let budget = ReminderBudget(store: store)
        var changed = false
        for r in budget.pending() where !inFlight.contains(r.id) {
            if ReminderBudget.phoneTakesOver(r, now: now) {
                budget.markDelivered(r.id, by: "phone", at: now); changed = true; continue
            }
            guard ReminderBudget.macShows(r, now: now) else { continue }
            inFlight.insert(r.id)
            defer { inFlight.remove(r.id) }
            switch await claim(r.id) {
            case .phones:
                budget.markDelivered(r.id, by: "phone", at: now); changed = true
            case .unreachable:
                continue
            case .mine, .noEngine:
                let title = ShortID.parse(r.item).flatMap { store.item($0)?.title } ?? "FloatBoard"
                do {
                    try await schedule(DueReminder(id: r.id, cardID: 0, title: title, body: r.text, fireAt: now.addingTimeInterval(1)))
                    budget.markDelivered(r.id, by: "mac", at: now); changed = true
                    reported.remove(r.id)
                } catch {
                    if reported.insert(r.id).inserted {
                        store.activity("reminders", .error, "Could not show a reminder; will try again", detail: "\(error)", trace: r.id)
                    }
                }
            }
        }
        return changed
    }
}
