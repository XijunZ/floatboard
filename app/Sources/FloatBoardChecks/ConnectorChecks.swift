import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// A scripted engine: every request goes through `handler` and is recorded.
final class FakeEngine {
    var requests: [(method: String, path: String, query: String, body: Data)] = []
    var handler: (String, String, Data) throws -> (Int, String)
    init(_ h: @escaping (String, String, Data) throws -> (Int, String)) { handler = h }
    func client() -> ConnectorClient {
        ConnectorClient(baseURL: URL(string: "https://engine.test")!, key: "k1") { [self] req in
            let method = req.httpMethod ?? "GET"
            let url = req.url!
            let body = req.httpBody ?? Data()
            requests.append((method, url.path, url.query ?? "", body))
            guard req.value(forHTTPHeaderField: "Authorization") == "Bearer k1" else { throw URLError(.userAuthenticationRequired) }
            let (code, text) = try handler(method, url.path, body)
            return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
    func bodies(_ path: String) -> [[String: Any]] {
        requests.filter { $0.path == path }.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] } // try?-ok: check helper
    }
}

let okStatus = #"{"settings_version":0,"schema":[],"needs_attention":[],"waiting":0,"last_run_ok":null,"last_run_error":null,"oldest_unprocessed_event":null}"#

/// Default well-behaved engine: acks everything, empty proposals, quiet status.
func goodEngine(status: String = okStatus) -> FakeEngine {
    FakeEngine { method, path, body in
        switch path {
        case "/v2/events":
            let events = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["events"] as? [[String: Any]]) ?? []
            let acked = events.compactMap { $0["uuid"] as? String }
            return (200, #"{"acked":\#(try String(decoding: JSONSerialization.data(withJSONObject: acked), as: UTF8.self))}"#)
        case "/v2/proposals": return (200, #"{"items":[],"cursor":null}"#)
        case "/v2/status": return (200, status)
        case "/v2/settings": return (200, "{}")
        case "/v2/drafts/run": return (200, #"{"processed":0,"waiting":0}"#)
        default: return (404, "{}")
        }
    }
}

@MainActor func addOutbox(_ store: Store, connector: String, count: Int, base: Date, extra: [String: String] = [:]) -> [String] {
    var ids: [String] = []
    for i in 0..<count {
        let id = "\(connector)-\(String(format: "%03d", i))"
        var p = ["source_mid": "m\(i)", "source_sent": "s", "item_id": "", "verdict": "done", "detail": "", "at": "1"]
        for (k, v) in extra { p[k] = v }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])) ?? Data(), as: UTF8.self) // try?-ok: check helper
        do {
            try store.db.run("INSERT INTO outbox(uuid,connector,kind,payload_json,created,attempts,next_try) VALUES(?,?,?,?,?,0,?)",
                             [id, connector, "done", json, base.addingTimeInterval(Double(i)), base])
        } catch { check(false, "addOutbox: \(error)") }
        ids.append(id)
    }
    return ids
}

@MainActor func connectorRow(_ store: Store, _ id: String, _ col: String) -> String? {
    // try?-ok: check helper; nil reads as missing
    (try? store.db.query("SELECT \(col) FROM connectors WHERE id=?", [id]) { s -> String? in // try?-ok: test helper
        DB.text(s, 0) }.first) ?? nil
}

@MainActor func connectorActivity(_ store: Store, _ id: String) -> [ActivityEntry] {
    store.recentActivity(limit: 5000).filter { $0.component == "connector:\(id)" }
}

@MainActor func sentCount(_ store: Store, _ id: String) -> Int {
    // try?-ok: check helper
    Int((try? store.db.query("SELECT count(*) FROM outbox WHERE connector=? AND sent IS NOT NULL", [id]) { DB.int($0, 0) }.first) ?? -1) // try?-ok: test helper
}

@MainActor func connectorChecks(_ store: Store) async {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Outbox drains in order, across a failing batch.
    do {
        let ids = addOutbox(store, connector: "ob", count: 120, base: t0, extra: ["card_id": "7", "last_at": "5", "from_area": "X"])
        var eventCalls = 0
        let eng = goodEngine()
        let good = eng.handler
        eng.handler = { m, p, b in
            if p == "/v2/events" { eventCalls += 1; if eventCalls == 2 { return (500, #"{"error":"boom"}"#) } }
            return try good(m, p, b)
        }
        let r1 = await ConnectorSync.run(connector: "ob", store: store, client: eng.client(), now: t0)
        check(r1.sent == 50 && r1.failed == 50 && r1.error != nil, "outbox_first_run_sends_batch_1_then_fails_batch_2")
        check(sentCount(store, "ob") == 50 && store.waitingCount(connector: "ob") == 70, "outbox_batches_2_3_still_pending")
        check(eventCalls == 2, "outbox_stops_sending_after_failure")
        let first = eng.bodies("/v2/events")[0]["events"] as? [[String: Any]] ?? []
        let keys = Set((first.first?["payload"] as? [String: Any])?.keys.map { $0 } ?? [])
        check(keys == ["source_mid", "source_sent", "item_id", "verdict", "detail", "at"], "outbox_internal_payload_keys_stripped")
        let callsBefore = eventCalls
        let early = await ConnectorSync.run(connector: "ob", store: store, client: eng.client(), now: t0.addingTimeInterval(10))
        check(early.sent == 0 && eventCalls == callsBefore && store.waitingCount(connector: "ob") == 70, "backoff_blocks_newer_rows_within_window")
        let r2 = await ConnectorSync.run(connector: "ob", store: store, client: eng.client(), now: t0.addingTimeInterval(120))
        check(r2.sent == 70 && r2.error == nil && store.waitingCount(connector: "ob") == 0, "outbox_next_run_sends_rest")
        let sentOrder = eng.bodies("/v2/events").flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String } }
        // events seen by the engine: batch 1, failed batch 2 (rows 50-99), then the retry of 50-119
        let delivered = sentOrder.enumerated().filter { $0.offset < 50 || $0.offset >= 100 }.map(\.element)
        check(delivered == ids, "outbox_order_preserved")
    }

    // A failing events POST stops sending only: proposals and status still happen.
    do {
        _ = addOutbox(store, connector: "co", count: 2, base: t0)
        let page = #"{"items":[{"id":"pc1","kind":"task","source_key":{"message_id":"co1","sent_at":"2026-11-01T10:00:00Z"},"title":"Call back","provenance":{"model":"m","skill_version":"1","created":"2026-11-01"}}],"cursor":"cc2"}"#
        let eng = goodEngine(status: #"{"settings_version":0,"schema":[{"key":"k","label":"K","kind":"text"}],"needs_attention":[],"waiting":0}"#)
        let g = eng.handler
        eng.handler = { m, p, b in
            if p == "/v2/events" { return (500, "down") }
            if p == "/v2/proposals" { return (200, eng.requests.last?.query.contains("after=cc2") == true ? #"{"items":[],"cursor":"cc2"}"# : page) }
            return try g(m, p, b)
        }
        let r = await ConnectorSync.run(connector: "co", store: store, client: eng.client(), now: t0)
        let logs = connectorActivity(store, "co")
        check(r.error != nil && r.applied.added == 1 && connectorRow(store, "co", "cursor") == "cc2"
              && ConnectorSync.storedStatus(connector: "co", store: store)?.schema.first?.key == "k", "failed_send_still_applies_proposals_and_status")
        check(logs.filter { $0.level != .info }.count == 1 && store.recentActivity(limit: 5000).filter { $0.component == "outbox" && $0.trace?.hasPrefix("co-") == true }.isEmpty,
              "failed_batch_logs_one_row_not_per_event")
    }

    // Cursor only moves after the local commit.
    do {
        let page = #"{"items":[{"id":"p1","kind":"task","source_key":{"message_id":"cm1","sent_at":"2026-11-01T10:00:00Z"},"title":"Pay invoice","provenance":{"model":"m","skill_version":"1","created":"2026-11-01"}}],"cursor":"c2"}"#
        let eng = goodEngine()
        let good = eng.handler
        eng.handler = { m, p, b in
            if p == "/v2/proposals" { return (200, eng.requests.last?.query.contains("after=c2") == true ? #"{"items":[],"cursor":"c2"}"# : page) }
            return try good(m, p, b)
        }
        store.performForTest("CREATE TRIGGER ck_block BEFORE INSERT ON cards BEGIN SELECT RAISE(ABORT, 'boom'); END")
        let r1 = await ConnectorSync.run(connector: "cu", store: store, client: eng.client(), now: t0)
        let cur1 = connectorRow(store, "cu", "cursor") ?? ""
        check(r1.error != nil && cur1.isEmpty && store.card(externalID: "x") == nil, "cursor_unchanged_when_apply_fails")
        store.performForTest("DROP TRIGGER ck_block")
        let r2 = await ConnectorSync.run(connector: "cu", store: store, client: eng.client(), now: t0.addingTimeInterval(10))
        check(r2.error == nil && r2.applied.added == 1 && connectorRow(store, "cu", "cursor") == "c2", "cursor_saved_after_commit")
        check(eng.requests.contains { $0.path == "/v2/proposals" && $0.query.contains("after=c2") }, "cursor_sent_on_next_page_request")
    }

    // Engine behind: settings pushed again, minus app-only keys, plus groups.
    do {
        store.performForTest("INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('eb','eb','{\"default_group\":\"Work\",\"auto_add\":true,\"learned\":\"L\",\"vip\":[\"a\",\"b\"]}',3,1)")
        let eng = goodEngine(status: #"{"settings_version":2,"schema":[{"key":"vip","label":"VIPs","kind":"list"}],"needs_attention":["x"],"waiting":0,"last_run_ok":null,"last_run_error":null,"oldest_unprocessed_event":null}"#)
        let r1 = await ConnectorSync.run(connector: "eb", store: store, client: eng.client(), now: t0)
        let put = eng.bodies("/v2/settings").first
        let values = put?["values"] as? [String: Any]
        check(r1.error == nil && put?["version"] as? Int == 3 && values?["default_group"] == nil && values?["auto_add"] == nil && values?["learned"] as? String == "L"
              && (values?["groups"] as? [String]) == store.areas.map(\.name) && values?["vip"] as? [String] == ["a", "b"],
              "settings_pushed_without_app_only_keys_with_groups")
        check(values?["time_zone"] as? String == TimeZone.current.identifier, "settings_push_includes_device_time_zone")
        let st = ConnectorSync.storedStatus(connector: "eb", store: store)
        check(st?.schema.first?.key == "vip" && st?.needsAttention == ["x"], "status_saved_in_connector_row")
        check(connectorRow(store, "eb", "engine_settings_version") == "2", "engine_version_taken_from_status")
        _ = await ConnectorSync.run(connector: "eb", store: store, client: eng.client(), now: t0.addingTimeInterval(5))
        check(eng.bodies("/v2/settings").count == 2, "engine_behind_gets_settings_again")
        // stale push: 409
        let stale = goodEngine()
        let sg = stale.handler
        stale.handler = { m, p, b in p == "/v2/settings" ? (409, #"{"error":"stale","settings_version":7}"#) : try sg(m, p, b) }
        store.performForTest("UPDATE connectors SET settings_version=3, engine_settings_version=1 WHERE id='eb'")
        let r3 = await ConnectorSync.run(connector: "eb", store: store, client: stale.client(), now: t0.addingTimeInterval(10))
        check(connectorRow(store, "eb", "settings_version") == "8", "stale_409_bumps_local_version_past_engine")
        check(r3.error == nil, "stale_409_is_not_a_failed_run")
        check(stale.bodies("/v2/settings").count == 2 && stale.bodies("/v2/settings")[1]["version"] as? Int == 8, "stale_409_repushes_once_in_same_run")
        let unreadable = goodEngine()
        let ug = unreadable.handler
        unreadable.handler = { m, p, b in p == "/v2/settings" ? (409, "stale") : try ug(m, p, b) }
        store.performForTest("UPDATE connectors SET settings_version=3, engine_settings_version=1 WHERE id='eb'")
        let r4 = await ConnectorSync.run(connector: "eb", store: store, client: unreadable.client(), now: t0.addingTimeInterval(20))
        check(connectorRow(store, "eb", "settings_version") == "3" && r4.error != nil && unreadable.bodies("/v2/settings").count == 1,
              "stale_409_without_version_is_logged_not_bumped")
    }

    // Device time zone: a zone different from the one last pushed bumps the version and is pushed; the same zone is not.
    do {
        let zone = TimeZone.current.identifier
        store.performForTest("INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('tz','tz','{}',4,4)")
        store.performForTest("INSERT OR REPLACE INTO meta(key,value) VALUES('pushed_time_zone:tz','\(zone)')")
        let same = goodEngine(status: #"{"settings_version":4,"schema":[],"needs_attention":[],"waiting":0,"last_run_ok":null,"last_run_error":null,"oldest_unprocessed_event":null}"#)
        _ = await ConnectorSync.run(connector: "tz", store: store, client: same.client(), now: t0)
        check(same.bodies("/v2/settings").isEmpty && connectorRow(store, "tz", "settings_version") == "4", "same_time_zone_is_not_pushed_again")
        store.performForTest("UPDATE meta SET value='Pacific/Chatham' WHERE key='pushed_time_zone:tz'")
        let moved = goodEngine(status: #"{"settings_version":5,"schema":[],"needs_attention":[],"waiting":0,"last_run_ok":null,"last_run_error":null,"oldest_unprocessed_event":null}"#)
        _ = await ConnectorSync.run(connector: "tz", store: store, client: moved.client(), now: t0.addingTimeInterval(5))
        let put = moved.bodies("/v2/settings").first
        check(put?["version"] as? Int == 5 && (put?["values"] as? [String: Any])?["time_zone"] as? String == zone, "changed_time_zone_bumps_version_and_is_pushed")
        let saved = (try? store.db.query("SELECT value FROM meta WHERE key='pushed_time_zone:tz'") { DB.text($0, 0) }.first) ?? nil // try?-ok: check helper
        check(saved == zone, "pushed_time_zone_remembered")
    }

    // Unreachable bookkeeping.
    do {
        let down = FakeEngine { _, _, _ in throw URLError(.notConnectedToInternet) }
        _ = await ConnectorSync.run(connector: "un", store: store, client: down.client(), now: t0)
        let since = Double(connectorRow(store, "un", "unreachable_since") ?? "")
        _ = await ConnectorSync.run(connector: "un", store: store, client: down.client(), now: t0.addingTimeInterval(60))
        check(since == t0.timeIntervalSince1970 && Double(connectorRow(store, "un", "unreachable_since") ?? "") == since,
              "unreachable_since_set_once")
        let r = await ConnectorSync.run(connector: "un", store: store, client: goodEngine().client(), now: t0.addingTimeInterval(120))
        check(r.error == nil && (connectorRow(store, "un", "unreachable_since") ?? "").isEmpty
              && Double(connectorRow(store, "un", "last_ok") ?? "") == t0.addingTimeInterval(120).timeIntervalSince1970,
              "unreachable_since_cleared_on_success")
    }

    // Each failing call writes exactly one Activity row under connector:<id>.
    do {
        var results: [Bool] = []
        for failing in ["/v2/events", "/v2/proposals", "/v2/status", "/v2/settings"] {
            let id = "fl" + failing.dropFirst(4)
            _ = addOutbox(store, connector: id, count: 2, base: t0)
            store.performForTest("INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('\(id)','\(id)','{}',2,1)")
            let eng = goodEngine()
            let g = eng.handler
            eng.handler = { m, p, b in p == failing ? (500, "nope") : try g(m, p, b) }
            _ = await ConnectorSync.run(connector: id, store: store, client: eng.client(), now: t0)
            results.append(connectorActivity(store, id).filter { $0.level != .info }.count == 1)
        }
        check(results == [true, true, true, true], "every_failure_logged")
    }

    // 401: nothing sent, reconnect message, queue intact.
    do {
        let ids = addOutbox(store, connector: "au", count: 3, base: t0)
        let eng = goodEngine()
        eng.handler = { _, _, _ in (401, #"{"error":"bad key"}"#) }
        let r = await ConnectorSync.run(connector: "au", store: store, client: eng.client(), now: t0)
        let st = ConnectorSync.storedStatus(connector: "au", store: store)
        let rows = connectorActivity(store, "au")
        check(r.sent == 0 && sentCount(store, "au") == 0 && store.pendingOutbox(connector: "au", limit: 10, now: t0).map(\.uuid) == ids,
              "auth_error_keeps_queue")
        check(st?.needsAttention.contains("The engine didn't accept this connection's key.") == true
              && rows.count == 1 && rows[0].level == .error && rows[0].message.hasPrefix("Reconnect"), "auth_error_asks_to_reconnect")
        check(eng.requests.count == 1, "auth_error_stops_the_run")
    }
}
