/// What FloatBoard asks Google for: Calendar events only (plus who signed in). No mail access.
public enum GoogleAuthConfig {
    public static let scopes: [String] = ["https://www.googleapis.com/auth/calendar.events", "openid", "email"]
}
