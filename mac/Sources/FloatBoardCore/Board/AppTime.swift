import Foundation

/// The time zone FloatBoard shows and stores dates in. London unless told otherwise; a later change makes it a setting.
public enum AppTime {
    nonisolated(unsafe) public static var zone: TimeZone = TimeZone(identifier: "Europe/London")!
    /// A Gregorian calendar in `zone`. Read it each time: it follows `zone`.
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
}
