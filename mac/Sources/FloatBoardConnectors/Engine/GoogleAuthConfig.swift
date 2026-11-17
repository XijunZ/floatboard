/// What FloatBoard asks Google for. Calendar sign-in: Calendar events and the list of calendars (read-only), plus who signed in,
/// no mail access. Gmail sign-in (Settings › Connections › Inputs › Gmail): the same plus Gmail, so one consent covers both.
public enum GoogleAuthConfig {
    public static let scopes: [String] = ["https://www.googleapis.com/auth/calendar.events",
                                            "https://www.googleapis.com/auth/calendar.calendarlist.readonly", "openid", "email"]
    /// Gmail access first, then everything Calendar needs.
    public static let gmailScopes: [String] = ["https://www.googleapis.com/auth/gmail.modify"] + scopes

    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
    static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    static let listScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    /// What a sign-in may be used for, from the permissions Google says it granted (people can untick some on the consent screen).
    public struct Granted: Equatable {
        /// calendar.events: the sign-in can be kept as the account's Calendar sign-in.
        public var calendar: Bool
        /// gmail.modify, and Gmail was asked for: the sign-in can be handed to the engine for Gmail screening.
        public var gmail: Bool
        /// The calendar list too (optional: without it only the account's main calendar is used).
        public var calendarList: Bool
    }

    /// Reads the token answer's `scope` (space-separated). No `scope` means nothing is known to be granted, so nothing is used,
    /// and an existing working sign-in is never replaced by one that lacks its permission.
    public static func granted(scope: String?, gmailAsked: Bool) -> Granted {
        let set = Set((scope ?? "").split(separator: " ").map(String.init))
        let calendar = set.contains(eventsScope)
        return Granted(calendar: calendar, gmail: gmailAsked && set.contains(gmailScope), calendarList: calendar && set.contains(listScope))
    }

    /// The message after a sign-in: exactly what got connected, and what was not allowed.
    public static func connectedMessage(email: String, granted g: Granted, gmailAsked: Bool) -> String {
        let listNote = g.calendar && !g.calendarList
            ? " Calendar shows your main calendar only; sign in again and allow the calendar list to see your other calendars." : ""
        if gmailAsked {
            switch (g.gmail, g.calendar) {
            case (true, true): return "Gmail and Calendar \(email) connected." + listNote
            case (true, false): return "Gmail \(email) connected. Calendar was not allowed, so it is not connected."
            case (false, true): return "Calendar \(email) connected. Gmail was not allowed, so Gmail is not connected; sign in again and allow Gmail." + listNote
            case (false, false): return "Google did not allow Gmail or Calendar for \(email); nothing was connected. Sign in again and allow them."
            }
        }
        return g.calendar ? "Calendar \(email) connected." + listNote
                          : "Google did not allow Calendar for \(email), so it is not connected. Sign in again and allow Calendar."
    }
}
