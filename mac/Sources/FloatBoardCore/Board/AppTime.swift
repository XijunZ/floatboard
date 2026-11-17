import Foundation

/// The time zone FloatBoard shows and stores dates in: UK time (Europe/London) unless changed, or "follow this Mac".
/// The choice is saved on the board (`meta` key `time_zone`: "mac" or a zone name).
public enum AppTime {
    public static let metaKey = "time_zone"
    public static let macSetting = "mac"
    public static let defaultZone = "Europe/London"
    /// Posted (on the main thread) whenever the zone setting changes, so screens can redraw.
    public static let didChange = Notification.Name("FloatBoardTimeZoneChanged")

    nonisolated(unsafe) private static var fixed: TimeZone = TimeZone(identifier: defaultZone)!
    nonisolated(unsafe) public private(set) static var followsMac = false

    /// The zone in use. When following this Mac it is the Mac's zone right now. Setting it pins that zone.
    public static var zone: TimeZone {
        get { followsMac ? TimeZone.current : fixed }
        set { fixed = newValue; followsMac = false; changed() }
    }
    /// A Gregorian calendar in `zone`. Read it each time: it follows `zone`.
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    /// The setting as saved: "mac" or a zone name.
    public static var setting: String { followsMac ? macSetting : fixed.identifier }

    /// Uses a setting in memory only; false (and no change) for a name that is not a time zone.
    @discardableResult
    public static func apply(_ setting: String) -> Bool {
        if setting == macSetting { followsMac = true; changed(); return true }
        guard let z = TimeZone(identifier: setting) else { return false }
        fixed = z; followsMac = false; changed()
        return true
    }
    /// Reads the saved setting; London if none is saved or it is not a time zone.
    public static func load(from db: DB) {
        let saved = (try? db.query("SELECT value FROM meta WHERE key=?", [metaKey]) { DB.text($0, 0) }.first) // try?-ok: nothing saved yet means London
        if let saved, apply(saved) { return }
        apply(defaultZone)
    }
    /// Uses the setting and saves it on the board. A name that is not a time zone is refused and nothing changes.
    public static func save(_ setting: String, to db: DB) throws {
        guard setting == macSetting || TimeZone(identifier: setting) != nil else { return }
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [metaKey, setting])
        apply(setting)
    }
    /// Every zone name the picker offers, sorted.
    public static var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
