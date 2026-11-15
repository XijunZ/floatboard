import Foundation

/// One thing that is wrong without anything having said so. `id` is stable while the problem lasts.
public struct HealthProblem: Equatable {
    public let id: String
    public let message: String
    public let since: Date
    public init(id: String, message: String, since: Date) { self.id = id; self.message = message; self.since = since }

    /// Problems about the app itself (Activity window) rather than one connector (Connectors tab).
    public var isAppWide: Bool { id == "errors" || id == "backup" }
}

/// The deterministic watchdog: conditions that produce no error of their own. Thresholds are fixed:
/// unreachable > 1 h, oldest waiting change > 1 h, engine last_run_ok > 2 h old, any needs_attention line,
/// newest backup > 36 h old, unseen errors in the last 24 h. The engine's oldest_unprocessed_event is deliberately
/// NOT used: it includes events legitimately blocked on a disconnected inbox, which surface via needs_attention.
@MainActor
public enum Health {
    static let hour: TimeInterval = 3600

    /// Decides from stored state only. It changes nothing in the board; the one thing it may write is an Activity row
    /// when a read fails or a backup file turns out to be damaged (reported once per file).
    public static func evaluate(store: Store, backups: Backups?, now: Date) -> [HealthProblem] {
        var out: [HealthProblem] = []
        do {
            for c in try store.loadConnectors() { out += connectorProblems(c, store: store, now: now) }
        } catch {
            store.activity("health", .error, "Could not read the connectors to check their health", detail: "\(error)")
        }
        if let backups {
            if let newest = newestVerifiedBackup(backups, store: store) {
                if now.timeIntervalSince(newest) > 36 * hour {
                    out.append(HealthProblem(id: "backup", message: "The newest verified backup of your board is over 36 hours old", since: newest))
                }
            } else if let first = metaDate("first_launch_at", store), now.timeIntervalSince(first) > 36 * hour {
                // A fresh install gets 36 hours of grace before "no backup" is a problem.
                out.append(HealthProblem(id: "backup", message: "There is no verified backup of your board", since: first))
            }
        }
        do {
            let r = try store.db.query("SELECT count(*), min(at) FROM activity WHERE level='error' AND seen=0 AND at>=?",
                                       [now.addingTimeInterval(-24 * hour)]) { (DB.int($0, 0), DB.date($0, 1)) }.first
            if let r, r.0 > 0 {
                out.append(HealthProblem(id: "errors", message: r.0 == 1 ? "1 error in the last 24 hours hasn't been looked at"
                                                                      : "\(r.0) errors in the last 24 hours haven't been looked at",
                                         since: r.1 ?? now))
            }
        } catch {
            store.activity("health", .error, "Could not check Activity for new errors", detail: "\(error)")
        }
        return out.sorted { $0.id < $1.id }
    }

    private static func connectorProblems(_ c: ConnectorInfo, store: Store, now: Date) -> [HealthProblem] {
        var out: [HealthProblem] = []
        if let since = c.unreachableSince, now.timeIntervalSince(since) > hour {
            out.append(HealthProblem(id: "unreachable:\(c.id)", message: "\(c.name) hasn't been reachable for over an hour", since: since))
        }
        let waiting = store.waitingCount(connector: c.id)
        if waiting > 0, let oldest = oldestWaiting(c.id, store), now.timeIntervalSince(oldest) > hour {
            out.append(HealthProblem(id: "waiting:\(c.id)",
                                     message: "\(waiting == 1 ? "A change" : "\(waiting) changes") for \(c.name) \(waiting == 1 ? "has" : "have") been waiting to send for over an hour",
                                     since: oldest))
        }
        if c.lastOK == nil, let added = metaDate("connector_added:\(c.id)", store), now.timeIntervalSince(added) > hour {
            out.append(HealthProblem(id: "never-synced:\(c.id)",
                                     message: "\(c.name) has never synced. Open the connect link again or check Connectors.", since: added))
        }
        let parsed = statusObject(c.statusJSON)
        if parsed.unreadable {
            out.append(HealthProblem(id: "status-unreadable:\(c.id)", message: "Couldn't read \(c.name)'s status", since: c.lastOK ?? now))
        }
        guard let status = parsed.object else { return out }
        let lines = (status["needs_attention"] as? [String]) ?? []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            // The text comes from the engine and may quote email content: redact it, and build the id from the redacted line
            // with digits removed, so a changing count or time doesn't make the same problem look new.
            let safe = Redact.attention(line)
            out.append(HealthProblem(id: "attention:\(c.id):\(stableHash(normalise(safe)))", message: "\(c.name): \(safe)", since: c.lastOK ?? now))
        }
        // Engine stall: only judged while the connector is reachable (otherwise the status is just old).
        if c.unreachableSince == nil {
            let runOK = status["last_run_ok"] as? String
            if let runOK {
                if let d = parseDate(runOK), now.timeIntervalSince(d) > 2 * hour {
                    out.append(HealthProblem(id: "engine-stalled:\(c.id)", message: "\(c.name)'s engine hasn't finished a run for over 2 hours", since: d))
                }
            } else if let connected = connectedSince(c.id, store), now.timeIntervalSince(connected) > 2 * hour {
                out.append(HealthProblem(id: "engine-stalled:\(c.id)", message: "\(c.name)'s engine hasn't reported a finished run since it was connected", since: connected))
            }
        }
        return out
    }

    private static func oldestWaiting(_ id: String, _ store: Store) -> Date? {
        do {
            return try store.db.query("SELECT min(created) FROM outbox WHERE connector=? AND sent IS NULL AND detached=0", [id]) { DB.date($0, 0) }.first ?? nil
        } catch {
            store.activity("health", .error, "Could not read the outbox to check for stuck changes", detail: "\(error)")
            return nil
        }
    }

    private static func connectedSince(_ id: String, _ store: Store) -> Date? {
        do {
            let v = try store.db.query("SELECT value FROM meta WHERE key=?", ["connected_since:\(id)"]) { DB.text($0, 0) }.first
            return v.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        } catch {
            store.activity("health", .error, "Could not read when a connector was connected", detail: "\(error)")
            return nil
        }
    }

    private static func statusObject(_ json: String) -> (object: [String: Any]?, unreadable: Bool) {
        guard !json.isEmpty, json != "{}" else { return (nil, false) }
        do {
            if let o = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { return (o, false) }
            return (nil, true)
        } catch { return (nil, true) }
    }

    static func normalise(_ s: String) -> String {
        let noDigits = s.unicodeScalars.filter { !CharacterSet.decimalDigits.contains($0) }
        return String(String.UnicodeScalarView(noDigits)).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func metaDate(_ key: String, _ store: Store) -> Date? {
        do {
            let v = try store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) }.first
            return v.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        } catch {
            store.activity("health", .error, "Could not read a saved date (\(key))", detail: "\(error)")
            return nil
        }
    }

    /// Verified results by file path and modification time, so a backup is checked once, not every 15 minutes.
    private static var verifiedCache: [String: Bool] = [:]

    private static func newestVerifiedBackup(_ backups: Backups, store: Store) -> Date? {
        for b in backups.list().prefix(5) {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: b.url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0 // try?-ok: missing file just fails verification below
            let key = "\(b.url.path)|\(mtime)"
            let ok: Bool
            if let cached = verifiedCache[key] { ok = cached } else {
                ok = Backups.isVerified(b.url)
                verifiedCache[key] = ok
                if !ok { store.activity("backup", .warning, "A backup file is damaged or empty and doesn't count", detail: b.url.lastPathComponent) }
            }
            if ok { return b.date }
        }
        return nil
    }

    static func parseDate(_ s: String) -> Date? {
        let a = ISO8601DateFormatter()
        if let d = a.date(from: s) { return d }
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: s) { return d }
        a.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]   // no zone: read as UTC
        return a.date(from: s)
    }

    /// FNV-1a: stable across launches (String.hashValue is not).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: Logging

    /// Evaluates, then writes exactly one Activity warning per NEW problem and one info row per cleared one. The set of
    /// open problems is kept in the meta table, so a problem that persists is not logged again, even after a relaunch.
    @discardableResult
    public static func refresh(store: Store, backups: Backups?, now: Date = Date()) -> [HealthProblem] {
        store.detachUnreadableOutbox()
        backfillDates(store: store, now: now)
        let all = evaluate(store: store, backups: backups, now: now)
        let acked = loadAcknowledged(store)
        let problems = all.filter { !acked.contains($0.id) }
        if !acked.isEmpty { saveAcknowledged(acked.intersection(Set(all.map(\.id))), store) }   // a problem that went away may alert again later
        var open: [String: String] = [:]
        do {
            if let raw = try store.db.query("SELECT value FROM meta WHERE key='health_open'", [], { DB.text($0, 0) }).first {
                if let d = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] { open = d }
                else { throw DBError.sql("not a list of text values") }
            }
        } catch {
            store.activity("health", .warning, "The saved list of open problems can't be read; starting it again", detail: "\(error)")
        }
        let current = Dictionary(all.map { ($0.id, $0.message) }, uniquingKeysWith: { a, _ in a })
        for p in all where open[p.id] == nil {
            store.activity("health", .warning, p.message, detail: p.id)
        }
        for (id, message) in open.sorted(by: { $0.key < $1.key }) where current[id] == nil {
            store.activity("health", .info, "Resolved: \(message)", detail: id)
        }
        if current != open {
            do {
                let data = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
                try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('health_open',?)", [String(decoding: data, as: UTF8.self)])
            } catch {
                store.activity("health", .error, "Could not save the list of open problems", detail: "\(error)")
            }
        }
        store.healthProblems = problems
        return problems
    }

    // MARK: Dismissing and first-seen dates

    /// Hides a problem from the bar until it goes away (or, for connector lines, until its text changes: the id holds the text).
    public static func acknowledge(_ id: String, store: Store) {
        var acked = loadAcknowledged(store)
        acked.insert(id)
        saveAcknowledged(acked, store)
        store.healthProblems.removeAll { $0.id == id }
    }

    private static func loadAcknowledged(_ store: Store) -> Set<String> {
        do {
            guard let raw = try store.db.query("SELECT value FROM meta WHERE key='health_ack'", [], { DB.text($0, 0) }).first else { return [] }
            if let list = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] { return Set(list) }
            throw DBError.sql("not a list of text values")
        } catch {
            store.activity("health", .warning, "The saved list of dismissed problems can't be read; starting it again", detail: "\(error)")
            return []
        }
    }

    private static func saveAcknowledged(_ ids: Set<String>, _ store: Store) {
        do {
            let data = try JSONSerialization.data(withJSONObject: ids.sorted())
            try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('health_ack',?)", [String(decoding: data, as: UTF8.self)])
        } catch {
            store.activity("health", .error, "Could not save the list of dismissed problems", detail: "\(error)")
        }
    }

    /// Dates the watchdog needs but older databases don't have: when each connector was added, and when it first worked
    /// (its last successful sync, which may already be old).
    private static func backfillDates(store: Store, now: Date) {
        do {
            let t = String(now.timeIntervalSince1970)
            try store.db.run("INSERT OR IGNORE INTO meta(key,value) VALUES('first_launch_at',?)", [t])
            try store.db.run("INSERT OR IGNORE INTO meta(key,value) SELECT 'connector_added:' || id, ? FROM connectors", [t])
            try store.db.run("INSERT OR IGNORE INTO meta(key,value) SELECT 'connected_since:' || id, CAST(last_ok AS TEXT) FROM connectors WHERE last_ok IS NOT NULL")
        } catch {
            store.activity("health", .error, "Could not save the dates the health check needs", detail: "\(error)")
        }
    }
}
