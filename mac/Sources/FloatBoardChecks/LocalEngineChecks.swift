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

/// Switching to Mac only and back: "This Mac" appears as an engine the app syncs with like any other, and goes away.
@MainActor func localModeChecks() async {
    guard (try? LocalEngine.bundledScript()) != nil else { return } // try?-ok: reported by localEngineChecks
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-mode-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "mode setup: \(error)"); return }
    LocalMode.resetForTesting()
    LocalMode.transportOverride = { req in (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
    defer { LocalMode.transportOverride = nil; LocalMode.resetForTesting() }
    do {
        try Keys.setClaude("sk-mode", store: store)
        try await LocalMode.enable(store: store)
        let info = store.connectors.first { $0.id == LocalMode.connectorID }
        check(info?.name == "This Mac" && LocalMode.isOn(store: store) && Keys.pending(connector: LocalMode.connectorID, store: store).contains(.claude),
              "mac_only_adds_this_mac_and_queues_keys")
        guard let info, let client = ConnectorAccounts.client(for: info, store: store) else { check(false, "mac_only_client"); return }
        _ = await Keys.push(connector: LocalMode.connectorID, store: store, client: client)
        let st = try await client.status()
        check(st.keys?.claude == true, "mac_only_engine_gets_the_claude_key")
        let r = await ConnectorSync.run(connector: LocalMode.connectorID, store: store, client: client, now: Date())
        store.reload()
        check(r.error == nil && store.connectors.first { $0.id == LocalMode.connectorID }?.lastOK != nil, "mac_only_engine_syncs_like_an_online_one: \(r)")
        await LocalMode.tick(store: store)
        check(!store.recentActivity(limit: 50).contains { $0.message.hasPrefix("The engine on this Mac hit a problem") }, "mac_only_schedule_runs")
        try await LocalMode.disable(store: store)
        check(!LocalMode.isOn(store: store), "always_on_removes_this_mac")
        // Back again: the same user (key kept), nothing to recreate.
        try await LocalMode.enable(store: store)
        check(LocalMode.isOn(store: store), "mac_only_again_reuses_its_engine")
    } catch { check(false, "mac_only: \(error)") }
}
