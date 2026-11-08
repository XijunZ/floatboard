import Foundation

public enum ActivityLevel: String {
    case info, warning, error
}

public struct ActivityEntry {
    public let at: Date
    public let component: String
    public let level: ActivityLevel
    public let message: String
    public let detail: String?
    public let trace: String?
    public var seen: Bool
}

extension Store {
    /// Records one line in the activity log. If even that fails, stderr is the last resort.
    public func activity(_ component: String, _ level: ActivityLevel, _ message: String,
                         detail: String? = nil, trace: String? = nil) {
        if txOpen { txActivity.append((Date(), component, level, message, detail, trace)); return }
        writeActivity(Date(), component, level, message, detail, trace)
    }

    func flushTxActivity() {
        let rows = txActivity
        txActivity = []
        for r in rows { writeActivity(r.0, r.1, r.2, r.3, r.4, r.5) }
    }

    private func writeActivity(_ at: Date, _ component: String, _ level: ActivityLevel, _ message: String,
                               _ detail: String?, _ trace: String?) {
        do {
            try db.run("INSERT INTO activity(at,component,level,message,detail,trace,seen) VALUES(?,?,?,?,?,?,0)",
                       [at, component, level.rawValue, message, detail, trace])
        } catch {
            FileHandle.standardError.write(Data("FloatBoard: could not write activity row (\(message)): \(error)\n".utf8))
        }
    }

    /// Newest first.
    public func recentActivity(limit: Int) -> [ActivityEntry] {
        fetchActivity("SELECT at,component,level,message,detail,trace,seen FROM activity ORDER BY at DESC, id DESC LIMIT ?", [limit])
    }

    /// All rows sharing one trace id, oldest first.
    public func trace(_ id: String) -> [ActivityEntry] {
        fetchActivity("SELECT at,component,level,message,detail,trace,seen FROM activity WHERE trace=? ORDER BY at, id", [id])
    }

    public func markActivitySeen(upTo: Date) {
        do { try db.run("UPDATE activity SET seen=1 WHERE at<=?", [upTo]) } catch {
            activityMaintenanceFailed("Could not mark activity seen", error)
        }
    }

    /// Drops rows older than 90 days. Runs at launch.
    public func pruneActivity() {
        do { try db.run("DELETE FROM activity WHERE at<?", [Date().addingTimeInterval(-90 * 86400)]) } catch {
            activityMaintenanceFailed("Could not prune activity", error)
        }
    }

    /// Maintenance failures are logged as an Activity warning; `activity` itself falls back to stderr.
    public func activityMaintenanceFailed(_ message: String, _ error: Error) {
        activity("store", .warning, message, detail: "\(error)")
    }

    private func fetchActivity(_ sql: String, _ args: [Any?]) -> [ActivityEntry] {
        do {
            return try db.query(sql, args) { s in
                let detail = DB.text(s, 4), trace = DB.text(s, 5)
                return ActivityEntry(at: DB.date(s, 0) ?? Date(), component: DB.text(s, 1),
                                     level: ActivityLevel(rawValue: DB.text(s, 2)) ?? .info,
                                     message: DB.text(s, 3), detail: detail.isEmpty ? nil : detail,
                                     trace: trace.isEmpty ? nil : trace, seen: DB.int(s, 6) != 0)
            }
        } catch {
            // stderr only: logging a failed read into the same table risks recursion.
            FileHandle.standardError.write(Data("FloatBoard: could not read activity: \(error)\n".utf8))
            return []
        }
    }
}
