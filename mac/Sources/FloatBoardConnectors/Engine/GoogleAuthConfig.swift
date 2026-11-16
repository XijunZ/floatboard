/// What FloatBoard asks Google for: Calendar events and the list of calendars (read-only), plus who signed in. No mail access.
public enum GoogleAuthConfig {
    public static let scopes: [String] = ["https://www.googleapis.com/auth/calendar.events",
                                            "https://www.googleapis.com/auth/calendar.calendarlist.readonly", "openid", "email"]
}
