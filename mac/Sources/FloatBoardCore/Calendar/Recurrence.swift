import Foundation

/// A repeating meeting's rule (Google's `recurrence`: RRULE, EXDATE ... lines) as a few words for the phone's planning
/// summary: "weekdays 09:00", "weekly Tue 14:00", "every 2 weeks Mon, Wed 09:00", "monthly". Only the common shapes are
/// put in words; anything else is "repeats". `start` is one instance's start, `allDay` whether it is all-day.
///
/// The rule's weekdays are days in the zone the series runs in (`master`: its first start and that zone). With it, weekdays
/// and time are converted together into the app's zone (a Monday 23:00 in Los Angeles is "Tue 07:00" in London), checked on
/// each day the rule could fall on within `range` (the days shown; 14 days from `start` when nil). When a clock change in
/// either zone makes that come out differently on different days, the label has no time ("weekly Tue"), and no weekdays
/// either when those differ too ("weekly"). Without `master`, the rule's weekdays and `start`'s time are shown as they are.
public enum RecurrenceLabel {
    private static let days = ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun"]
    private static let order = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    private static let weekdays = ["MO", "TU", "WE", "TH", "FR"]

    public static func text(rule: String, start: Date, allDay: Bool, master: (start: Date, zone: TimeZone)? = nil,
                            range: DateInterval? = nil) -> String {
        guard let line = rule.split(whereSeparator: \.isNewline).map(String.init).first(where: { $0.uppercased().hasPrefix("RRULE:") }) else {
            return "repeats"
        }
        var parts: [String: String] = [:]
        for p in line.dropFirst(6).split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { parts[kv[0].uppercased()] = kv[1].uppercased() }
        }
        var interval = 1
        if let i = parts["INTERVAL"] {
            guard let n = Int(i), n >= 1 else { return "repeats" }
            interval = n
        }
        let byDay = parts["BYDAY"].map { $0.split(separator: ",").map(String.init) } ?? []
        let freq = parts["FREQ"]
        guard freq != "WEEKLY" || byDay.allSatisfy({ days[$0] != nil }) else { return "repeats" }
        // The rule's days in its own zone: BYDAY, else the master's weekday (weekly); every day for daily.
        let ruleDays: [String]? = switch freq {
        case "DAILY": byDay.isEmpty ? order : (Set(byDay) == Set(weekdays) ? weekdays : nil)
        case "WEEKLY": byDay.isEmpty ? [master.map { weekdayCode($0.start, in: $0.zone) } ?? weekdayCode(start, in: AppTime.zone)] : byDay
        default: nil
        }
        var shownDays = ruleDays ?? []
        var time = allDay ? "" : " " + clock(start)
        if !allDay, let master, let ruleDays {
            if let c = converted(days: ruleDays, master: master, range: range ?? DateInterval(start: AppTime.calendar.startOfDay(for: start), duration: 14 * 86400)) {
                shownDays = c.days
                time = c.time.map { " " + $0 } ?? ""
            } else {
                shownDays = []; time = ""
            }
        }
        let sorted = order.filter { shownDays.contains($0) }
        switch freq {
        case "DAILY":
            if Set(byDay) == Set(weekdays), interval == 1 {
                if Set(sorted) == Set(weekdays) { return "weekdays" + time }
                return sorted.isEmpty ? "weekly" : "weekly " + names(sorted) + time
            }
            guard byDay.isEmpty else { return "repeats" }
            return (interval == 1 ? "daily" : "every \(interval) days") + time
        case "WEEKLY":
            if Set(sorted) == Set(weekdays), interval == 1 { return "weekdays" + time }
            let lead = interval == 1 ? "weekly" : "every \(interval) weeks"
            return sorted.isEmpty ? lead : lead + " " + names(sorted) + time
        case "MONTHLY": return interval == 1 ? "monthly" : "every \(interval) months"
        case "YEARLY": return interval == 1 ? "yearly" : "every \(interval) years"
        default: return "repeats"
        }
    }

    /// The rule's days and time of day moved from the series' zone into the app's, over every day in `range` the rule could
    /// fall on (the master's time of day in its zone). Days are nil-free only when each of the rule's days lands on one app day;
    /// `time` is nil when the time differs between days. Nil when the days themselves differ (or nothing falls in range).
    private static func converted(days ruleDays: [String], master: (start: Date, zone: TimeZone), range: DateInterval) -> (days: [String], time: String?)? {
        var mc = Calendar(identifier: .gregorian); mc.timeZone = master.zone
        let hm = mc.dateComponents([.hour, .minute], from: master.start)
        var landed: [String: Set<String>] = [:], times = Set<String>()
        // Each day of the master's calendar that overlaps the range (a day either side, for zones far apart).
        guard var day = mc.date(byAdding: .day, value: -1, to: mc.startOfDay(for: range.start)) else { return nil }
        while day <= range.end.addingTimeInterval(86400) {
            let code = weekdayCode(day, in: master.zone)
            if ruleDays.contains(code), let at = mc.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day),
               range.contains(at) {
                landed[code, default: []].insert(weekdayCode(at, in: AppTime.zone))
                times.insert(clock(at))
            }
            guard let next = mc.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !landed.isEmpty, landed.values.allSatisfy({ $0.count == 1 }) else { return nil }
        // A rule day with no date in range keeps the same shift as the others when all of them agree on it.
        let shifts = Set(landed.map { (from, to) in ((order.firstIndex(of: to.first!) ?? 0) - (order.firstIndex(of: from) ?? 0) + 7) % 7 })
        guard shifts.count == 1, let shift = shifts.first else { return nil }
        let out = ruleDays.map { order[((order.firstIndex(of: $0) ?? 0) + shift) % 7] }
        return (out, times.count == 1 ? times.first : nil)
    }

    private static func names(_ codes: [String]) -> String { codes.compactMap { days[$0] }.joined(separator: ", ") }

    private static func clock(_ d: Date) -> String {
        let c = AppTime.calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func weekdayCode(_ d: Date, in zone: TimeZone) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        // Calendar weekday: 1 = Sunday ... 7 = Saturday.
        return ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][(c.component(.weekday, from: d) - 1) % 7]
    }
}

extension CalendarCache {
    /// Repeating meetings of one calendar (Google's `recurringEventId` of cached, live events) whose rule is not kept yet (or
    /// was kept before the series' start and zone were), or, with `readBefore`, was last read before then. At most `limit`.
    public func seriesToRead(account: String, calendarID: String, readBefore: Date? = nil, limit: Int = 50) -> [String] {
        do {
            return try db.query("""
                SELECT DISTINCT e.recurring_id FROM cal_events e
                LEFT JOIN cal_series s ON s.account=e.account AND s.calendar_id=e.calendar_id AND s.series_id=e.recurring_id
                WHERE e.account=? AND e.calendar_id=? AND e.gone=0 AND e.recurring_id IS NOT NULL AND e.recurring_id<>''
                AND (s.series_id IS NULL OR s.read_at<? OR s.master_zone IS NULL) ORDER BY e.recurring_id LIMIT ?
                """, [account, calendarID, readBefore ?? Date.distantPast, limit]) { DB.text($0, 0) }
        } catch {
            store?.activity("calendar", .error, "Could not read which repeating meetings need their rule", detail: "\(error)")
            return []
        }
    }

    /// Keeps a series' rule (its `recurrence` lines joined by newlines; "" when Google had none or refused for good), with the
    /// series' first start and the time zone its rule runs in when known.
    @discardableResult
    public func saveSeries(account: String, calendarID: String, seriesID: String, rule: String, masterStart: Date? = nil,
                           masterZone: String? = nil, now: Date = Date()) -> Bool {
        do {
            try db.run("""
                INSERT OR REPLACE INTO cal_series(account, calendar_id, series_id, rule, read_at, master_start, master_zone) VALUES(?,?,?,?,?,?,?)
                """, [account, calendarID, seriesID, rule, now, masterZone == nil ? nil : masterStart, masterStart == nil ? "" : (masterZone ?? "")])
            return true
        } catch {
            store?.activity("calendar", .error, "Could not save a repeating meeting's rule", detail: "\(error)")
            return false
        }
    }

    /// The series' first start and the zone its rule runs in, nil when not known (all-day, or not read with them yet).
    public func seriesMaster(account: String, calendarID: String, seriesID: String) -> (start: Date, zone: TimeZone)? {
        do {
            return try db.query("SELECT master_start, master_zone FROM cal_series WHERE account=? AND calendar_id=? AND series_id=?",
                                [account, calendarID, seriesID]) { s -> (Date, TimeZone)? in
                guard let at = DB.date(s, 0), let z = TimeZone(identifier: DB.text(s, 1)) else { return nil }
                return (at, z)
            }.first ?? nil
        } catch {
            store?.activity("calendar", .error, "Could not read when a repeating meeting runs", detail: "\(error)")
            return nil
        }
    }

    /// The kept rule of a series, nil when it has not been read.
    public func seriesRule(account: String, calendarID: String, seriesID: String) -> String? {
        do {
            return try db.query("SELECT rule FROM cal_series WHERE account=? AND calendar_id=? AND series_id=?",
                                [account, calendarID, seriesID]) { DB.text($0, 0) }.first
        } catch {
            store?.activity("calendar", .error, "Could not read a repeating meeting's rule", detail: "\(error)")
            return nil
        }
    }
}
