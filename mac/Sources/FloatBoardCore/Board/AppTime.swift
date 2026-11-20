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

    // MARK: Offset groups and summer time

    /// The place picked when summer time is turned off (`meta` key): the zone in use is then that place's fixed
    /// winter offset (an `Etc/GMT` zone), and this remembers which place it came from.
    public static let placeKey = "time_zone_place"

    /// Zones that share a winter (standard) offset, e.g. "UTC+1": Berlin, Paris, Lagos…
    public struct ZoneGroup: Equatable, Sendable, Identifiable {
        public let offset: Int
        public let label: String
        public let zones: [String]
        public var id: Int { offset }
    }

    /// A zone's winter offset from UTC in seconds (its offset now, minus any summer time in force now).
    public static func standardOffset(_ z: TimeZone, at d: Date = Date()) -> Int {
        z.secondsFromGMT(for: d) - Int(z.daylightSavingTimeOffset(for: d))
    }
    /// True when the zone moves its clocks within the next year (summer time, e.g. London's BST).
    public static func hasSummerTime(_ z: TimeZone, at d: Date = Date()) -> Bool {
        guard let t = z.nextDaylightSavingTimeTransition(after: d) else { return false }
        return t.timeIntervalSince(d) < 366 * 86_400
    }
    /// "UTC+0", "UTC+1", "UTC−5", "UTC+5:30".
    public static func offsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let a = abs(seconds), h = a / 3600, m = (a % 3600) / 60
        return "UTC\(sign)\(h)" + (m == 0 ? "" : String(format: ":%02d", m))
    }
    /// The picker's zones grouped by winter offset, west to east. `matching` filters by name or by offset
    /// ("shanghai", "+1", "utc-5").
    public static func groups(matching query: String = "", at d: Date = Date()) -> [ZoneGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "−", with: "-")
        var by: [Int: [String]] = [:]
        for name in allZones {
            guard let z = TimeZone(identifier: name) else { continue }
            let off = standardOffset(z, at: d)
            let label = offsetLabel(off).lowercased().replacingOccurrences(of: "−", with: "-")
            if !q.isEmpty, !name.lowercased().contains(q), label != q, label != "utc" + q { continue }
            by[off, default: []].append(name)
        }
        return by.keys.sorted().map { ZoneGroup(offset: $0, label: offsetLabel($0), zones: by[$0]!.sorted()) }
    }
    /// The fixed winter-time zone for a place with summer time turned off ("Etc/GMT-1" is UTC+1; the sign is
    /// reversed in these names). Nil when the winter offset is not whole hours (e.g. Adelaide, UTC+9:30).
    public static func winterOnlyZone(for z: TimeZone, at d: Date = Date()) -> String? {
        let s = standardOffset(z, at: d)
        guard s % 3600 == 0 else { return nil }
        let h = s / 3600
        let name = h == 0 ? "Etc/GMT" : "Etc/GMT\(h > 0 ? "-" : "+")\(abs(h))"
        return TimeZone(identifier: name) != nil ? name : nil
    }
    /// The place the picker shows: the saved place when summer time is off for it, else the setting itself.
    public static func place(from db: DB) -> String {
        let saved = (try? db.query("SELECT value FROM meta WHERE key=?", [placeKey]) { DB.text($0, 0) }.first) // try?-ok: no place saved means the setting is the place
        if let saved, let z = TimeZone(identifier: saved), winterOnlyZone(for: z) == setting { return saved }
        return setting
    }
    /// True when the setting in use is a place's winter time with summer time turned off.
    public static func summerTimeOff(place: String) -> Bool { place != setting && setting.hasPrefix("Etc/") }
    /// Saves a place and whether its summer time is followed. Summer time on (or a place without it) saves the
    /// place itself, which follows the real clock changes automatically; off saves its fixed winter offset.
    /// A place whose winter offset has no fixed zone keeps summer time.
    public static func save(place: String, summerTime: Bool, to db: DB) throws {
        guard place != macSetting, !summerTime, let z = TimeZone(identifier: place), hasSummerTime(z),
              let winter = winterOnlyZone(for: z) else {
            try db.run("DELETE FROM meta WHERE key=?", [placeKey])
            try save(place, to: db)
            return
        }
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [placeKey, place])
        try save(winter, to: db)
    }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
