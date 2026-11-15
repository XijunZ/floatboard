import Foundation
import FloatBoardConnectors
import FloatBoardCore

/// Mac only mode: the engine runs inside the app (JavaScriptCore + a local SQLite file). Claude and Gmail are faked.
@MainActor func localEngineChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-local-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let script: String
    do { script = try LocalEngine.bundledScript() } catch {
        // Built from engine/ with Node (npm run build:mac); without it, Mac only mode is unavailable and not checked.
        print("SKIP local engine checks: \(error)"); return
    }

    final class Seen: @unchecked Sendable { var claude: [[String: Any]] = []; var other: [String] = [] }
    let seen = Seen()
    let claudeAnswer = #"{"action_required":true,"title":"Send Anna the flat contract","why":"Anna asked for it tonight","due":null,"has_time":false,"importance":2,"group":null,"urgent":false}"#
    let transport: LocalEngine.Transport = { req in
        let url = req.url!
        if url.host == "api.anthropic.com" {
            if let b = req.httpBody, let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any] { seen.claude.append(j) } // try?-ok: check helper
            let body: [String: Any] = ["id": "m", "type": "message", "role": "assistant", "model": "claude-haiku-5-5", "stop_reason": "end_turn",
                                       "stop_sequence": NSNull(), "content": [["type": "text", "text": claudeAnswer]],
                                       "usage": ["input_tokens": 1, "output_tokens": 1]]
            return (try JSONSerialization.data(withJSONObject: body),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!)
        }
        seen.other.append(url.absoluteString)
        return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    let engine: LocalEngine
    do {
        engine = try LocalEngine(script: script, databaseURL: root.appendingPathComponent("screening.sqlite"),
                                 secrets: ["ENC_KEY": Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(), "ADMIN_KEY": "adm-local"],
                                 transport: transport)
    } catch { check(false, "local_engine_starts: \(error)"); return }
    check(true, "local_engine_starts")

    func raw(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:]) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: "http://floatboard.local" + path)!)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = Data(body.utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await engine.handle(r)
        return (resp.statusCode, (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]) // try?-ok: check helper
    }

    do {
        let (code, made) = try await raw("POST", "/admin/users", body: #"{"name":"Me"}"#, headers: ["X-Admin-Key": "adm-local"])
        guard code == 200, let key = made["key"] as? String else { check(false, "local_engine_creates_its_user: \(code) \(made)"); return }
        check(true, "local_engine_creates_its_user")

        // The app talks to it exactly as to an online engine.
        let client = ConnectorClient(baseURL: URL(string: "http://floatboard.local")!, key: key) { req in try await engine.handle(req) }
        let status = try await client.status()
        check(status.keys == EngineKeys(claude: false, googleClientID: nil), "local_engine_reports_status")
        let keys = try await client.setKeys(claudeKey: "sk-test-local")
        check(keys.claude, "local_engine_takes_keys")
        let books = try await client.rulebooks()
        check(books.map(\.key) == ["email", "chat"], "local_engine_serves_the_rulebooks")

        // A WhatsApp ask becomes a task, judged by (fake) Claude through the Mac's network.
        let chat = #"{"app":"whatsapp","chats":[{"key":"wa:447700900123@s.whatsapp.net:ABC1","name":"Anna","group":false,"senders":["Anna"],"transcript":"[2026-11-13 09:12] Anna: Can you send me the flat contract by tonight?","link":"whatsapp://send?phone=447700900123","received":"2026-11-13T09:12:00Z"}]}"#
        let (chatCode, stored) = try await raw("POST", "/v2/chats", body: chat, headers: ["Authorization": "Bearer \(key)"])
        check(chatCode == 200 && stored["stored"] as? Int == 1, "local_engine_stores_chats")
        try await engine.idle()
        try await engine.scheduled(cron: "*/5 * * * *", at: Date())
        let page = try await client.proposals(after: nil)
        let task = page.items.first { $0.kind == .task }
        check(task?.title == "Send Anna the flat contract" && seen.claude.count >= 1
              && (seen.claude.first?["model"] as? String ?? "").contains("haiku"),
              "local_engine_turns_a_chat_into_a_task")
        // The key went to Claude as sent: decrypted on this Mac from its own database.
        check(seen.other.isEmpty, "local_engine_calls_nothing_else")
    } catch { check(false, "local_engine: \(error)") }
}

/// Switching between Always on and Mac only, both ways, loses nothing and starts where the other left off. The online
/// engine here is a second copy of the same engine (its own database), reached as https://online.test.
@MainActor func localModeChecks() async {
    guard let script = try? LocalEngine.bundledScript() else { return } // try?-ok: reported by localEngineChecks
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-mode-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "mode setup: \(error)"); return }
    let none: LocalEngine.Transport = { req in (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
    let onlineEngine: LocalEngine
    do {
        onlineEngine = try LocalEngine(script: script, databaseURL: root.appendingPathComponent("online.sqlite"),
                                       secrets: ["ENC_KEY": "online engine encryption key for the checks", "ADMIN_KEY": "adm-on"], transport: none)
    } catch { check(false, "mode online engine: \(error)"); return }
    func raw(_ e: LocalEngine, _ method: String, _ url: String, _ body: String?, _ headers: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = Data(body.utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, _) = try await e.handle(r)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    LocalMode.resetForTesting()
    LocalMode.transportOverride = none
    ConnectorAccounts.testTransport = { req in try await onlineEngine.handle(req) }
    defer { LocalMode.transportOverride = nil; ConnectorAccounts.testTransport = nil; LocalMode.resetForTesting() }
    func inbox(_ state: [String: Any]) -> [String: Any]? { (state["sources"] as? [[String: Any]])?.first { $0["address"] as? String == "me@example.com" } }
    do {
        // The person's online engine, already set up: an inbox read up to "hist-10", one email judged, rules saved.
        let made = try await raw(onlineEngine, "POST", "https://online.test/admin/users", #"{"name":"Me"}"#, ["X-Admin-Key": "adm-on"])
        guard let onKey = made["key"] as? String else { check(false, "mode online user"); return }
        let auth = ["Authorization": "Bearer \(onKey)"]
        _ = try await raw(onlineEngine, "POST", "https://online.test/v2/handover",
                          #"{"sources":[{"kind":"gmail","address":"me@example.com","enabled":true,"cursor":"hist-10","refresh_token":"rt-1","client_id":"cid","client_secret":"cs","fathom_key":null}],"seen":["<old@x>"],"claude_key":"sk-online","apply_enabled":true}"#, auth)
        try ConnectorAccounts.add(id: "email", name: "Email", baseURL: URL(string: "https://online.test")!, key: onKey, store: store)
        try store.saveConnectorSettings(connector: "email", values: ["my_rules": "Invoices are tasks", "alerts_on": true])
        store.reload()
        check(!LocalMode.isSetUp(), "mac_only_not_set_up_before_first_switch")

        // To Mac only: everything arrives, the online inbox pauses.
        try await LocalMode.enable(store: store)
        guard let local = LocalMode.client(store: store),
              let online = ConnectorAccounts.client(for: store.connectors.first { $0.id == "email" }!, store: store) else { check(false, "mode clients"); return }
        var l = try JSONSerialization.jsonObject(with: try await local.handoverState()) as? [String: Any] ?? [:]
        var o = try JSONSerialization.jsonObject(with: try await online.handoverState()) as? [String: Any] ?? [:]
        check(inbox(l)?["enabled"] as? Bool == true && inbox(l)?["cursor"] as? String == "hist-10" && inbox(l)?["refresh_token"] as? String == "rt-1"
              && (l["seen"] as? [String])?.contains("<old@x>") == true && l["claude_key"] as? String == "sk-online",
              "to_mac_only_inbox_access_position_and_judged_move")
        check(inbox(o)?["enabled"] as? Bool == false, "to_mac_only_online_inbox_paused")
        check(store.connectors.first { $0.id == LocalMode.connectorID }?.settings["my_rules"] as? String == "Invoices are tasks",
              "to_mac_only_rules_move")

        // On this Mac: reading moves on, a rule changes; the standby online engine is kept in step but doesn't read.
        _ = try await raw(onlineEngine, "GET", "https://online.test/v2/status", nil, auth) // reachable
        let macKey = try ConnectorAccounts.key(for: LocalMode.connectorID) ?? ""
        var r = URLRequest(url: URL(string: LocalMode.address + "/v2/handover")!); r.httpMethod = "POST"
        r.setValue("Bearer \(macKey)", forHTTPHeaderField: "Authorization")
        r.httpBody = Data(#"{"sources":[{"kind":"gmail","address":"me@example.com","enabled":true,"cursor":"hist-20","refresh_token":"rt-1","client_id":"cid","client_secret":"cs","fathom_key":null}],"seen":["<new@x>"],"apply_enabled":true}"#.utf8)
        _ = try await LocalMode.handle(r)
        try store.saveConnectorSettings(connector: LocalMode.connectorID, values: ["my_rules": "Invoices are tasks\nSchool emails are tasks"])
        store.reload()
        await LocalMode.mirror(store: store)
        store.reload()
        o = try JSONSerialization.jsonObject(with: try await online.handoverState()) as? [String: Any] ?? [:]
        check(inbox(o)?["cursor"] as? String == "hist-20" && inbox(o)?["enabled"] as? Bool == false && (o["seen"] as? [String])?.contains("<new@x>") == true
              && store.connectors.first { $0.id == "email" }?.settings["my_rules"] as? String == "Invoices are tasks\nSchool emails are tasks"
              && store.connectors.first { $0.id == "email" }?.settings["alerts_on"] as? Bool == true,
              "standby_online_kept_in_step_without_reading")

        // Back to Always on: picks up at hist-20, reading again; this Mac's engine on standby.
        try await LocalMode.disable(store: store)
        o = try JSONSerialization.jsonObject(with: try await online.handoverState()) as? [String: Any] ?? [:]
        check(inbox(o)?["enabled"] as? Bool == true && inbox(o)?["cursor"] as? String == "hist-20" && !LocalMode.isOn(store: store) && LocalMode.isSetUp(),
              "back_to_always_on_picks_up_where_the_mac_left_off")
        // Standby the other way: the Mac's engine follows the online one, switched off.
        _ = try await raw(onlineEngine, "POST", "https://online.test/v2/handover",
                          #"{"sources":[{"kind":"gmail","address":"me@example.com","enabled":true,"cursor":"hist-30","refresh_token":"rt-2","client_id":"cid","client_secret":"cs","fathom_key":null}],"seen":[],"apply_enabled":true}"#, auth)
        await LocalMode.mirror(store: store)
        l = try JSONSerialization.jsonObject(with: try await local.handoverState()) as? [String: Any] ?? [:]
        check(inbox(l)?["cursor"] as? String == "hist-30" && inbox(l)?["refresh_token"] as? String == "rt-2" && inbox(l)?["enabled"] as? Bool == false,
              "standby_mac_kept_in_step_without_reading")
        // And to Mac only again: the same engine, from hist-30.
        try await LocalMode.enable(store: store)
        l = try JSONSerialization.jsonObject(with: try await local.handoverState()) as? [String: Any] ?? [:]
        check(LocalMode.isOn(store: store) && inbox(l)?["cursor"] as? String == "hist-30" && inbox(l)?["enabled"] as? Bool == true,
              "mac_only_again_starts_where_always_on_left_off")
    } catch { check(false, "mode switching: \(error)") }
}

/// "On this Mac": judging with Apple's model (faked here) through the engine inside the app, and the comparison.
@MainActor func onDeviceChecks() async {
    guard (try? LocalEngine.bundledScript()) != nil else { return } // try?-ok: reported by localEngineChecks
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-ondevice-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "ondevice setup: \(error)"); return }
    final class Seen: @unchecked Sendable { var device: [String] = []; var claude = 0 }
    let seen = Seen()
    let realModel = ProcessInfo.processInfo.environment["FLOATBOARD_REAL_ONDEVICE"] == "1" // a manual run against Apple's model
    if !realModel { OnDeviceModel.answerOverride = { instructions, prompt in
        seen.device.append(instructions)
        return "```json\n{\"action_required\":true,\"title\":\"Reply to Anna\",\"why\":\"She asked\",\"due\":null,\"has_time\":false,\"importance\":1,\"group\":null,\"urgent\":false}\n```"
    } }
    LocalMode.transportOverride = { req in
        if req.url?.host == "api.anthropic.com" {
            seen.claude += 1
            let text = #"{"action_required":false,"title":"","why":"","due":null,"has_time":false,"importance":1,"group":null,"urgent":false}"#
            let body: [String: Any] = ["id": "m", "type": "message", "role": "assistant", "model": "claude-haiku-5-5", "stop_reason": "end_turn",
                                       "stop_sequence": NSNull(), "content": [["type": "text", "text": text]], "usage": ["input_tokens": 1, "output_tokens": 1]]
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!)
        }
        return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    LocalMode.resetForTesting()
    defer { LocalMode.transportOverride = nil; OnDeviceModel.answerOverride = nil; LocalMode.resetForTesting() }
    do {
        try Keys.setClaude("sk-od", store: store)
        try await LocalMode.enable(store: store)
        guard let info = store.connectors.first(where: { $0.id == LocalMode.connectorID }),
              let client = ConnectorAccounts.client(for: info, store: store) else { check(false, "ondevice client"); return }
        _ = await Keys.push(connector: info.id, store: store, client: client)
        let st = try await client.status()
        check(st.schema.first { $0.key == "model_judge" }?.options?.contains("On this Mac") == true, "on_this_mac_offered_in_mac_only_mode")
        try await client.putSettings(values: ["model_judge": .string("On this Mac")], version: 50)
        let chat = #"{"app":"whatsapp","chats":[{"key":"wa:447700900999@s.whatsapp.net:OD1","name":"Anna","group":false,"senders":["Anna"],"transcript":"[2026-11-13 09:12] Anna: Can you call me back?","link":"","received":"2026-11-13T09:12:00Z"}]}"#
        var r = URLRequest(url: URL(string: LocalMode.address + "/v2/chats")!)
        r.httpMethod = "POST"; r.httpBody = Data(chat.utf8)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(try ConnectorAccounts.key(for: info.id) ?? "")", forHTTPHeaderField: "Authorization")
        _ = try await LocalMode.handle(r)
        await LocalMode.tick(store: store)
        let page = try await client.proposals(after: nil)
        if realModel {
            // Apple's model: its answers must be usable (whether it calls something a task is what Compare measures).
            let c0 = try await client.compareModels(limit: 5)
            print("REAL on-device: proposals \(page.items.count), compare n=\(c0.n) agree=\(c0.agree) unusable=\(c0.unusable ?? -1)")
            check(c0.unusable == 0 && seen.claude == 1, "on_this_mac_real_model_answers_are_usable")
            return
        }
        check(page.items.contains { $0.title == "Reply to Anna" } && seen.device.first?.contains("JSON schema") == true && seen.claude == 0,
              "on_this_mac_judges_without_claude")
        let c = try await client.compareModels(limit: 5)
        check(c.n == 1 && c.agree == 0 && seen.claude == 1, "comparison_runs_both_and_counts_agreement: n=\(c.n) agree=\(c.agree) claude=\(seen.claude) \(c.note ?? "")")
    } catch { check(false, "on_this_mac: \(error)") }
}
