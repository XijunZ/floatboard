import Foundation

extension MakeTask {
    /// The due date a selection mentions ("by Friday", "on 21 November", "tomorrow at 3pm"), by code (NSDataDetector), read
    /// in the app's time zone: a date-only mention is that day; one with a time keeps it. Nil when none is mentioned or the
    /// mention is more than a day in the past. Relative words count from today (the detector's own clock).
    public static func dueMentioned(in text: String, now: Date = Date()) -> (date: Date, hasTime: Bool)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil } // try?-ok: no detector = no date filled in; the owner can set one
        let ns = text as NSString
        guard let m = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), let found = m.date else { return nil }
        let said = ns.substring(with: m.range).lowercased()
        let timed = said.range(of: #"\d{1,2}[:.]\d{2}|\d{1,2}\s*(am|pm)|noon|midnight|\d{1,2}\s*h\b"#, options: .regularExpression) != nil
        // The detector reads in this Mac's zone: take the wall-clock parts there and rebuild them in the app's zone.
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: found)
        var c = DateComponents(year: parts.year, month: parts.month, day: parts.day)
        if timed { c.hour = parts.hour; c.minute = parts.minute }
        guard let date = AppTime.calendar.date(from: c), date > now.addingTimeInterval(-86400) else { return nil }
        return (date, timed)
    }
}
