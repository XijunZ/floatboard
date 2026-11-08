import FloatBoardCore
import Foundation

public struct SyncReport: Equatable {
    public var sent = 0
    public var failed = 0
    public var applied = ReconcileSummary()
    /// Proposals the engine handed over in this run (whether or not they changed anything).
    public var received = 0
    public var error: String?
}

/// The durable loop between the board and an online connector. Nothing here is fire-and-forget: an outbox row is
/// marked sent only when the engine acknowledges its uuid, the proposals cursor moves only after the local commit,
/// and every failure leaves one Activity row (component `connector:<id>`).
public enum ConnectorSync {
    static let batchSize = 50
    /// Settings only the app uses: never pushed (the engine rejects keys outside its schema).
    static let appOnlySettings: Set<String> = ["default_group", "auto_add"]
    static let authMessage = "The engine didn't accept this connection's key."
    /// While a delivered reply draft request waits for its answer, the app syncs that connector this often (seconds).
    public static let replyDraftPollInterval: TimeInterval = 15
    /// The last drafts/run problem reported per connector, so a poll every 15 s doesn't repeat the same warning.
    @MainActor static var draftsRunReported: [String: String] = [:]

    @MainActor
    public static func run(connector id: String, store: Store, client: ConnectorClient, now: Date) async -> SyncReport {
        var report = SyncReport()
        let component = "connector:\(id)"
        do {
            try store.db.run("INSERT OR IGNORE INTO connectors(id,name,settings_json,settings_version) VALUES(?,?,'{}',1)", [id, id])
        } catch {
            store.activity(component, .error, "Could not prepare the connector record", detail: "\(error)")
            report.error = "\(error)"
            return report
        }

        // 1. Outbox, oldest first, 50 at a time. A failure stops SENDING only; the other steps still run.
        // Order is strict: while the oldest unsent row is backing off, nothing newer goes out.
        var tried = Set<String>()
        sending: while true {
            if let next = store.oldestUnsentNextTry(connector: id), next > now { break }
            let batch = store.pendingOutbox(connector: id, limit: batchSize, now: now).filter { !tried.contains($0.uuid) }
            if batch.isEmpty { break }
            batch.forEach { tried.insert($0.uuid) }
            let uuids = batch.map(\.uuid)
            store.setOutboxInFlight(uuids, true)
            defer { store.setOutboxInFlight(uuids, false) }
            do {
                let acked = try await client.send(batch)
                store.markSent(acked, now: now, log: false)
                report.sent += acked.count
                store.activity(component, .info, "Sent \(acked.count) of \(batch.count) events", detail: acked.joined(separator: ","), trace: acked.first)
                let missing = uuids.filter { !acked.contains($0) }
                if !missing.isEmpty {
                    store.markFailed(missing, error: "The engine did not acknowledge this event.", now: now, log: false)
                    report.failed += missing.count
                    _ = fail(id, store, &report, now, "The engine acknowledged \(acked.count) of \(batch.count) events",
                             detail: "Not acknowledged, will retry: " + missing.joined(separator: ","), level: .warning, trace: missing.first)
                    break sending
                }
            } catch let e as ConnectorError {
                if e == .auth { return failAuth(id, store, &report, now) }
                store.markFailed(uuids, error: e.description, now: now, log: false)
                report.failed += batch.count
                _ = fail(id, store, &report, now, "Could not send \(batch.count) events", detail: e.description + " Events: " + uuids.joined(separator: ","),
                         level: .warning, trace: uuids.first)
                break sending
            } catch {
                _ = fail(id, store, &report, now, "Could not send events", detail: "\(error)", trace: uuids.first)
                break sending
            }
        }

        // 1b. A delivered reply draft request still waiting: ask the engine to work on one now, so the pull below can
        // bring its answer. A problem here is only a warning (the hourly run still drafts it); the sync carries on.
        if store.connectorsAwaitingReplyDrafts().contains(id) {
            do {
                try await client.runDrafts()
                draftsRunReported[id] = nil
            } catch let e as ConnectorError {
                if e == .auth { return failAuth(id, store, &report, now) }
                reportDraftsRun(id, store, e.description)
            } catch {
                reportDraftsRun(id, store, "\(error)")
            }
        }

        // 2. Proposals, page by page; the cursor is saved only after the page is applied.
        var traceID: String?
        do {
            let row = try connectorRow(id, store)
            // Unreadable settings only fail the settings step above. Proposals carry on with defaults (the board's first
            // group, auto-add on) and one warning per distinct stored text.
            let settings: [String: Any]
            do {
                settings = try parse(row.settingsJSON, id)
                unreadableSettingsReported[id] = nil
            } catch {
                settings = [:]
                if unreadableSettingsReported[id] != row.settingsJSON {
                    unreadableSettingsReported[id] = row.settingsJSON
                    store.activity(component, .warning, "The connector's saved settings can't be read; using the first group and auto-add until they are fixed",
                                   detail: "\(error)")
                }
            }
            let defaultGroup = (settings["default_group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? store.areas.first?.name ?? "Personal"
            let autoAdd = settings["auto_add"] as? Bool ?? true
            var cursor: String? = row.cursor.isEmpty ? nil : row.cursor
            var finished = false
            for _ in 0..<1000 {
                traceID = cursor
                let page = try await client.proposalsPage(after: cursor)
                let proposals = try Reconciler.decodeBatch(page.items, store: store)
                traceID = proposals.first?.id ?? cursor
                report.received += proposals.count
                let summary = try Reconciler.apply(proposals, connector: id, store: store, defaultGroup: defaultGroup, autoAdd: autoAdd)
                add(&report.applied, summary)
                guard let next = page.cursor, next != cursor else { finished = true; break }
                try store.db.run("UPDATE connectors SET cursor=? WHERE id=?", [next, id])
                cursor = next
            }
            if !finished {
                store.activity(component, .warning, "Stopped after 1000 pages of proposals; the rest will come next time",
                               detail: "cursor \(cursor ?? "none")", trace: cursor)
            }
        } catch let e as ConnectorError {
            if e == .auth { return failAuth(id, store, &report, now) }
            _ = fail(id, store, &report, now, "Could not fetch proposals", detail: e.description, trace: traceID)
        } catch {
            _ = fail(id, store, &report, now, "Could not fetch proposals", detail: "\(error)", trace: traceID)
        }

        // 3. Settings, when the engine is behind. After proposals, so a learned update applied there (which bumps the
        // version) is what gets pushed, never an older local copy. A stale answer (409) bumps the version and pushes once more.
        do {
            try bumpIfTimeZoneChanged(id, store)
            for attempt in 0..<2 {
                let row = try connectorRow(id, store)
                guard row.engineVersion < row.version else { break }
                do {
                    try await client.putSettings(values: try settingsValues(row.settingsJSON, id, store), version: row.version)
                    try store.db.run("UPDATE connectors SET engine_settings_version=? WHERE id=?", [row.version, id])
                    try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [timeZoneKey(id), TimeZone.current.identifier])
                    break
                } catch ConnectorError.staleSettings(let engine) {
                    guard let engine else {
                        _ = fail(id, store, &report, now, "The engine said the settings were stale but not which version",
                                 detail: "Will try again next time.")
                        break
                    }
                    if attempt == 1 {
                        store.activity(component, .warning, "The engine still reports newer settings; will retry next time",
                                       detail: "engine version \(engine), local \(row.version)")
                        break
                    }
                    let next = max(row.version, engine) + 1
                    try store.db.run("UPDATE connectors SET settings_version=? WHERE id=?", [next, id])
                    store.activity(component, .warning, "The engine had newer settings; sending again",
                                   detail: "engine version \(engine), local \(row.version) -> \(next)")
                }
            }
        } catch let e as ConnectorError {
            if e == .auth { return failAuth(id, store, &report, now) }
            _ = fail(id, store, &report, now, "Could not send settings", detail: e.description)
        } catch {
            _ = fail(id, store, &report, now, "Could not send settings", detail: "\(error)")
        }

        // 4. Status.
        do {
            let status = try await client.status()
            let data = try JSONEncoder().encode(status)
            try store.db.run("UPDATE connectors SET status_json=?, engine_settings_version=? WHERE id=?",
                             [String(decoding: data, as: UTF8.self), status.settingsVersion, id])
        } catch let e as ConnectorError {
            if e == .auth { return failAuth(id, store, &report, now) }
            _ = fail(id, store, &report, now, "Could not read the engine's status", detail: e.description)
        } catch {
            _ = fail(id, store, &report, now, "Could not read the engine's status", detail: "\(error)")
        }

        if report.error != nil { return report }

        do {
            try store.db.run("UPDATE connectors SET last_ok=?, unreachable_since=NULL WHERE id=?", [now, id])
            // When it first worked: the health watchdog needs it to tell "engine never reported a run" from "just connected".
            try store.db.run("INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)", ["connected_since:\(id)", String(now.timeIntervalSince1970)])
        } catch {
            store.activity(component, .error, "Could not record the successful sync", detail: "\(error)")
        }
        return report
    }

    @MainActor
    static func reportDraftsRun(_ id: String, _ store: Store, _ why: String) {
        guard draftsRunReported[id] != why else { return }
        draftsRunReported[id] = why
        store.activity("connector:\(id)", .warning, "Could not ask the engine to work on waiting reply drafts; they will come with a later sync",
                       detail: why)
    }

    // MARK: Re-check

    public struct RecheckOutcome {
        public var summary: ReconcileSummary?
        /// Plain words for the user: the result, or why nothing happened.
        public var notice: String
        public var stillRunning = false
        /// True when any pass failed (the alert says so).
        public var problems = false
        public init(summary: ReconcileSummary?, notice: String, stillRunning: Bool = false, problems: Bool = false) {
            self.summary = summary; self.notice = notice; self.stillRunning = stillRunning; self.problems = problems
        }
    }

    static let maxRecheckPasses = 10

    /// "2 added · 11 withdrawn · 3 kept because you'd changed them · 5 already on your board"; zero parts are left out.
    public static func recheckLine(_ s: ReconcileSummary) -> String {
        var parts: [String] = []
        if s.added > 0 { parts.append("\(s.added) added") }
        if s.refreshed > 0 { parts.append("\(s.refreshed) updated") }
        if s.withdrawn > 0 { parts.append("\(s.withdrawn) withdrawn") }
        if s.keptTouched > 0 { parts.append("\(s.keptTouched) kept because you'd changed them") }
        if s.skippedExisting > 0 { parts.append("\(s.skippedExisting) already on your board") }
        return parts.isEmpty ? "Nothing changed" : parts.joined(separator: " · ")
    }

    /// Looks again at the last `days` days of email. Never deletes: the engine re-judges and the reconciler adds, refreshes
    /// or withdraws untouched cards and leaves touched ones alone. A backup is taken first; if it fails nothing happens.
    @MainActor
    public static func recheck(connector id: String, days: Int, store: Store, client: ConnectorClient, now: Date,
                               backups: Backups? = Backups.forEnvironment()) async -> ReconcileSummary? {
        await recheckOutcome(connector: id, days: days, store: store, client: client, now: now, backups: backups).summary
    }

    @MainActor
    public static func recheckOutcome(connector id: String, days: Int, store: Store, client: ConnectorClient, now: Date,
                                      backups: Backups? = Backups.forEnvironment()) async -> RecheckOutcome {
        let component = "connector:\(id)"
        if let backups {
            guard store.takeBackup(backups, reason: "pre-recheck", now: now) != nil else {
                store.activity(component, .error, "Re-check cancelled: the safety backup could not be made",
                               detail: "Nothing was changed and the engine was not asked to re-check.")
                return RecheckOutcome(summary: nil, notice: "Re-check was not started because FloatBoard couldn't make a backup first. Nothing was changed. Details are in Activity.")
            }
        }
        do {
            try await client.recheck(days: days)
        } catch {
            store.activity(component, .error, "Re-check could not be started", detail: "\(error)")
            let why = (error as? ConnectorError)?.description ?? "\(error)"
            return RecheckOutcome(summary: nil, notice: "The engine couldn't start the re-check: \(why) Nothing was changed.")
        }
        var total = ReconcileSummary()
        var drained = false, failure: String?
        for _ in 0..<maxRecheckPasses {
            let more: (processed: Int, done: Bool)
            do { more = try await client.run() } catch {
                store.activity(component, .error, "Re-check: the engine could not run its check", detail: "\(error)")
                failure = (error as? ConnectorError)?.description ?? "\(error)"
                break
            }
            let r = await run(connector: id, store: store, client: client, now: now)
            add(&total, r.applied)
            if let e = r.error { failure = e; break }
            if more.done { drained = true; break }
        }
        let line = recheckLine(total)
        store.activity(component, failure == nil ? .info : .warning, "Re-check of the last \(days) days: \(line)",
                       detail: "added \(total.added), refreshed \(total.refreshed), withdrawn \(total.withdrawn), kept \(total.keptTouched), already there \(total.skippedExisting)")
        var notice = line
        if let failure {
            notice += "\n\nThe re-check stopped early (\(failure)). Whatever arrived was applied; the rest will come with the next syncs."
        } else if !drained {
            notice += "\n\nRe-check is still running on the engine; the rest will arrive with the next syncs."
        }
        return RecheckOutcome(summary: total, notice: notice, stillRunning: !drained && failure == nil, problems: failure != nil)
    }

    /// The status last saved from the engine (plus any local "reconnect" flag).
    @MainActor
    public static func storedStatus(connector id: String, store: Store) -> ConnectorStatus? {
        do {
            let json = try store.db.query("SELECT status_json FROM connectors WHERE id=?", [id]) { DB.text($0, 0) }.first ?? ""
            return try JSONDecoder().decode(ConnectorStatus.self, from: Data(json.utf8))
        } catch {
            return nil // never synced yet (or an empty record): nothing to show
        }
    }

    // MARK: Helpers

    @MainActor
    private static func fail(_ id: String, _ store: Store, _ report: inout SyncReport, _ now: Date, _ message: String,
                             detail: String, level: ActivityLevel = .error, trace: String? = nil) -> SyncReport {
        store.activity("connector:\(id)", level, message, detail: detail, trace: trace)
        if report.error == nil { report.error = message + ": " + detail }
        markUnreachable(id, store, now)
        return report
    }

    @MainActor
    private static func failAuth(_ id: String, _ store: Store, _ report: inout SyncReport, _ now: Date) -> SyncReport {
        store.activity("connector:\(id)", .error, "Reconnect \(id): the engine didn't accept this connection's key",
                       detail: "Nothing was sent. Queued changes are kept and will go out after you reconnect.")
        report.error = authMessage
        var status = storedStatus(connector: id, store: store) ?? ConnectorStatus()
        if !status.needsAttention.contains(authMessage) { status.needsAttention.append(authMessage) }
        do {
            let data = try JSONEncoder().encode(status)
            try store.db.run("UPDATE connectors SET status_json=? WHERE id=?", [String(decoding: data, as: UTF8.self), id])
        } catch {
            store.activity("connector:\(id)", .error, "Could not save the reconnect notice", detail: "\(error)")
        }
        markUnreachable(id, store, now)
        return report
    }

    @MainActor
    private static func markUnreachable(_ id: String, _ store: Store, _ now: Date) {
        do {
            try store.db.run("UPDATE connectors SET unreachable_since=? WHERE id=? AND unreachable_since IS NULL", [now, id])
        } catch {
            store.activity("connector:\(id)", .error, "Could not record that the engine is unreachable", detail: "\(error)")
        }
    }

    private struct Row { var settingsJSON: String, version: Int, engineVersion: Int, cursor: String }

    @MainActor
    private static func connectorRow(_ id: String, _ store: Store) throws -> Row {
        try store.db.query("SELECT settings_json,settings_version,engine_settings_version,cursor FROM connectors WHERE id=?", [id]) { s in
            Row(settingsJSON: DB.text(s, 0), version: Int(DB.int(s, 1)), engineVersion: Int(DB.int(s, 2)), cursor: DB.text(s, 3))
        }.first ?? Row(settingsJSON: "{}", version: 0, engineVersion: 0, cursor: "")
    }

    /// Empty settings read as none. Settings that exist but can't be read throw, so an empty set is never sent to the engine.
    private static func parse(_ json: String, _ connector: String) throws -> [String: Any] {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        do {
            if let d = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { return d }
        } catch {}
        throw ConnectorRecordError.unreadableStored(connector)
    }

    /// The stored settings text last reported as unreadable, per connector (one warning per change).
    @MainActor private static var unreadableSettingsReported: [String: String] = [:]

    /// settings_json minus app-only keys, plus the board's group names and the device's time zone.
    @MainActor
    private static func settingsValues(_ json: String, _ id: String, _ store: Store) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in try parse(json, id) where !appOnlySettings.contains(k) { if let j = JSONValue.from(any: v) { out[k] = j } }
        out["groups"] = .strings(store.areas.map(\.name))
        out["time_zone"] = .string(TimeZone.current.identifier)
        return out
    }

    private static func timeZoneKey(_ id: String) -> String { "pushed_time_zone:\(id)" }

    /// The engine reads due dates in the time zone it was last sent. When the device's zone differs from that one (or
    /// none was sent yet), the settings version is bumped so this sync pushes it.
    @MainActor
    private static func bumpIfTimeZoneChanged(_ id: String, _ store: Store) throws {
        let pushed = try store.db.query("SELECT value FROM meta WHERE key=?", [timeZoneKey(id)]) { DB.text($0, 0) }.first
        guard pushed != TimeZone.current.identifier else { return }
        try store.db.run("UPDATE connectors SET settings_version=engine_settings_version+1 WHERE id=? AND settings_version<=engine_settings_version", [id])
    }

    private static func add(_ a: inout ReconcileSummary, _ b: ReconcileSummary) {
        a.added += b.added; a.refreshed += b.refreshed; a.withdrawn += b.withdrawn; a.keptTouched += b.keptTouched
        a.skippedExisting += b.skippedExisting; a.summaries += b.summaries; a.learnedUpdates += b.learnedUpdates
        a.corrections += b.corrections; a.undatedSkipped += b.undatedSkipped
    }
}
