import Foundation

/// J12 and §9: a copy of each day's jots as a Markdown file `<folder>/YYYY-MM-DD.md`, dated by the app's time zone (the day
/// a jot was added). FloatBoard owns these files: each is rewritten whole and safely (a temporary file replaces it) when that
/// day's jots change; a day left with no jots loses its file only if FloatBoard wrote it.
public struct DailyFilesSettings: Codable, Equatable {
    public var on = true
    public var folder = "~/Code/Resources/braindumps/daily"
    public init(on: Bool = true, folder: String = "~/Code/Resources/braindumps/daily") { self.on = on; self.folder = folder }
    public var url: URL { URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true) }
}

@MainActor public struct DailyFiles {
    let store: Store
    public init(store: Store) { self.store = store }
    /// The first line of every file FloatBoard writes (so it never removes a file it did not write).
    public static let marker = "<!-- Written by FloatBoard from your jots; edits here are replaced. -->"
    static let settingsKey = "jot_daily_files", passKey = "jot_files_at", seqKey = "jot_files_seq"

    public var settings: DailyFilesSettings {
        guard let raw = (try? store.db.query("SELECT value FROM meta WHERE key=?", [Self.settingsKey]) { DB.text($0, 0) })?.first, // try?-ok: unreadable = defaults
              let s = try? JSONDecoder().decode(DailyFilesSettings.self, from: Data(raw.utf8)) else { return DailyFilesSettings() } // try?-ok: unreadable = defaults
        return s
    }

    public func save(_ s: DailyFilesSettings) {
        store.perform {
            let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.settingsKey, json])
            try store.db.run("DELETE FROM meta WHERE key=?", [Self.passKey])   // a new folder gets every day written at the next pass
        }
    }

    /// "2026-11-17" for a moment, in the app's zone.
    nonisolated public static func dayKey(_ d: Date) -> String {
        let c = AppTime.calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The file's text for a day's jots (oldest first), or nil when there are none.
    public func render(day: Date) -> String? {
        guard let span = AppTime.calendar.dateInterval(of: .day, for: day) else { return nil }
        let jots = JotStore(store: store).jots(addedFrom: span.start, to: span.end).reversed()
        guard !jots.isEmpty else { return nil }
        let title = DateFormatter()
        title.calendar = AppTime.calendar; title.timeZone = AppTime.zone; title.locale = Locale(identifier: "en_GB")
        title.dateFormat = "EEEE d MMMM yyyy"
        let time = DateFormatter()
        time.timeZone = AppTime.zone; time.locale = Locale(identifier: "en_GB"); time.dateFormat = "HH:mm"
        var out = Self.marker + "\n# Jots · " + title.string(from: span.start) + "\n"
        for j in jots {
            let tags = store.itemTags(j.shortID).all
            out += "\n## \(time.string(from: j.added)) · \(j.shortID.text) · \(j.kind.title)" + (tags.isEmpty ? "" : " · " + tags.joined(separator: ", ")) + "\n\n"
            out += j.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        return out
    }

    /// True when FloatBoard wrote this file (its first line is the marker).
    static func isOurs(_ file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false } // try?-ok: unreadable = not known to be ours, so never replaced
        defer { try? h.close() } // try?-ok: closing a file only read
        let head = (try? h.read(upToCount: marker.utf8.count)) ?? nil // try?-ok: unreadable = not ours
        return head.map { String(decoding: $0, as: UTF8.self) == marker } ?? false
    }

    /// Rewrites the files of every day whose jots changed since the last pass (all days at the first pass). Returns the
    /// days written or removed. Problems go to Activity; the pass is not marked done then, so it is tried again.
    @discardableResult
    public func refresh(now: Date = Date()) -> [String] {
        let s = settings
        guard s.on else { return [] }
        let last = (try? store.db.query("SELECT value FROM meta WHERE key=?", [Self.passKey]) { DB.text($0, 0) })?.first.flatMap(Double.init) // try?-ok: unknown = write every day
        let since = last.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        // Changed since the last pass by this Mac's write order (a jot arriving late with an older time still counts); a board
        // whose last pass predates the write order uses the time once.
        let js = JotStore(store: store)
        let upTo = js.lastChangeSeq()
        let lastSeq = (try? store.db.query("SELECT value FROM meta WHERE key=?", [Self.seqKey]) { DB.text($0, 0) })?.first.flatMap { Int64($0) } // try?-ok: unknown = use the time this once
        let changed = lastSeq.map { js.changed(afterSeq: $0) } ?? js.changed(since: since)
        let days = Dictionary(grouping: changed, by: { Self.dayKey($0.added) }).compactMapValues { $0.first?.added }
        if days.isEmpty && last != nil { return [] }   // nothing changed: no write (so the pass never feeds itself)
        var done: [String] = []
        do {
            try FileManager.default.createDirectory(at: s.url, withIntermediateDirectories: true)
            for (key, any) in days.sorted(by: { $0.key < $1.key }) {
                var file = s.url.appendingPathComponent(key + ".md")
                if let text = render(day: any) {
                    // A day file FloatBoard did not write (no marker on its first line) is never replaced: the jots go beside it.
                    if FileManager.default.fileExists(atPath: file.path), !Self.isOurs(file) {
                        let beside = s.url.appendingPathComponent(key + " (FloatBoard).md")
                        if !FileManager.default.fileExists(atPath: beside.path) {   // said once, when the jots first go beside it
                            store.activity("jots", .warning, "\(key).md in the daily files folder was not written by FloatBoard; it was left as it is",
                                           detail: "That day's jots are in \(beside.lastPathComponent) instead.")
                        }
                        guard !FileManager.default.fileExists(atPath: beside.path) || Self.isOurs(beside) else {
                            store.activity("jots", .warning, "Could not write that day's jots: \(key).md and \(beside.lastPathComponent) were not written by FloatBoard")
                            continue
                        }
                        file = beside
                    }
                    let tmp = s.url.appendingPathComponent(".\(key).md.tmp")
                    try Data(text.utf8).write(to: tmp, options: .atomic)
                    if FileManager.default.fileExists(atPath: file.path) {
                        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
                    } else {
                        try FileManager.default.moveItem(at: tmp, to: file)
                    }
                    done.append(key)
                } else {
                    // No jots left that day: only files FloatBoard wrote go (the day file, or the one beside a file of the owner's).
                    for f in [file, s.url.appendingPathComponent(key + " (FloatBoard).md")] where FileManager.default.fileExists(atPath: f.path) && Self.isOurs(f) {
                        try FileManager.default.removeItem(at: f)
                        if !done.contains(key) { done.append(key) }
                    }
                }
            }
            store.perform {
                try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.passKey, String(now.timeIntervalSince1970)])
                try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.seqKey, String(upTo)])
            }
        } catch {
            store.activity("jots", .error, "Could not write the daily jot files", detail: "\(s.folder): \(error)")
        }
        return done
    }
}
