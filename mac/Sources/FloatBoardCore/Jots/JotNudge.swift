import Foundation

/// J11 and §9: the daily jot nudge, at a chosen time (app zone), skipped on days you already jotted (only jots you typed,
/// dictated or wrote on the phone count), with the day's finished tasks as a prompt. Shown once: by this Mac, or by the
/// phone when the Mac has not shown it within 10 minutes.
public struct JotNudgeSettings: Codable, Equatable {
    public var on = true
    /// Minutes after midnight, app zone.
    public var minutes = 21 * 60
    public init(on: Bool = true, minutes: Int = 21 * 60) { self.on = on; self.minutes = minutes }
}

/// What the engine needs to give the nudge on the phone when the Mac does not.
public struct JotNudgeState: Equatable {
    public let minutes: Int?
    public let zone: String
    public let shownDay: String?
    public let jottedDay: String?
    public let doneToday: [String]
}

@MainActor public struct JotNudge {
    let store: Store
    public init(store: Store) { self.store = store }
    static let settingsKey = "jot_nudge", shownKey = "jot_nudged_day"

    public var settings: JotNudgeSettings {
        guard let raw = meta(Self.settingsKey), let s = try? JSONDecoder().decode(JotNudgeSettings.self, from: Data(raw.utf8)) else { // try?-ok: unreadable = defaults
            return JotNudgeSettings()
        }
        return s
    }

    public func save(_ s: JotNudgeSettings) {
        store.perform {
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.settingsKey, String(decoding: try JSONEncoder().encode(s), as: UTF8.self)])
        }
    }

    /// The nudge to show now on this Mac (title, body), or nil: off, before the time, already shown today, or already jotted.
    public func due(now: Date = Date()) -> (title: String, body: String)? {
        let s = settings
        guard s.on, store.isOn(.jots) else { return nil }
        let c = AppTime.calendar.dateComponents([.hour, .minute], from: now)
        guard (c.hour ?? 0) * 60 + (c.minute ?? 0) >= s.minutes, meta(Self.shownKey) != DailyFiles.dayKey(now),
              !JotStore(store: store).ownJotAdded(on: now) else { return nil }
        return ("Anything to jot today?", prompt(now: now))
    }

    /// Records that the nudge was shown today (on this Mac).
    public func markShown(now: Date = Date()) {
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.shownKey, DailyFiles.dayKey(now)]) }
    }

    /// "Done today: A, B and 2 more." or a plain line when nothing was finished.
    public func prompt(now: Date = Date()) -> String {
        let done = doneToday(now: now)
        guard !done.isEmpty else { return "A line about your day, an idea, or what's on your mind." }
        let shown = done.prefix(3).joined(separator: ", ")
        return "Done today: " + shown + (done.count > 3 ? " and \(done.count - 3) more." : ".")
    }

    /// Titles of the tasks finished today (app zone), oldest first.
    public func doneToday(now: Date = Date()) -> [String] {
        guard let day = AppTime.calendar.dateInterval(of: .day, for: now) else { return [] }
        return store.cards.filter { $0.status == .done && ($0.done.map(day.contains) ?? false) }.sorted { ($0.done ?? now) < ($1.done ?? now) }.map(\.title)
    }

    /// What the engine gets with each jots push (nil minutes when the nudge or Jots is off).
    public func state(now: Date = Date()) -> JotNudgeState {
        let s = settings
        return JotNudgeState(minutes: s.on && store.isOn(.jots) ? s.minutes : nil, zone: AppTime.zone.identifier, shownDay: meta(Self.shownKey),
                             jottedDay: JotStore(store: store).ownJotAdded(on: now) ? DailyFiles.dayKey(now) : nil,
                             doneToday: Array(doneToday(now: now).prefix(10)))
    }

    private func meta(_ key: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) })?.first // try?-ok: unreadable = not set
    }
}
