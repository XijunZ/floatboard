import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// No silent failures. Every failure here must throw or write an Activity row, never vanish.
@MainActor func silentFailureChecks(_ store: Store) {
    func rows(_ component: String? = nil, level: ActivityLevel? = nil, containing text: String = "") -> [ActivityEntry] {
        store.recentActivity(limit: 1000).filter {
            (component == nil || $0.component == component) && (level == nil || $0.level == level)
                && (text.isEmpty || $0.message.contains(text) || ($0.detail ?? "").contains(text))
        }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fb-silent-\(UUID().uuidString)")
    // try?-ok: test helper
    try? fm.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: test helper
    let savedCreds = ProcessInfo.processInfo.environment[LocalData.credentialsEnv]
    func pointCreds(at path: String?) {
        if let path { setenv(LocalData.credentialsEnv, path, 1) } else if let savedCreds { setenv(LocalData.credentialsEnv, savedCreds, 1) } else { unsetenv(LocalData.credentialsEnv) }
        Credentials.resetCacheForTesting()
    }

    // credentials_write_failure_throws_and_logs
    do {
        let ro = root.appendingPathComponent("ro")
        try fm.createDirectory(at: ro, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        pointCreds(at: ro.appendingPathComponent("sub/creds.json").path)
        var thrown: Error?
        do { try Credentials.logging("save a secret", store: store) { try Credentials.set("s3cret-value-123", "k") } } catch { thrown = error }
        var isUnwritable = false
        if let e = thrown as? CredentialsError, case .unwritable = e { isUnwritable = true }
        let logged = rows("credentials", level: .error, containing: "save a secret")
        let leaked = store.recentActivity(limit: 1000).contains { ($0.detail ?? "").contains("s3cret-value-123") || $0.message.contains("s3cret-value-123") }
        check(isUnwritable && logged.count == 1 && !leaked, "credentials_write_failure_throws_and_logs")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path)
    } catch { check(false, "credentials_write_failure_throws_and_logs: \(error)") }

    // credentials_unreadable_differs_from_missing
    do {
        let file = root.appendingPathComponent("c2.json")
        pointCreds(at: file.path)
        let missing: String?? = try? Credentials.get("k") // try?-ok: test helper
        try Data("this is not json".utf8).write(to: file)
        Credentials.resetCacheForTesting()
        var unreadable = false
        do { _ = try Credentials.get("k") } catch CredentialsError.unreadable { unreadable = true } catch {}
        var setRefused = false
        do { try Credentials.set("v", "k") } catch CredentialsError.unreadable { setRefused = true } catch {}
        let stillCorrupt = (try? String(contentsOf: file, encoding: .utf8)) == "this is not json" // try?-ok: test helper
        check(missing == .some(nil) && unreadable && setRefused && stillCorrupt, "credentials_unreadable_differs_from_missing")
        var deleteLogged = false
        do { try Credentials.logging("remove a secret", store: store) { try Credentials.delete("k") } } catch { deleteLogged = !rows("credentials", containing: "remove a secret").isEmpty }
        check(deleteLogged, "credentials_unreadable_delete_logged")
    } catch { check(false, "credentials_unreadable_differs_from_missing: \(error)") }
    pointCreds(at: nil)

    // bar_config_broken_kept_and_logged
    do {
        struct Cfg: Codable { var a: Int }
        let d = UserDefaults(suiteName: "fb-silent-bar")!
        d.removePersistentDomain(forName: "fb-silent-bar")
        let bad = Data("{not a config".utf8)
        d.set(bad, forKey: "barConfig")
        let first = store.loadJSONSetting(Cfg.self, defaults: d, key: "barConfig", brokenKey: "barConfig.broken", what: "bar settings")
        let second = store.loadJSONSetting(Cfg.self, defaults: d, key: "barConfig", brokenKey: "barConfig.broken", what: "bar settings")
        d.set(try JSONEncoder().encode(Cfg(a: 7)), forKey: "barConfig")
        let good = store.loadJSONSetting(Cfg.self, defaults: d, key: "barConfig", brokenKey: "barConfig.broken", what: "bar settings")
        check(first == nil && second == nil && good?.a == 7 && d.data(forKey: "barConfig.broken") == bad
              && rows("settings", level: .warning, containing: "bar settings").count == 1, "bar_config_broken_kept_and_logged")
        // A second, different broken blob must not overwrite the first; at most 3 copies are kept.
        let bad2 = Data("{second".utf8)
        d.set(bad2, forKey: "barConfig")
        _ = store.loadJSONSetting(Cfg.self, defaults: d, key: "barConfig", brokenKey: "barConfig.broken", what: "bar settings")
        let keptSecond = d.dictionaryRepresentation().contains { $0.key.hasPrefix("barConfig.broken.") && ($0.value as? Data) == bad2 }
        for i in 3...6 {
            d.set(Data("{bad\(i)".utf8), forKey: "barConfig")
            _ = store.loadJSONSetting(Cfg.self, defaults: d, key: "barConfig", brokenKey: "barConfig.broken", what: "bar settings")
        }
        let copies = d.dictionaryRepresentation().filter { $0.key.hasPrefix("barConfig.broken") }
        check(d.data(forKey: "barConfig.broken") == bad && keptSecond && copies.count == 3,
              "bar_config_later_broken_does_not_overwrite_earlier")
        d.removePersistentDomain(forName: "fb-silent-bar")
    } catch { check(false, "bar_config_broken_kept_and_logged: \(error)") }

    // store_reload_error_logged
    do {
        store.performForTest("ALTER TABLE areas RENAME TO areas_x")
        defer { if (try? store.db.query("SELECT 1 FROM sqlite_master WHERE name='areas_x'") { DB.int($0, 0) }.first) != nil { // try?-ok: test helper
            store.performForTest("ALTER TABLE areas_x RENAME TO areas"); store.reload() } }
        store.reload()
        let n = rows("store", level: .error, containing: "Could not read the board").count
        store.performForTest("ALTER TABLE areas_x RENAME TO areas")
        store.reload()
        check(n >= 1, "store_reload_error_logged")
    }

    // backup_rotation_reports_every_failure
    do {
        let dir = root.appendingPathComponent("bkrot")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["board-20200101-000000-daily.sqlite", "board-20200102-000000-daily.sqlite", "board-20200103-000000-daily.sqlite"]
        for n in names { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let b = Backups(dbURL: store.db.url, dir: dir)
        var message = ""
        do { try b.rotate() } catch { message = "\(error)" }
        store.dailyBackup(b)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let row = rows("backup", level: .warning, containing: "rotation").first
        check(names.allSatisfy { message.contains($0) } && (row?.detail ?? "").contains(names[2]) && (row?.detail ?? "").contains(names[0]),
              "backup_rotation_reports_every_failure")
    } catch { check(false, "backup_rotation_reports_every_failure: \(error)") }

    // backup_cleanup_failure_is_reported
    do {
        let dir = root.appendingPathComponent("bkclean")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = Backups(dbURL: root.appendingPathComponent("nope.sqlite"), dir: dir)
        store.takeBackup(b, reason: "probe")
        check(rows("backup", level: .error, containing: "probe").count == 1, "backup_failure_logged")
        check(Backups.removeReporting(dir.appendingPathComponent("does-not-exist.sqlite")) == nil, "backup_remove_missing_file_is_success")
        let locked = root.appendingPathComponent("bklocked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let victim = locked.appendingPathComponent("v.sqlite")
        try Data("x".utf8).write(to: victim)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let failure = Backups.removeReporting(victim)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        check(failure != nil, "backup_remove_reports_failure")
    } catch { check(false, "backup_cleanup: \(error)") }

    // outbox_note_reflects_reason
    do {
        check(Store.detachedNote(reason: "no_connector") == "Change kept — it will be sent once the connector is set up"
              && Store.detachedNote(reason: "removed") == "Change kept but not sent — connector removed", "outbox_note_texts")
        let c = store.seedCard(title: "NoConn", area: "Personal", importance: .low, source: "nc", externalID: "nc:1")
        store.performForTest("UPDATE cards SET connector='ghost', source_mid='m', source_sent='s' WHERE external_id='nc:1'")
        store.reload()
        let noConnBefore = rows("outbox", containing: "once the connector is set up").count
        let removedBefore = rows("outbox", containing: "connector removed").count
        if c, let card = store.cards.first(where: { $0.title == "NoConn" }) {
            store.move(card, to: .done)
            let a = rows("outbox", containing: "once the connector is set up").count - noConnBefore
            store.performForTest("INSERT OR REPLACE INTO meta(key,value) VALUES('user_removed:ghost','1')")
            if let again = store.cards.first(where: { $0.title == "NoConn" }) { store.deleteCard(again, verdict: nil) }
            let r = rows("outbox", containing: "connector removed").count - removedBefore
            check(a == 1 && r == 1, "outbox_note_reflects_reason")
        } else { check(false, "outbox_note_reflects_reason: setup") }
    }

    // connector_non_https_logged_once_host_only
    do {
        store.performForTest("INSERT INTO connectors(id,name,base_url,settings_json) VALUES('plain','Plain','http://secret-host.example/path?token=abc123','{}')")
        store.reload()
        if let info = store.connectors.first(where: { $0.id == "plain" }) {
            _ = ConnectorAccounts.client(for: info, store: store)
            _ = ConnectorAccounts.client(for: info, store: store)
            let r = rows("connector:plain", level: .error)
            let leaked = store.recentActivity(limit: 1000).contains { ($0.detail ?? "").contains("abc123") || $0.message.contains("abc123") }
            check(r.count == 1 && r[0].detail == "secret-host.example" && !leaked, "connector_non_https_logged_once_host_only")
        } else { check(false, "connector_non_https_logged_once_host_only: setup") }
    }
    try? fm.removeItem(at: root) // try?-ok: test helper
}

/// Bad stored data degrades loudly but never blocks or loses other data.
@MainActor func badStoredDataChecks(_ store: Store) async {
    func rows(_ component: String, containing text: String, level: ActivityLevel? = nil) -> [ActivityEntry] {
        store.recentActivity(limit: 2000).filter { $0.component == component && (level == nil || $0.level == level)
            && ($0.message.contains(text) || ($0.detail ?? "").contains(text)) }
    }
    func scalar(_ sql: String, _ args: [Any?] = []) -> String? {
        ((try? store.db.query(sql, args) { DB.text($0, 0) }.first) ?? nil) // try?-ok: test helper
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // corrupt_settings_do_not_block_proposals
    do {
        store.performForTest("INSERT INTO connectors(id,name,base_url,settings_json) VALUES('cs','Cs','https://engine.test','not json {')")
        let page = #"{"items":[{"id":"cs1","kind":"task","source_key":{"message_id":"csm1","sent_at":"2026-11-01T10:00:00Z"},"title":"Corrupt settings task","provenance":{"model":"m","skill_version":"1","created":"2026-11-01"}},{"id":"cs2","kind":"learned","learned":"- keep going","provenance":{"model":"m","skill_version":"1","created":"2026-11-01"}}],"cursor":"cs-c2"}"#
        let eng = goodEngine()
        let good = eng.handler
        eng.handler = { m, p, b in
            if p == "/v2/proposals" { return (200, eng.requests.last?.query.contains("after=cs-c2") == true ? #"{"items":[],"cursor":"cs-c2"}"# : page) }
            return try good(m, p, b)
        }
        let r1 = await ConnectorSync.run(connector: "cs", store: store, client: eng.client(), now: t0)
        let r2 = await ConnectorSync.run(connector: "cs", store: store, client: eng.client(), now: t0.addingTimeInterval(600))
        let warnings = rows("connector:cs", containing: "saved settings can't be read", level: .warning)
        check(r1.applied.added == 1 && store.card(externalID: "cs:csm1") != nil && scalar("SELECT cursor FROM connectors WHERE id='cs'") == "cs-c2"
              && warnings.count == 1 && r2.applied.added == 0
              && scalar("SELECT settings_json FROM connectors WHERE id='cs'") == "not json {"
              && rows("connector:cs", containing: "Learned update skipped").count + rows("reconciler", containing: "Learned update skipped").count >= 1,
              "corrupt_settings_do_not_block_proposals")
    }

    // outbox_item_id_survives_non_string_meta + unreadable meta logged once
    do {
        store.performForTest("INSERT INTO connectors(id,name,base_url,settings_json) VALUES('oc','Oc','https://oc.example','{}')")
        store.seedCard(title: "MixedMeta", area: "Personal", importance: .low, source: "oc", externalID: "oc:1")
        store.seedCard(title: "BadMeta", area: "Personal", importance: .low, source: "oc", externalID: "oc:2")
        store.performForTest("UPDATE cards SET connector='oc', source_mid='mx', source_sent='s', source_meta='{\"itemId\":\"it9\",\"n\":5}' WHERE external_id='oc:1'")
        store.performForTest("UPDATE cards SET connector='oc', source_mid='my', source_sent='s', source_meta='garbage' WHERE external_id='oc:2'")
        store.reload()
        if let c1 = store.cards.first(where: { $0.title == "MixedMeta" }), let c2 = store.cards.first(where: { $0.title == "BadMeta" }) {
            store.move(c1, to: .done)
            store.setImportance(c2, .high)
            if let again = store.cards.first(where: { $0.title == "BadMeta" }) { store.setImportance(again, .medium) }
            let payload = scalar("SELECT payload_json FROM outbox WHERE connector='oc' AND kind='done'") ?? ""
            check(payload.contains("\"item_id\":\"it9\""), "outbox_item_id_survives_non_string_meta")
            check(rows("outbox", containing: "details can't be read", level: .warning).count == 1, "outbox_unreadable_meta_logged_once_per_card")
        } else { check(false, "outbox meta setup") }
    }

    // outbox_unreadable_pending_payload_left_untouched
    do {
        store.seedCard(title: "PendingBad", area: "Personal", importance: .low, source: "oc", externalID: "oc:3")
        store.performForTest("UPDATE cards SET connector='oc', source_mid='mz', source_sent='s' WHERE external_id='oc:3'")
        store.reload()
    }
    do {
        let now = Date()
        store.performForTest { try store.db.run("INSERT OR REPLACE INTO outbox(uuid,connector,kind,payload_json,created,attempts,next_try) VALUES('badpend','oc','changed','garbage {',?,0,?)", [now, now]) }
        if let c = store.cards.first(where: { $0.title == "PendingBad" }) {
            store.setImportance(c, .high)
            check(scalar("SELECT payload_json FROM outbox WHERE uuid='badpend'") == "garbage {"
                  && scalar("SELECT count(*) FROM outbox WHERE connector='oc' AND kind='changed' AND uuid<>'badpend' AND payload_json LIKE '%mz%'") == "1"
                  && rows("outbox", containing: "pending change", level: .warning).count >= 1, "outbox_unreadable_pending_payload_left_untouched")
        } else { check(false, "outbox pending setup") }
    }

    // reconciler_unreadable_meta_logged
    do {
        let prov = Provenance(model: "m", skillVersion: "1", created: "2026-11-07T10:00:00Z")
        func prop(_ title: String) -> Proposal {
            Proposal(id: "rm-" + title, kind: .task, sourceKey: SourceKey(messageID: "rmm1", sentAt: "2026-11-07T10:00:00Z"), title: title,
                     why: "w", due: nil, hasTime: false, group: nil, importance: 1, sourceLabel: "x", link: "", summary: nil,
                     taskRef: nil, learned: nil, provenance: prov)
        }
        try Reconciler.apply([prop("First")], connector: "oc", store: store, defaultGroup: "Personal", autoAdd: true)
        store.performForTest("UPDATE cards SET source_meta='garbage' WHERE external_id='oc:rmm1'")
        try Reconciler.apply([prop("Second")], connector: "oc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(rows("reconciler", containing: "details can't be read", level: .warning).count >= 1
              && (scalar("SELECT source_meta FROM cards WHERE external_id='oc:rmm1'") ?? "").contains("garbage"), "reconciler_unreadable_meta_logged_and_kept")
    } catch { check(false, "reconciler_unreadable_meta_logged_and_kept: \(error)") }
}
