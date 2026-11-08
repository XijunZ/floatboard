import Foundation
import FloatBoardCore
import FloatBoardConnectors
import SQLite3

// Edge cases in connector sync: lost acks, changes during a send, stale cards, settings pushes, groups, removed connectors.

@MainActor private func val(_ store: Store, _ sql: String, _ args: [Any?] = []) -> String? {
    // try?-ok: check helper; nil reads as missing
    ((try? store.db.query(sql, args) { s -> String? in sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : DB.text(s, 0) }.first) ?? nil) // try?-ok: check helper
}

@MainActor private func settingsOf(_ store: Store, _ id: String) -> [String: Any] {
    let json = val(store, "SELECT settings_json FROM connectors WHERE id=?", [id]) ?? ""
    // try?-ok: check helper; unreadable reads as empty and fails the check
    return ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:] // try?-ok: check helper
}

/// An engine whose transport is async, so a check can act on the board while a request is "on the wire".
private func asyncEngine(_ handler: @escaping (String, String, Data) async throws -> (Int, String)) -> ConnectorClient {
    ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k1") { req in
        let url = req.url!
        let (code, text) = try await handler(req.httpMethod ?? "GET", url.path, req.httpBody ?? Data())
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private func ackAll(_ body: Data) throws -> (Int, String) {
    let events = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["events"] as? [[String: Any]]) ?? []
    let acked = events.compactMap { $0["uuid"] as? String }
    return (200, #"{"acked":\#(String(decoding: try JSONSerialization.data(withJSONObject: acked), as: UTF8.self))}"#)
}

private func uuidsSent(_ eng: FakeEngine) -> [String] {
    eng.bodies("/v2/events").flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String } }
}

@MainActor func connectorEdgeCaseChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-edge-\(UUID().uuidString)")
    func freshStore(_ name: String) -> Store? {
        do { return Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite"))) } catch { check(false, "edge-case store \(name): \(error)"); return nil }
    }
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    guard let f = freshStore("main"), let g = freshStore("groups") else { return }

    // A status whose last_run_ok is a timestamp (what the engine sends) syncs cleanly and is stored.
    do {
        let eng = goodEngine(status: #"{"settings_version":0,"schema":[],"needs_attention":[],"waiting":0,"last_run_ok":"2026-11-07T10:00:00.000Z","last_run_error":null,"oldest_unprocessed_event":null}"#)
        let r = await ConnectorSync.run(connector: "st", store: f, client: eng.client(), now: t)
        check(r.error == nil && ConnectorSync.storedStatus(connector: "st", store: f)?.lastRunOK == "2026-11-07T10:00:00.000Z",
              "status_with_timestamp_last_run_ok_syncs")
    }

    f.performForTest("INSERT INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('ff','ff','{}',1,1)")
    f.reload()
    for m in ["m1", "m2", "m3", "m4"] {
        f.seedCard(title: "Task " + m, area: "Work", importance: .medium, source: "ff", externalID: "ff:" + m)
    }
    func card(_ m: String) -> Card? { f.card(externalID: "ff:" + m) }
    func unsent(_ cardID: Int64) -> Int {
        Int(val(f, "SELECT count(*) FROM outbox WHERE connector='ff' AND sent IS NULL AND payload_json LIKE ?", ["%\"card_id\":\"\(cardID)\"%"]) ?? "") ?? -1
    }

    // The engine stored a change but its answer was lost; a second quick change must be a new event, not merged.
    if let c = card("m1") {
        f.setImportance(c, .high, now: t)
        let lost = goodEngine()
        let good = lost.handler
        lost.handler = { m, p, b in p == "/v2/events" ? (500, "timeout") : try good(m, p, b) }
        _ = await ConnectorSync.run(connector: "ff", store: f, client: lost.client(), now: t.addingTimeInterval(1))
        if let c2 = card("m1") { f.setImportance(c2, .low, now: t.addingTimeInterval(2)) }
        let eng = goodEngine()
        _ = await ConnectorSync.run(connector: "ff", store: f, client: eng.client(), now: t.addingTimeInterval(100))
        let sent = uuidsSent(eng)
        check(Set(sent).count == 2 && sent.first == uuidsSent(lost).first && unsent(c.id) == 0, "outbox_change_after_lost_ack_is_a_new_event")
    }

    // A change made while its pending row is on the wire gets its own row (and is sent next time).
    if let c = card("m2") {
        f.setImportance(c, .high, now: t.addingTimeInterval(200))
        var edited = false
        let client = asyncEngine { _, path, body in
            switch path {
            case "/v2/events":
                if !edited {
                    edited = true
                    await MainActor.run { if let cur = f.card(c.id) { f.setImportance(cur, .low, now: t.addingTimeInterval(201)) } }
                }
                return try ackAll(body)
            case "/v2/proposals": return (200, #"{"items":[],"cursor":null}"#)
            case "/v2/status": return (200, okStatus)
            default: return (200, "{}")
            }
        }
        _ = await ConnectorSync.run(connector: "ff", store: f, client: client, now: t.addingTimeInterval(200))
        check(edited && unsent(c.id) == 1, "outbox_change_during_send_is_not_merged_into_the_row_in_flight")
    }

    // move() decides from the stored row, not the caller's copy.
    if let c = card("m3") {
        f.move(c, to: .done, now: t.addingTimeInterval(300))
        let dones = { Int(val(f, "SELECT count(*) FROM outbox WHERE connector='ff' AND kind='done'") ?? "") ?? -1 }
        let moves = { Int(val(f, "SELECT count(*) FROM events WHERE card_id=? AND kind='moved'", [c.id]) ?? "") ?? -1 }
        let (d0, m0) = (dones(), moves())
        f.move(c, to: .done, now: t.addingTimeInterval(301))   // `c` still says todo
        check(dones() == d0 && moves() == m0, "move_with_stale_todo_card_does_not_finish_twice")
    }
    if var c = card("m4") {
        c.status = .done   // stale: the board says todo
        f.move(c, to: .done, now: t.addingTimeInterval(310))
        check(f.card(c.id)?.status == .done, "move_with_stale_done_card_still_moves")
    }

    // Network back: backed-off rows are tried at once.
    do {
        _ = addOutbox(f, connector: "ff", count: 2, base: t)
        f.performForTest("UPDATE outbox SET next_try=\(t.addingTimeInterval(3600).timeIntervalSince1970), attempts=3 WHERE sent IS NULL")
        let n = f.retryOutboxNow(now: t.addingTimeInterval(400))
        check(n >= 2 && f.oldestUnsentNextTry(connector: "ff").map { $0 <= t.addingTimeInterval(400) } == true
              && f.recentActivity(limit: 20).contains { $0.component == "outbox" && $0.message.contains("sent now") },
              "network_back_clears_outbox_backoff")
    }

    // App-only settings never reach the engine.
    do {
        f.performForTest(#"INSERT INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('ao','ao','{"auto_add":false,"default_group":"Work","my_rules":"R"}',2,1)"#)
        let eng = goodEngine()
        _ = await ConnectorSync.run(connector: "ao", store: f, client: eng.client(), now: t)
        let values = eng.bodies("/v2/settings").first?["values"] as? [String: Any] ?? [:]
        check(values["my_rules"] as? String == "R" && values["auto_add"] == nil && values["default_group"] == nil, "app_only_settings_not_pushed")
    }

    // A learned update from the engine wins over an older unsent settings edit; the push carries the new text.
    do {
        f.performForTest(#"INSERT INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('lf','lf','{"learned":"- OLD","my_rules":"R"}',5,4)"#)
        let eng = goodEngine()
        let base = eng.handler
        eng.handler = { m, p, b in
            if p == "/v2/proposals" {
                return eng.requests.filter({ $0.path == "/v2/proposals" }).count == 1
                    ? (200, #"{"items":[{"id":"ln1","kind":"learned","learned":"- NEW","provenance":{"model":"m","skill_version":"1","created":"2026-11-07T10:00:00Z"}}],"cursor":"c1"}"#)
                    : (200, #"{"items":[],"cursor":"c1"}"#)
            }
            return try base(m, p, b)
        }
        _ = await ConnectorSync.run(connector: "lf", store: f, client: eng.client(), now: t)
        let puts = eng.bodies("/v2/settings")
        let learned = puts.compactMap { ($0["values"] as? [String: Any])?["learned"] as? String }
        check(!learned.isEmpty && learned.allSatisfy { $0 == "- NEW" } && (puts.last?["version"] as? Int ?? 0) > 5
              && settingsOf(f, "lf")["learned"] as? String == "- NEW", "learned_update_is_pushed_not_overwritten_by_older_edit")
    }

    // Engine items from before send dates existed (sent_at null) match by message id; nothing rejected, nothing added.
    do {
        f.seedCard(title: "Old mail", area: "Work", importance: .medium, source: "email", externalID: "email:old@x")
        let before = f.recentActivity(limit: 5000).filter { $0.message.hasPrefix("Proposal rejected") }.count
        let cardsBefore = val(f, "SELECT count(*) FROM cards")
        let prov = #""provenance":{"model":"m","skill_version":"1","created":"2026-10-01T00:00:00Z"}"#
        let page = Data("""
            [{"id":"lp1","kind":"task","source_key":{"message_id":"old@x","sent_at":null},"title":"Other title",\(prov)},
             {"id":"lp2","kind":"task","source_key":{"message_id":"gone@x","sent_at":null},"title":"Gone",\(prov)}]
            """.utf8)
        do {
            let ps = try Reconciler.decodeBatch(page, store: f)
            let sum = try Reconciler.apply(ps, connector: "email", store: f, defaultGroup: "Work", autoAdd: true)
            let after = f.recentActivity(limit: 5000).filter { $0.message.hasPrefix("Proposal rejected") }.count
            check(ps.count == 2 && after == before && sum.added == 0 && val(f, "SELECT count(*) FROM cards") == cardsBefore
                  && f.card(externalID: "email:old@x")?.title == "Old mail"
                  && val(f, "SELECT source_sent FROM cards WHERE external_id='email:old@x'") == nil,
                  "undated_source_key_matches_by_message_id_without_warnings")
        } catch { check(false, "undated_source_key_matches_by_message_id_without_warnings: \(error)") }
    }

    // Group changes reach every connector; rename/delete carry the group's note and default group.
    do {
        g.performForTest(#"INSERT INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('ga','ga','{"group_notes":{"Work":"office things"},"default_group":"Work"}',3,3)"#)
        g.performForTest("INSERT INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('gb','gb','{}',1,1)")
        g.reload()
        let version = { (id: String) in Int(val(g, "SELECT settings_version FROM connectors WHERE id=?", [id]) ?? "") ?? -1 }
        if let work = g.areas.first(where: { $0.name == "Work" }) { g.renameArea(work, to: "Office") }
        let renamed = settingsOf(g, "ga")
        check(version("ga") == 4 && version("gb") == 2 && (renamed["group_notes"] as? [String: String]) == ["Office": "office things"]
              && renamed["default_group"] as? String == "Office", "group_rename_bumps_settings_and_carries_note_and_default")
        let eng = goodEngine(status: #"{"settings_version":3,"schema":[],"needs_attention":[],"waiting":0}"#)
        _ = await ConnectorSync.run(connector: "ga", store: g, client: eng.client(), now: t)
        let pushed = eng.bodies("/v2/settings").first?["values"] as? [String: Any] ?? [:]
        check((pushed["groups"] as? [String])?.contains("Office") == true && (pushed["groups"] as? [String])?.contains("Work") == false,
              "group_rename_is_pushed")
        g.addArea("Side")
        check(version("ga") == 5 && version("gb") == 3, "group_add_bumps_settings")
        if let office = g.areas.first(where: { $0.name == "Office" }) { g.deleteArea(office, moveTasksTo: "Personal") }
        let deleted = settingsOf(g, "ga")
        check(version("ga") == 6 && (deleted["group_notes"] as? [String: String] ?? ["x": "x"]).isEmpty && deleted["default_group"] == nil,
              "group_delete_drops_note_and_resets_default")
        do {
            try g.upsertConnector(id: "gn", name: "GN", baseURL: "https://gn.test")
            let first = goodEngine()
            _ = await ConnectorSync.run(connector: "gn", store: g, client: first.client(), now: t)
            check(version("gn") >= 1 && first.bodies("/v2/settings").count == 1, "new_connector_pushes_settings_on_first_sync")
        } catch { check(false, "new_connector_pushes_settings_on_first_sync: \(error)") }
    }

    // Removing a connector keeps its settings; adding the same id again restores them.
    do {
        g.performForTest(#"INSERT INTO connectors(id,name,base_url,settings_json,settings_version,engine_settings_version) VALUES('ra','RA','https://ra.test','{"my_rules":"R","learned":"- L"}',4,4)"#)
        g.reload()
        try g.removeConnector(id: "ra")
        let gone = val(g, "SELECT count(*) FROM connectors WHERE id='ra'") == "0"
        try g.upsertConnector(id: "ra", name: "RA", baseURL: "https://ra.test")
        let back = settingsOf(g, "ra")
        check(gone && back["my_rules"] as? String == "R" && back["learned"] as? String == "- L"
              && (Int(val(g, "SELECT settings_version FROM connectors WHERE id='ra'") ?? "") ?? 0) > 4
              && g.recentActivity(limit: 50).contains { $0.component == "connector:ra" && $0.message.contains("Restored") },
              "removed_connector_settings_kept_and_restored")
    } catch { check(false, "removed_connector_settings_kept_and_restored: \(error)") }

    // Privacy: settings kept from a removed connector are never restored into a different engine (another person's).
    do {
        g.performForTest(#"INSERT INTO connectors(id,name,base_url,settings_json,settings_version,engine_settings_version) VALUES('rx','RX','https://mine.test','{"my_rules":"MINE","learned":"- private"}',3,3)"#)
        g.reload()
        try g.removeConnector(id: "rx")
        try g.upsertConnector(id: "rx", name: "RX", baseURL: "https://someone-else.test")
        let other = settingsOf(g, "rx")
        let kept = val(g, "SELECT count(*) FROM connector_archive WHERE id='rx' AND restored_at IS NULL") == "1"
        let logged = g.recentActivity(limit: 50).contains { $0.component == "connector:rx" && $0.message.contains("different engine") }
        check(other["my_rules"] == nil && other["learned"] == nil && kept && logged, "archived_settings_not_restored_at_another_engine")
        // Back at the original engine, they are restored.
        try g.removeConnector(id: "rx")
        try g.upsertConnector(id: "rx", name: "RX", baseURL: "https://mine.test/")
        check(settingsOf(g, "rx")["my_rules"] as? String == "MINE", "archived_settings_restored_at_the_same_engine")
    } catch { check(false, "archived_settings_not_restored_at_another_engine: \(error)") }
}
