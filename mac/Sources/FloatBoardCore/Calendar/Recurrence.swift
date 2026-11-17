import Foundation

/// A repeating meeting's rule (Google's `recurrence`: RRULE, EXDATE ... lines) as a few words for the phone's planning
/// summary: "weekdays 09:00", "weekly Tue 14:00", "every 2 weeks Mon, Wed 09:00", "monthly". Only the common shapes are
/// put in words; anything else is "repeats". `start` is one instance's start (its weekday and time, in the app's zone).
public enum RecurrenceLabel {
    private static let days = ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun"]
    private static let order = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    private static let weekdays = ["MO", "TU", "WE", "TH", "FR"]

    public static func text(rule: String, start: Date, allDay: Bool) -> String {
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
        let time = allDay ? "" : " " + clock(start)
        switch parts["FREQ"] {
        case "DAILY":
            if Set(byDay) == Set(weekdays), interval == 1 { return "weekdays" + time }
            guard byDay.isEmpty else { return "repeats" }
            return (interval == 1 ? "daily" : "every \(interval) days") + time
        case "WEEKLY":
            guard byDay.allSatisfy({ days[$0] != nil }) else { return "repeats" }
            if Set(byDay) == Set(weekdays), interval == 1 { return "weekdays" + time }
            let codes = byDay.isEmpty ? [weekdayCode(start)] : order.filter { byDay.contains($0) }
            let names = codes.compactMap { days[$0] }.joined(separator: ", ")
            return (interval == 1 ? "weekly" : "every \(interval) weeks") + " " + names + time
        case "MONTHLY": return interval == 1 ? "monthly" : "every \(interval) months"
        case "YEARLY": return interval == 1 ? "yearly" : "every \(interval) years"
        default: return "repeats"
        }
    }

    private static func clock(_ d: Date) -> String {
        let c = AppTime.calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func weekdayCode(_ d: Date) -> String {
        // Calendar weekday: 1 = Sunday ... 7 = Saturday.
        ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][(AppTime.calendar.component(.weekday, from: d) - 1) % 7]
    }
}

extension CalendarCache {
    /// Repeating meetings of one calendar (Google's `recurringEventId` of cached, live events) whose rule is not kept yet, or,
    /// with `readBefore`, was last read before then. At most `limit`.
    public func seriesToRead(account: String, calendarID: String, readBefore: Date? = nil, limit: Int = 50) -> [String] {
        do {
            return try db.query("""
                SELECT DISTINCT e.recurring_id FROM cal_events e
                LEFT JOIN cal_series s ON s.account=e.account AND s.calendar_id=e.calendar_id AND s.series_id=e.recurring_id
                WHERE e.account=? AND e.calendar_id=? AND e.gone=0 AND e.recurring_id IS NOT NULL AND e.recurring_id<>''
                AND (s.series_id IS NULL OR s.read_at<?) ORDER BY e.recurring_id LIMIT ?
                """, [account, calendarID, readBefore ?? Date.distantPast, limit]) { DB.text($0, 0) }
        } catch {
            store?.activity("calendar", .error, "Could not read which repeating meetings need their rule", detail: "\(error)")
            return []
        }
    }

    /// Keeps a series' rule (its `recurrence` lines joined by newlines; "" when Google had none or refused for good).
    @discardableResult
    public func saveSeries(account: String, calendarID: String, seriesID: String, rule: String, now: Date = Date()) -> Bool {
        do {
            try db.run("INSERT OR REPLACE INTO cal_series(account, calendar_id, series_id, rule, read_at) VALUES(?,?,?,?,?)",
                       [account, calendarID, seriesID, rule, now])
            return true
        } catch {
            store?.activity("calendar", .error, "Could not save a repeating meeting's rule", detail: "\(error)")
            return false
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
