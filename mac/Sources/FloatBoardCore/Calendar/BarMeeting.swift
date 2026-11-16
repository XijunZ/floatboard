import Foundation

/// What the bar's "next meeting" shows. Pure rules, no database: the caller passes the cache's `nextMeeting(after:)`.
public enum BarMeeting {
    /// The meeting appears this long before it starts.
    public static let leadTime: TimeInterval = 60 * 60

    /// `next` when it is within 60 minutes of starting or in progress; nil before that, and once it has ended.
    public static func visible(next: CalEvent?, now: Date) -> CalEvent? {
        guard let e = next, now >= e.start.addingTimeInterval(-leadTime), now < e.end else { return nil }
        return e
    }

    /// "11:00 Standup" in the app time zone.
    public static func label(_ e: CalEvent) -> String { "\(Fmt.clock(e.start)) \(e.title)" }

    /// Where Join goes: the event's video link, only when it is a web address.
    public static func joinURL(_ e: CalEvent) -> URL? {
        let t = e.videoLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return nil }
        return u
    }
}
