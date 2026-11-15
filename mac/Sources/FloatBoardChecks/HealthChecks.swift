import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// The health watchdog (silence is a failure too) and safe diagnostics.
@MainActor func healthChecks() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-health-\(UUID().uuidString)")
    let dbURL = root.appendingPathComponent("health.sqlite")
    let store: Store
    do { store = Store(db: try DB(url: dbURL)) } catch { check(false, "health setup: \(error)"); return }
    let n = Date()
    let iso = ISO8601DateFormatter()
    func ago(_ s: TimeInterval) -> Date { n.addingTimeInterval(-s) }
    let h = 3600.0

    func reset() {
        for t in ["outbox", "connectors", "activity", "corrections"] { store.performForTest("DELETE FROM \(t)") }
        store.performForTest("DELETE FROM meta")
    }
    func status(runOK: Date?? = .some(nil), attention: [String] = [], oldest: Date? = nil) -> String {
        let ok: String = (runOK ?? nil).map { "\"\(iso.string(from: $0))\"" } ?? "null"
        let old: String = oldest.map { "\"\(iso.string(from: $0))\"" } ?? "null"
        let a = String(decoding: (try? JSONSerialization.data(withJSONObject: attention)) ?? Data("[]".utf8), as: UTF8.self) // try?-ok: check helper
        return #"{"settings_version":0,"schema":[],"needs_attention":\#(a),"waiting":0,"last_run_ok":\#(ok),"last_run_error":null,"oldest_unprocessed_event":\#(old)}"#
    }
    /// A healthy connector (synced a minute ago, connected for 10 h, engine ran a minute ago) with overrides.
    func connector(_ id: String = "h1", url: String = "https://h1.example/path", unreachable: Date? = nil, statusJSON: String? = nil,
                   connectedSince: Date? = nil) {
        store.performForTest {
            try store.db.run("INSERT OR REPLACE INTO connectors(id,name,base_url,settings_json,status_json,last_ok,unreachable_since) VALUES(?,?,?,?,?,?,?)",
                             [id, id.uppercased(), url, "{}", statusJSON ?? status(runOK: .some(ago(60))), ago(60), unreachable])
            try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                             ["connected_since:\(id)", String((connectedSince ?? ago(10 * h)).timeIntervalSince1970)])
        }
    }
    func outbox(_ uuid: String, _ id: String = "h1", created: Date, payload: String = #"{"verdict":"done"}"#) {
        store.performForTest {
            try store.db.run("INSERT INTO outbox(uuid,connector,kind,payload_json,created,attempts,next_try) VALUES(?,?,?,?,?,0,?)",
                             [uuid, id, "done", payload, created, created])
        }
    }
    func ids(_ backups: Backups? = nil) -> [String] { Health.evaluate(store: store, backups: backups, now: n).map(\.id).sorted() }
    func warnings(_ text: String = "") -> [ActivityEntry] {
        store.recentActivity(limit: 1000).filter { $0.component == "health" && $0.level == .warning && (text.isEmpty || $0.message.contains(text)) }
    }

    // health_flags_each_silent_condition
    do {
        reset(); connector()
        let healthy = ids()
        reset(); connector(unreachable: ago(2 * h))
        let unreachable = ids()
        reset(); connector(unreachable: ago(0.5 * h))
        let briefly = ids()
        reset(); connector(); outbox("w1", created: ago(2 * h)); outbox("w2", created: ago(10))
        let waiting = ids()
        reset(); connector(); outbox("w3", created: ago(0.5 * h))
        let waitingFresh = ids()
        reset(); connector(statusJSON: status(runOK: .some(ago(3 * h))))
        let stalled = ids()
        reset(); connector(statusJSON: status(runOK: .some(nil)), connectedSince: ago(3 * h))
        let stalledMissing = ids()
        reset(); connector(statusJSON: status(runOK: .some(nil)), connectedSince: ago(1 * h))
        let missingButNew = ids()
        reset(); connector(statusJSON: status(runOK: .some(ago(60)), attention: ["Reconnect your inbox", "Calendar blocked"]))
        let attention = ids()
        // backups: real snapshots only; a 0-byte file with a backup-style name must not count
        let bk = root.appendingPathComponent("bk")
        let backups = Backups(dbURL: dbURL, dir: bk)
        reset(); connector()
        do { try backups.snapshot(reason: "daily", now: ago(40 * h)) } catch { check(false, "snapshot: \(error)") }
        let backupOld = ids(backups)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        fm.createFile(atPath: bk.appendingPathComponent("board-\(f.string(from: ago(0.5 * h)))-daily.sqlite").path, contents: Data())
        let backupGarbage = ids(backups)
        do { try backups.snapshot(reason: "manual", now: ago(1 * h)) } catch { check(false, "snapshot: \(error)") }
        let backupFresh = ids(backups)
        let backupOff = ids(nil)
        // errors
        reset(); connector()
        store.performForTest {
            try store.db.run("INSERT INTO activity(at,component,level,message,seen) VALUES(?,?,?,?,0)", [ago(1 * h), "x", "error", "boom"])
        }
        let errors = ids()
        store.markActivitySeen(upTo: n)
        let errorsSeen = ids()
        reset(); connector()
        store.performForTest { try store.db.run("INSERT INTO activity(at,component,level,message,seen) VALUES(?,?,?,?,0)", [ago(25 * h), "x", "error", "old"]) }
        let errorsOld = ids()
        let attentionIDs = attention.filter { $0.hasPrefix("attention:h1:") }
        check(healthy == [] && unreachable == ["unreachable:h1"] && briefly == [], "health_unreachable_over_an_hour")
        check(waiting == ["waiting:h1"] && waitingFresh == [], "health_oldest_waiting_change_over_an_hour")
        check(stalled == ["engine-stalled:h1"] && stalledMissing == ["engine-stalled:h1"] && missingButNew == [], "health_engine_stalled_by_last_run_ok")
        check(attentionIDs.count == 2 && attention.count == 2 && Set(attentionIDs).count == 2, "health_one_problem_per_attention_line")
        check(backupOld == ["backup"] && backupGarbage == ["backup"] && backupFresh == [] && backupOff == [], "health_backup_older_than_36_hours")
        check(errors == ["errors"] && errorsSeen == [] && errorsOld == [], "health_unseen_errors_last_24_hours")
    }

    // oldest_unprocessed_event_not_used_for_staleness
    do {
        reset(); connector(statusJSON: status(runOK: .some(ago(60)), oldest: ago(30 * h)))
        check(ids().isEmpty, "oldest_unprocessed_event_not_used_for_staleness")
    }

    // health_problem_logged_once_and_cleared
    do {
        reset(); connector(unreachable: ago(2 * h))
        let a = Health.refresh(store: store, backups: nil, now: n)
        _ = Health.refresh(store: store, backups: nil, now: n.addingTimeInterval(60))
        let once = warnings().count == 1
        // Relaunch: a second Store on the same file must not repeat the warning.
        var relaunched: Store?
        do { relaunched = Store(db: try DB(url: dbURL)) } catch { check(false, "relaunch: \(error)") }
        if let r = relaunched { _ = Health.refresh(store: r, backups: nil, now: n.addingTimeInterval(120)) }
        let afterRelaunch = warnings().count
        store.performForTest("UPDATE connectors SET unreachable_since=NULL")
        let cleared = Health.refresh(store: store, backups: nil, now: n.addingTimeInterval(180))
        _ = Health.refresh(store: store, backups: nil, now: n.addingTimeInterval(240))
        let infos = store.recentActivity(limit: 1000).filter { $0.component == "health" && $0.level == .info }
        store.performForTest("UPDATE connectors SET unreachable_since=\(n.timeIntervalSince1970 - 2 * h)")
        _ = Health.refresh(store: store, backups: nil, now: n.addingTimeInterval(300))
        check(a.map(\.id) == ["unreachable:h1"] && once && afterRelaunch == 1 && cleared.isEmpty && infos.count == 1
              && warnings().count == 2, "health_problem_logged_once_and_cleared")
    }

    // unreadable_outbox_row_detached
    do {
        reset(); connector()
        outbox("bad", created: ago(2 * h), payload: "garbage {")
        outbox("good", created: ago(10))
        let pending = store.pendingOutbox(connector: "h1", limit: 10, now: n.addingTimeInterval(1)).map(\.uuid)
        _ = store.pendingOutbox(connector: "h1", limit: 10, now: n.addingTimeInterval(2))
        let reason = (try? store.db.query("SELECT detached, detach_reason, payload_json FROM outbox WHERE uuid='bad'") { (DB.int($0, 0), DB.text($0, 1), DB.text($0, 2)) })?.first // try?-ok: check helper
        let logged = store.recentActivity(limit: 100).filter { $0.trace == "bad" && $0.level == .warning }
        check(pending == ["good"] && store.waitingCount(connector: "h1") == 1 && reason?.0 == 1 && reason?.1 == "unreadable"
              && reason?.2 == "garbage {" && logged.count == 1 && ids().isEmpty, "unreadable_outbox_row_detached")
    }

    // trace_follows_correction_end_to_end
    do {
        reset()
        store.performForTest("INSERT INTO connectors(id,name,base_url,settings_json) VALUES('tr','Tr','https://tr.example','{}')")
        store.seedCard(title: "Trace me", area: "Personal", importance: .low, source: "tr", externalID: "tr:1")
        store.performForTest("UPDATE cards SET connector='tr', source_mid='trm', source_sent='s' WHERE external_id='tr:1'")
        store.reload()
        if let c = store.cards.first(where: { $0.title == "Trace me" }) {
            store.move(c, to: .done)
            let uuid = (try? store.db.query("SELECT uuid FROM outbox WHERE connector='tr'") { DB.text($0, 0) })?.first ?? "none" // try?-ok: check helper
            let eng = goodEngine()
            var acked: [String] = []
            let g = eng.handler
            eng.handler = { m, p, b in
                let r = try g(m, p, b)
                if p == "/v2/events" { acked += ((try JSONSerialization.jsonObject(with: Data(r.1.utf8)) as? [String: Any])?["acked"] as? [String]) ?? [] }
                return r
            }
            _ = await ConnectorSync.run(connector: "tr", store: store, client: eng.client(), now: n.addingTimeInterval(60))
            let sentIDs = eng.bodies("/v2/events").flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String } }
            let rows = store.trace(uuid)
            check(uuid != "none" && rows.contains { $0.component == "outbox" } && rows.contains { $0.component == "connector:tr" }
                  && sentIDs == [uuid] && acked == [uuid], "trace_follows_correction_end_to_end")
        } else { check(false, "trace setup") }
    }

    // diagnostics_contain_no_secrets_or_titles
    do {
        reset()
        let secretKey = "sk-test-NOTAREALKEY-0123456789abcdef"
        let title = "Wire Anna the deposit"
        connector("dg", url: "https://user:hunter2@dg.example/v2/path?token=abc123", statusJSON: status(runOK: .some(ago(60)), attention: ["Reply needed: \"\(title)\""]))
        do { try Credentials.set(secretKey, "connector:dg") } catch { check(false, "diag creds: \(error)") }
        store.seedCard(title: title, area: "Personal", importance: .low, source: "dg", externalID: "dg:1")
        store.activity("connector:dg", .warning, "Could not file a card", detail: "GET https://user:hunter2@dg.example/v2/path?token=abc123 failed; Authorization: Bearer \(secretKey)")
        store.activity("checks", .info, "long", detail: String(repeating: "x", count: 1000))
        for i in 0..<250 { store.activity("checks", .info, "filler \(i)") }
        let json = Diagnostics.json(store: store, backups: nil, appVersion: "9.9.9", now: n)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] // try?-ok: check helper
        let rows = parsed?["activity"] as? [[String: Any]] ?? []
        let maxDetail = rows.compactMap { ($0["detail"] as? String)?.count }.max() ?? 0
        let conns = parsed?["connectors"] as? [[String: Any]] ?? []
        let leaks = ["SECRETKEY", "hunter2", "/v2/path", "abc123", title, "Wire Anna"].filter { json.contains($0) }
        check(leaks.isEmpty && json.contains("dg.example") && rows.count == 200 && maxDetail <= 301
              && parsed?["app_version"] as? String == "9.9.9" && parsed?["schema_version"] as? Int == DB.schemaVersion
              && conns.first?["host"] as? String == "dg.example" && (conns.first?["needs_attention"] as? [String])?.count == 1,
              "diagnostics_contain_no_secrets_or_titles")
    }
    await healthEdgeCaseChecks(store: store, root: root, dbURL: dbURL)
    try? fm.removeItem(at: root) // try?-ok: scratch cleanup
}

/// More health cases: verified backups, silent never-syncing, unreadable status, redaction, stable ids, dismiss, fresh install.
@MainActor func healthEdgeCaseChecks(store: Store, root: URL, dbURL: URL) async {
    let fm = FileManager.default
    let n = Date()
    let iso = ISO8601DateFormatter()
    let h = 3600.0
    func ago(_ s: TimeInterval) -> Date { n.addingTimeInterval(-s) }
    func reset() {
        for t in ["outbox", "connectors", "activity", "corrections", "cards", "meta"] { store.performForTest("DELETE FROM \(t)") }
    }
    func status(_ attention: [String] = []) -> String {
        let a = String(decoding: (try? JSONSerialization.data(withJSONObject: attention)) ?? Data("[]".utf8), as: UTF8.self) // try?-ok: check helper
        return #"{"settings_version":0,"schema":[],"needs_attention":\#(a),"waiting":0,"last_run_ok":"\#(iso.string(from: ago(60)))","last_run_error":null,"oldest_unprocessed_event":null}"#
    }
    func conn(_ id: String = "f1", statusJSON: String? = nil, lastOK: Date? = nil, added: Date? = nil, connected: Date? = nil) {
        store.performForTest {
            try store.db.run("INSERT OR REPLACE INTO connectors(id,name,base_url,settings_json,status_json,last_ok) VALUES(?,?,?,?,?,?)",
                             [id, id.uppercased(), "https://f.example", "{}", statusJSON ?? status(), lastOK])
            if let added { try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["connector_added:\(id)", String(added.timeIntervalSince1970)]) }
            if let connected { try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["connected_since:\(id)", String(connected.timeIntervalSince1970)]) }
        }
    }
    func run(_ sql: String, _ args: [Any?]) { store.performForTest { try store.db.run(sql, args) } }
    func ids(_ b: Backups? = nil) -> [String] { Health.evaluate(store: store, backups: b, now: n).map(\.id).sorted() }
    func meta(_ k: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", [k]) { DB.text($0, 0) })?.first // try?-ok: check helper
    }

    // never_syncing_connector_flagged (1 h after it was added, no successful sync)
    do {
        reset(); conn(statusJSON: "{}", lastOK: nil, added: ago(2 * h))
        let old = ids()
        reset(); conn(statusJSON: "{}", lastOK: nil, added: ago(0.5 * h))
        let young = ids()
        reset(); conn(statusJSON: "{}", lastOK: nil)   // legacy row without a record of when it was added
        _ = Health.refresh(store: store, backups: nil, now: n)
        let backfilled = meta("connector_added:f1") != nil
        check(old == ["never-synced:f1"] && young == [] && backfilled, "never_syncing_connector_flagged")
    }
    // connected_since backfilled from last_ok
    do {
        reset(); conn(statusJSON: "{}", lastOK: ago(5 * h))
        _ = Health.refresh(store: store, backups: nil, now: n)
        let v = meta("connected_since:f1").flatMap { Double($0) }
        check(v != nil && abs((v ?? 0) - ago(5 * h).timeIntervalSince1970) < 1, "connected_since_backfilled_from_last_ok")
    }
    // unreadable status
    do {
        reset(); conn(statusJSON: "not json {", lastOK: ago(60), added: ago(10 * h))
        _ = Health.refresh(store: store, backups: nil, now: n)
        _ = Health.refresh(store: store, backups: nil, now: n.addingTimeInterval(60))
        let logged = store.recentActivity(limit: 100).filter { $0.component == "health" && $0.level == .warning }.count
        check(ids() == ["status-unreadable:f1"] && logged == 1, "unreadable_status_is_a_problem_logged_once")
    }
    // attention ids stable across counts and times; redaction; dismiss
    do {
        reset(); conn(statusJSON: status(["3 emails waiting since 10:41"]), lastOK: ago(60), added: ago(10 * h))
        let a = ids()
        run("UPDATE connectors SET status_json=?", [status(["5 emails waiting since 11:02"])])
        let b = ids()
        run("UPDATE connectors SET status_json=?", [status(["Calendar is blocked"])])
        let c = ids()
        check(a.count == 1 && a == b && a != c, "attention_id_stable_across_counts_and_times")

        reset(); conn(statusJSON: status(["Can't read mail from anna@example.com about \"Wire the deposit\""]), lastOK: ago(60), added: ago(10 * h))
        _ = Health.refresh(store: store, backups: nil, now: n)
        let text = store.recentActivity(limit: 50).filter { $0.component == "health" }.map { $0.message + " " + ($0.detail ?? "") }.joined(separator: "\n")
            + Health.evaluate(store: store, backups: nil, now: n).map(\.message).joined()
        check(!text.contains("anna@") && !text.contains("Wire the deposit") && text.contains("<email>"), "health_attention_text_redacted")

        reset(); conn(statusJSON: status(["3 emails waiting since 10:41"]), lastOK: ago(60), added: ago(10 * h))
        let shown = Health.refresh(store: store, backups: nil, now: n)
        Health.acknowledge(shown[0].id, store: store)
        _ = Health.refresh(store: store, backups: nil, now: n)
        let hidden = store.healthProblems.isEmpty
        run("UPDATE connectors SET status_json=?", [status(["7 emails waiting since 12:00"])])
        _ = Health.refresh(store: store, backups: nil, now: n)
        let stillHidden = store.healthProblems.isEmpty
        run("UPDATE connectors SET status_json=?", [status(["A different problem"])])
        _ = Health.refresh(store: store, backups: nil, now: n)
        check(shown.count == 1 && hidden && stillHidden && store.healthProblems.count == 1, "dismissed_problem_stays_hidden_until_text_changes")
    }
    // fresh install: no "no backup" problem until 36 h after first launch
    do {
        let bk = root.appendingPathComponent("bk-fresh")
        let backups = Backups(dbURL: dbURL, dir: bk)
        reset(); conn(lastOK: ago(60), added: ago(10 * h))
        run("INSERT INTO meta(key,value) VALUES('first_launch_at',?)", [String(ago(1 * h).timeIntervalSince1970)])
        let fresh = ids(backups)
        run("UPDATE meta SET value=? WHERE key='first_launch_at'", [String(ago(40 * h).timeIntervalSince1970)])
        let old = ids(backups)
        check(fresh == [] && old == ["backup"], "fresh_install_no_backup_problem_for_36_hours")
    }
    // no card titles in Activity written by reconciling or editing
    do {
        reset()
        let first = #"{"items":[{"id":"pa","kind":"task","source_key":{"message_id":"ma","sent_at":"2026-11-01T10:00:00Z"},"title":"Wire Anna the deposit","provenance":{"model":"m","skill_version":"1","created":"2026-11-01"}}],"cursor":"c1"}"#
        let second = #"{"items":[{"id":"pb","kind":"task","source_key":{"message_id":"ma","sent_at":"2026-11-01T10:00:00Z"},"title":"Wire Anna the bigger deposit","provenance":{"model":"m","skill_version":"1","created":"2026-11-02"}}],"cursor":"c2"}"#
        let eng = goodEngine()
        let g = eng.handler
        eng.handler = { m, p, b in
            guard p == "/v2/proposals" else { return try g(m, p, b) }
            let q = eng.requests.last?.query ?? ""
            if q.contains("after=c2") { return (200, #"{"items":[],"cursor":"c2"}"#) }
            if q.contains("after=c1") { return (200, eng.requests.filter { $0.path == "/v2/proposals" }.count > 2 ? second : #"{"items":[],"cursor":"c1"}"#) }
            return (200, first)
        }
        store.performForTest("INSERT INTO connectors(id,name,base_url,settings_json) VALUES('rt','Rt','https://rt.example','{}')")
        _ = await ConnectorSync.run(connector: "rt", store: store, client: eng.client(), now: n)
        _ = await ConnectorSync.run(connector: "rt", store: store, client: eng.client(), now: n.addingTimeInterval(10))
        // edit the card's title as the user: the queued change must not put titles in Activity
        store.reload()
        if let c = store.cards.first(where: { $0.connector == "rt" }) { var e = c; e.title = "Totally different words"; store.update(e) }
        let all = store.recentActivity(limit: 1000).map { $0.message + " " + ($0.detail ?? "") }.joined(separator: "\n")
        let have = store.cards.contains { $0.connector == "rt" }
        check(have && !all.contains("Wire Anna") && !all.contains("Totally different"), "activity_has_no_card_titles")
    }
    // diagnostics: addresses and quoted text redacted, trace uuids survive
    do {
        reset()
        conn("dg2", statusJSON: status(["Can't read mail from anna@example.com about \"Wire the deposit\""]), lastOK: ago(60), added: ago(10 * h))
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        store.activity("checks", .info, "Delivered to anna@example.com", detail: "see \(uuid)", trace: uuid)
        let json = Diagnostics.json(store: store, backups: nil, appVersion: "1", now: n)
        check(!json.contains("anna@") && !json.contains("Wire the deposit") && json.contains("<email>") && json.contains(uuid),
              "diagnostics_redact_addresses_and_keep_traces")
    }
}
