/// What FloatBoard asks Google for. Calendar sign-in: Calendar events and the list of calendars (read-only), plus who signed in,
/// no mail access. Gmail sign-in (Settings › Connections › Inputs › Gmail): the same plus Gmail, so one consent covers both.
public enum GoogleAuthConfig {
    public static let scopes: [String] = ["https://www.googleapis.com/auth/calendar.events",
                                            "https://www.googleapis.com/auth/calendar.calendarlist.readonly", "openid", "email"]
    /// Gmail access first, then everything Calendar needs.
    public static let gmailScopes: [String] = ["https://www.googleapis.com/auth/gmail.modify"] + scopes
}
