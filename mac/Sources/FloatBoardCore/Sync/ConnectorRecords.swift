import Foundation
import SQLite3

/// One row of the `connectors` table, as the Connectors tab shows it. The connector's key is not here:
/// it lives in the credentials file (FloatBoardConnectors), never in the database.
public struct ConnectorInfo: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var settingsJSON: String
    public var settingsVersion: Int
    public var engineSettingsVersion: Int
    public var lastOK: Date?
    public var unreachableSince: Date?
    public var statusJSON: String

    /// settings_json as a dictionary (empty when unset or unreadable).
    public var settings: [String: Any] {
        // try?-ok: empty or unreadable settings behave as no settings
        ((try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8))) as? [String: Any]) ?? [:] // try?-ok: display only; saves refuse unreadable settings
    }
}

extension ConnectorInfo {
    /// Same engine: scheme, host (any case) and port match; path and trailing slash don't matter.
    public static func sameAddress(_ a: String, _ b: String) -> Bool {
        guard let x = URLComponents(string: a), let y = URLComponents(string: b) else { return a == b }
        func port(_ c: URLComponents) -> Int? { c.port ?? (c.scheme?.lowercased() == "https" ? 443 : c.scheme?.lowercased() == "http" ? 80 : nil) }
        return x.scheme?.lowercased() == y.scheme?.lowercased() && x.host?.lowercased() == y.host?.lowercased() && port(x) == port(y)
    }
}

public enum ConnectorRecordError: Error, CustomStringConvertible {
    case unsavable(String)
    case unreadableStored(String)
    case noConnector(String)
    public var description: String {
        switch self {
        case .unsavable(let k): return "These settings can't be saved (\(k) is not plain text, a number, a switch or a list)."
        case .unreadableStored(let id):
            return "The saved settings for \(id) can't be read, so nothing was saved (to avoid losing them). The raw text is in Activity."
        case .noConnector(let id): return "The connector \(id) has been removed, so its settings can't be saved."
        }
    }
}

extension Store {
    func loadConnectors() throws -> [ConnectorInfo] {
        try db.query("""
            SELECT id,name,base_url,settings_json,settings_version,engine_settings_version,last_ok,unreachable_since,status_json
            FROM connectors ORDER BY name, id
            """) { s in
            ConnectorInfo(id: DB.text(s, 0), name: DB.text(s, 1), baseURL: DB.text(s, 2), settingsJSON: DB.text(s, 3),
                          settingsVersion: Int(DB.int(s, 4)), engineSettingsVersion: Int(DB.int(s, 5)),
                          lastOK: sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : DB.date(s, 6),
                          unreachableSince: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : DB.date(s, 7),
                          statusJSON: DB.text(s, 8))
        }
    }

    /// Adds the connector, or points an existing one (same id) at an address. Settings and history are kept.
    /// A different address (scheme, host or port) is a different engine: its cursor, settings version it has seen,
    /// status and last sync are reset so nothing from the old engine is used with the new one.
    public func upsertConnector(id: String, name: String, baseURL: String) throws {
        try performThrowing {
            let old = try db.query("SELECT base_url FROM connectors WHERE id=?", [id]) { DB.text($0, 0) }.first
            // Version 1, ahead of a new engine's 0, so the first sync pushes the settings (and the group list).
            try db.run("INSERT OR IGNORE INTO connectors(id,name,settings_json,settings_version) VALUES(?,?,'{}',1)", [id, name])
            if old == nil { try restoreArchivedSettings(id: id, name: name, baseURL: baseURL) }
            if let old, !old.isEmpty, !ConnectorInfo.sameAddress(old, baseURL) {
                try db.run("""
                    UPDATE connectors SET name=?, base_url=?, unreachable_since=NULL, cursor='', engine_settings_version=0,
                           status_json='{}', last_ok=NULL WHERE id=?
                    """, [name, baseURL, id])
                try db.run("DELETE FROM meta WHERE key=?", ["connected_since:\(id)"])
                try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["connector_added:\(id)", String(Date().timeIntervalSince1970)])
                activity("connector:\(id)", .info, "Moved \(name) to a new address; sync starts afresh there",
                         detail: (URL(string: old)?.host ?? old) + " -> " + (URL(string: baseURL)?.host ?? baseURL))
            } else {
                try db.run("UPDATE connectors SET name=?, base_url=?, unreachable_since=NULL WHERE id=?", [name, baseURL, id])
                try db.run("INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)", ["connector_added:\(id)", String(Date().timeIntervalSince1970)])
                activity("connector:\(id)", .info, "Connected \(name)", detail: URL(string: baseURL)?.host ?? baseURL)
            }
        }
    }

    /// Removes the connector's row. Its cards, their history and corrections stay, and so do the user's settings for it
    /// (rules, group notes, lists, learned preferences): they move to `connector_archive` and come back when a connector
    /// with the same id is added again. Its unsent changes are kept for the record but detached, so they are never sent
    /// (not even to a later connector with the same id).
    public func removeConnector(id: String) throws {
        try performThrowing {
            try db.run("UPDATE outbox SET detached=1, detach_reason='removed' WHERE connector=? AND sent IS NULL AND detached=0", [id])
            let n = try db.query("SELECT changes()") { DB.int($0, 0) }.first ?? 0
            try db.run("""
                INSERT OR REPLACE INTO connector_archive(id,removed_at,name,base_url,settings_json,settings_version)
                SELECT id, ?, name, base_url, settings_json, settings_version FROM connectors WHERE id=?
                """, [Date(), id])
            try db.run("DELETE FROM connectors WHERE id=?", [id])
            try db.run("DELETE FROM meta WHERE key IN (?,?)", ["connected_since:\(id)", "connector_added:\(id)"])
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["user_removed:\(id)", String(Date().timeIntervalSince1970)])
            activity("connector:\(id)", .info, "Removed connector \(id); its tasks, history and settings are kept")
            if n > 0 {
                activity("connector:\(id)", .info, "\(n) unsent change\(n == 1 ? "" : "s") kept but not sent — connector removed")
            }
        }
    }

    /// A connector added again with an id that was removed before gets the settings it had then (newest removal at the
    /// same engine address), at a version above the old one so they are pushed. Settings kept from a different engine are
    /// never restored (they could be pushed into someone else's engine): they stay archived and the skip is logged.
    /// Must run inside a transaction, right after the row is inserted.
    func restoreArchivedSettings(id: String, name: String, baseURL: String) throws {
        let all = try db.query("""
            SELECT removed_at, settings_json, settings_version, base_url FROM connector_archive WHERE id=? AND restored_at IS NULL
            ORDER BY removed_at DESC
            """, [id], { s in (sqlite3_column_double(s, 0), DB.text(s, 1), Int(DB.int(s, 2)), DB.text(s, 3)) })
        guard let a = all.first(where: { ConnectorInfo.sameAddress($0.3, baseURL) }) else {
            if let other = all.first {
                activity("connector:\(id)", .info, "Kept your earlier settings for \(name) aside: they were for a different engine",
                         detail: "They stay saved and come back if you connect to " + (URL(string: other.3)?.host ?? other.3) + " again.")
            }
            return
        }
        let json = a.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty, json != "{}" else {
            try db.run("UPDATE connector_archive SET restored_at=? WHERE id=? AND removed_at=?", [Date(), id, a.0])
            return
        }
        try db.run("UPDATE connectors SET settings_json=?, settings_version=? WHERE id=?", [a.1, max(a.2, 0) + 1, id])
        try db.run("UPDATE connector_archive SET restored_at=? WHERE id=? AND removed_at=?", [Date(), id, a.0])
        activity("connector:\(id)", .info, "Restored your earlier settings for \(name)",
                 detail: "Kept when it was removed; they will be sent to the engine.")
    }

    enum GroupChange { case added(String), renamed(String, String), deleted(String) }

    /// The board's groups changed: every connector gets a new settings version (so the group list is pushed) and a
    /// `settings` outbox row. A rename carries the group's note and the default group; a delete drops the note and
    /// resets a default group that pointed at it. Must run inside the transaction that changed the groups.
    func groupsChanged(_ change: GroupChange, now: Date) throws {
        let rows = try db.query("SELECT id, settings_json FROM connectors ORDER BY id") { (DB.text($0, 0), DB.text($0, 1)) }
        for (id, json) in rows {
            var dict: [String: Any]? = [:]
            if !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] } catch { dict = nil }
            }
            if var d = dict {
                var notes = d["group_notes"] as? [String: Any]
                switch change {
                case .added: break
                case .renamed(let from, let to):
                    if let note = notes?[from] { notes?[from] = nil; if notes?[to] == nil { notes?[to] = note } }
                    if d["default_group"] as? String == from { d["default_group"] = to }
                case .deleted(let name):
                    notes?[name] = nil
                    if d["default_group"] as? String == name { d["default_group"] = nil }
                }
                if let notes { d["group_notes"] = notes }
                let data = try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
                try db.run("UPDATE connectors SET settings_json=? WHERE id=?", [String(decoding: data, as: UTF8.self), id])
            } else {
                activity("connector:\(id)", .warning, "Groups changed, but this connector's saved settings can't be read, so its group notes weren't updated")
            }
            try db.run("UPDATE connectors SET settings_version=settings_version+1 WHERE id=?", [id])
            let version = try db.query("SELECT settings_version FROM connectors WHERE id=?", [id]) { DB.int($0, 0) }.first ?? 0
            let uuid = UUID().uuidString
            try insertOutbox(uuid, id, .settings, ["version": String(version), "at": String(now.timeIntervalSince1970)], now)
            activity("connector:\(id)", .info, "Groups changed; the group list will be sent (settings version \(version))", trace: uuid)
        }
    }

    /// Merges `values` into the connector's stored settings (keys not given, such as "learned" or "default_group", are
    /// kept), bumps settings_version and queues a `settings` outbox row, all in one transaction. Refuses (and logs) when
    /// the connector no longer exists or its stored settings can't be read, so nothing stored is ever lost.
    public func saveConnectorSettings(connector id: String, values: [String: Any], now: Date = Date()) throws {
        for (k, v) in values where !JSONSerialization.isValidJSONObject(["v": v]) { throw ConnectorRecordError.unsavable(k) }
        guard let json = try db.query("SELECT settings_json FROM connectors WHERE id=?", [id], { DB.text($0, 0) }).first else {
            activity("connector:\(id)", .warning, "Settings not saved: the connector was removed")
            throw ConnectorRecordError.noConnector(id)
        }
        var dict: [String: Any] = [:]
        if !json.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                guard let d = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    throw ConnectorRecordError.unreadableStored(id)
                }
                dict = d
            } catch {
                activity("connector:\(id)", .error, "Settings not saved: the stored settings can't be read", detail: json)
                throw ConnectorRecordError.unreadableStored(id)
            }
        }
        for (k, v) in values { dict[k] = v }
        let merged = dict
        try performThrowing {
            // Store work is all on the main actor, so the row read above can't change before this runs.
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            try db.run("UPDATE connectors SET settings_json=?, settings_version=settings_version+1 WHERE id=?",
                       [String(decoding: data, as: UTF8.self), id])
            let version = try db.query("SELECT settings_version FROM connectors WHERE id=?", [id]) { DB.int($0, 0) }.first ?? 0
            let uuid = UUID().uuidString
            try insertOutbox(uuid, id, .settings, ["version": String(version), "at": String(now.timeIntervalSince1970)], now)
            activity("connector:\(id)", .info, "Settings saved (version \(version))", detail: values.keys.sorted().joined(separator: ", "),
                     trace: uuid)
        }
    }
}
