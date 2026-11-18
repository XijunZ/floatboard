import Foundation

/// What a budget reminder is about. Circle's due people and Decisions' reviews share one daily limit (features §9).
/// A birthday is its own kind (its own id, so it never stands in for a due reminder, and no Contacted / Snooze buttons).
public enum ReminderKind: String, CaseIterable { case circleDue = "circle_due", circleBirthday = "circle_birthday", decisionReview = "decision_review" }

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
    /// Throws when the database can't be read or written: a failure is never read as "deferred".
    public func request(kind: ReminderKind, itemID: ShortID, text: String, now: Date = Date()) throws -> ReminderGrant {
        let s = settings
        let fire = Self.allowedTime(from: now, settings: s)
        let day = Due.dayString(fire)
        let id = "rb-\(kind.rawValue)-\(itemID.text)-\(day)"
        return try store.performThrowing { () throws -> ReminderGrant in
            if try store.db.query("SELECT 1 FROM reminders WHERE id=?", [id], { DB.int($0, 0) }).first != nil { return .duplicate(id: id) }
            let used = try store.db.query("SELECT count(*) FROM reminders WHERE day=?", [day]) { DB.int($0, 0) }.first ?? 0
            guard used < s.dailyLimit else {
                let nextDay = AppTime.calendar.date(byAdding: .day, value: 1, to: AppTime.calendar.startOfDay(for: fire)) ?? fire
                return .deferred(until: Self.allowedTime(from: nextDay, settings: s))
            }
            try store.db.run("INSERT INTO reminders(id, kind, item, text, day, fire_at, granted) VALUES(?,?,?,?,?,?,?)",
                             [id, kind.rawValue, itemID.text, text, day, fire, now])
            return .granted(id: id, fireAt: fire)
        }
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
/// reminder. Past the Mac's grace it is the phone's and is never shown here; one this Mac claimed at the engine but could
/// not show is first handed back (`release`), so the engine sends it to the phone: a reminder is never shown nowhere.
@MainActor public final class ReminderDelivery {
    let store: Store
    let claim: (String) async -> ReminderClaim
    let schedule: (DueReminder) async throws -> Void
    let release: (String) async -> Bool
    /// Whether any engine can reach a phone now; when none can, a late reminder is shown on this Mac instead (never nowhere).
    let phoneAvailable: () -> Bool
    private var inFlight = Set<String>()
    private var reported = Set<String>()

    /// `release` hands a claim back to the engine (true once done, or when there was nothing to hand back; false: try again).
    public init(store: Store, claim: @escaping (String) async -> ReminderClaim, schedule: @escaping (DueReminder) async throws -> Void,
                release: @escaping (String) async -> Bool = { _ in true }, phoneAvailable: @escaping () -> Bool = { true }) {
        self.store = store; self.claim = claim; self.schedule = schedule; self.release = release; self.phoneAvailable = phoneAvailable
    }

    /// A reminder later than this is not shown late on the Mac (the engine sends one to the phone only within a day).
    public static let lateLimit: TimeInterval = 86400

    static func claimedKey(_ id: String) -> String { "reminder_claimed:\(id)" }
    /// Written before a claim is sent and cleared once its answer is known: a claim whose answer was lost (the engine may
    /// hold it) is then handed back at handoff like a known one, so the phone is never blocked by it.
    static func intentKey(_ id: String) -> String { "reminder_claim_sent:\(id)" }
    private func intent(_ id: String) -> Bool {
        do { return try store.db.query("SELECT 1 FROM meta WHERE key=?", [Self.intentKey(id)]) { DB.int($0, 0) }.first != nil } catch {
            return true   // unreadable: assume a claim may be out there (a release of nothing is harmless)
        }
    }
    /// Records the intent; false when it could not be kept (then no claim is sent this minute).
    private func setIntent(_ id: String) -> Bool {
        do { try store.performThrowing { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, '1')", [Self.intentKey(id)]) }; return true } catch {
            if reported.insert(id).inserted { store.activity("reminders", .error, "Could not note a reminder claim; will try again", detail: "\(error)", trace: id) }
            return false
        }
    }
    /// The claim's answer is known: the intent is replaced by the claim (mine) or simply cleared, in one write.
    private func settle(_ id: String, mine: Bool) {
        store.perform {
            if mine { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, '1')", [Self.claimedKey(id)]) }
            try store.db.run("DELETE FROM meta WHERE key=?", [Self.intentKey(id)])
        }
    }
    private func claimed(_ id: String) -> Bool {
        ((try? store.db.query("SELECT 1 FROM meta WHERE key=?", [Self.claimedKey(id)]) { DB.int($0, 0) }) ?? []).first != nil // try?-ok: unreadable = not claimed (the engine's answer still decides)
    }
    private func setClaimed(_ id: String, _ on: Bool) {
        store.perform {
            if on { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, '1')", [Self.claimedKey(id)]) }
            else { try store.db.run("DELETE FROM meta WHERE key=?", [Self.claimedKey(id)]) }
        }
    }

    /// Returns true when a reminder changed state (the board copy for the phone should be sent again).
    @discardableResult
    public func tick(now: Date = Date()) async -> Bool {
        let budget = ReminderBudget(store: store)
        var changed = false
        for r in budget.pending() where !inFlight.contains(r.id) {
            if ReminderBudget.phoneTakesOver(r, now: now) && !phoneAvailable() && !claimed(r.id) && !intent(r.id) {
                // Late (the Mac was asleep or busy) and no phone can be reached: shown here, late, rather than nowhere. More
                // than a day late it is dropped (as the engine does); in quiet hours it waits for them to end.
                if now.timeIntervalSince(r.fireAt) > Self.lateLimit {
                    budget.markDelivered(r.id, by: "expired", at: now); changed = true; continue
                }
                if ReminderBudget.allowedTime(from: now, settings: budget.settings) > now { continue }
                inFlight.insert(r.id)
                defer { inFlight.remove(r.id) }
                let title = ShortID.parse(r.item).flatMap { store.item($0)?.title } ?? "FloatBoard"
                do {
                    try await schedule(DueReminder(id: r.id, cardID: 0, title: title, body: r.text, fireAt: now.addingTimeInterval(1)))
                    budget.markDelivered(r.id, by: "mac", at: now); changed = true
                } catch {
                    if reported.insert(r.id).inserted { store.activity("reminders", .error, "Could not show a late reminder; will try again", detail: "\(error)", trace: r.id) }
                }
                continue
            }
            if ReminderBudget.phoneTakesOver(r, now: now) {
                let known = claimed(r.id)
                if known || intent(r.id) {
                    // Claimed here (or a claim whose answer was lost) but never shown: hand it back so the engine sends it to the
                    // phone (retried until it can; releasing a claim the engine never took changes nothing).
                    inFlight.insert(r.id)
                    let back = await release(r.id)
                    inFlight.remove(r.id)
                    guard back else { continue }
                    setClaimed(r.id, false)
                    settle(r.id, mine: false)
                    if known { store.activity("reminders", .warning, "A reminder could not be shown on this Mac; it goes to your phone instead", trace: r.id) }
                }
                budget.markDelivered(r.id, by: "phone", at: now); changed = true; continue
            }
            guard ReminderBudget.macShows(r, now: now) else { continue }
            inFlight.insert(r.id)
            defer { inFlight.remove(r.id) }
            guard setIntent(r.id) else { continue }
            let answer = await claim(r.id)
            if answer != .unreachable { settle(r.id, mine: answer == .mine) }   // unreachable: the engine may hold it; the intent stays
            switch answer {
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
                    if claimed(r.id) { setClaimed(r.id, false) }
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
