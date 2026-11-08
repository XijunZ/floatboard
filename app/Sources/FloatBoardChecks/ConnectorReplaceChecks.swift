import FloatBoardConnectors
import FloatBoardCore
import Foundation
import SQLite3

/// Replacing and removing connectors safely, settings that are never silently lost,
/// and the engine's /v2/status example decoding as the app's ConnectorStatus.
@MainActor func connectorReplaceChecks(_ store: Store) {
    func one<T>(_ sql: String, _ args: [Any?] = [], _ read: @escaping (OpaquePointer) -> T) -> T? {
        // try?-ok: a failed query makes the check fail
        (try? store.db.query(sql, args) { read($0) })?.first // try?-ok: test helper
    }
    func outboxCount(_ id: String) -> Int { Int(one("SELECT count(*) FROM outbox WHERE connector=?", [id]) { DB.int($0, 0) } ?? -1) }
    func activityHas(_ text: String) -> Bool { store.recentActivity(limit: 200).contains { $0.message.contains(text) } }
    func key(_ id: String) -> String? { (try? ConnectorAccounts.key(for: id)) ?? "unreadable" } // try?-ok: unreadable fails the check

    // replace_connector_resets_sync_state
    do {
        try ConnectorAccounts.add(id: "rp", name: "Rp", baseURL: URL(string: "https://a.example")!, key: "k1", store: store)
        try store.db.run("""
            UPDATE connectors SET cursor='c9', engine_settings_version=7, status_json='{"settings_version":7}', last_ok=?,
                   settings_json='{"learned":"- mornings"}', settings_version=7 WHERE id='rp'
            """, [Date()])
        try ConnectorAccounts.add(id: "rp", name: "Rp", baseURL: URL(string: "https://b.example")!, key: "k2", store: store)
        let r = one("SELECT cursor, engine_settings_version, status_json, last_ok IS NULL, settings_json, base_url FROM connectors WHERE id='rp'") {
            (DB.text($0, 0), DB.int($0, 1), DB.text($0, 2), DB.int($0, 3), DB.text($0, 4), DB.text($0, 5))
        }
        check(r?.0 == "" && r?.1 == 0 && r?.2 == "{}" && r?.3 == 1 && r?.4.contains("mornings") == true
              && r?.5 == "https://b.example" && key("rp") == "k2", "replace_connector_resets_sync_state")
        try store.db.run("UPDATE connectors SET cursor='c10' WHERE id='rp'")
        try ConnectorAccounts.add(id: "rp", name: "Rp", baseURL: URL(string: "https://b.example/")!, key: "k3", store: store)
        check(one("SELECT cursor FROM connectors WHERE id='rp'") { DB.text($0, 0) } == "c10" && key("rp") == "k3",
              "same_address_keeps_sync_state")
    } catch { check(false, "replace_connector_resets_sync_state: \(error)") }
    check(ConnectorInfo.sameAddress("https://a.example", "https://a.example/") && !ConnectorInfo.sameAddress("https://a.example", "https://a.example:8443")
          && !ConnectorInfo.sameAddress("http://localhost:8787", "https://localhost:8787")
          && !ConnectorInfo.sameAddress("https://a.example", "https://b.example") && ConnectorInfo.sameAddress("https://A.example", "https://a.example"),
          "connector_address_compares_scheme_host_port")

    // replace_key_not_saved_when_row_update_fails: the new key must never sit next to the old address
    do {
        try ConnectorAccounts.add(id: "rk", name: "Rk", baseURL: URL(string: "https://old.example")!, key: "old-key", store: store)
        try store.db.run("CREATE TEMP TRIGGER rk_fail BEFORE UPDATE ON connectors WHEN NEW.id='rk' BEGIN SELECT RAISE(ABORT, 'boom'); END")
        var threw = false
        do { try ConnectorAccounts.add(id: "rk", name: "Rk", baseURL: URL(string: "https://new.example")!, key: "new-key", store: store) }
        catch { threw = true }
        try store.db.run("DROP TRIGGER rk_fail")
        let url = one("SELECT base_url FROM connectors WHERE id='rk'") { DB.text($0, 0) }
        check(threw && url == "https://old.example" && key("rk") != "new-key", "replace_key_not_saved_when_row_update_fails")
    } catch { check(false, "replace_key_not_saved_when_row_update_fails: \(error)") }

    // connect_link_name_sanitized
    let tricky = URL(string: "floatboard://connect?url=https://evil.example&key=k&name=Email%20at%20engine.mine.com%0AOK%20%E2%80%94%20safe%20to%20join%20this%20is%20a%20long%20name")
        .flatMap(ConnectLink.parse)
    check(tricky.map { n in !n.name.contains("\n") && !n.name.contains(".") && n.name.count <= 40 && n.name.hasPrefix("Email at engine") } ?? false,
          "connect_link_name_sanitized")

    // remove_connector_detaches_outbox
    do {
        try ConnectorAccounts.add(id: "dt", name: "Dt", baseURL: URL(string: "https://dt.example")!, key: "k", store: store)
        try store.saveConnectorSettings(connector: "dt", values: ["x": 1])
        try store.saveConnectorSettings(connector: "dt", values: ["x": 2])
        let before = store.waitingCount(connector: "dt")
        try ConnectorAccounts.remove(id: "dt", store: store)
        try ConnectorAccounts.add(id: "dt", name: "Dt", baseURL: URL(string: "https://other.example")!, key: "k", store: store)
        let detached = Int(one("SELECT count(*) FROM outbox WHERE connector='dt' AND detached=1 AND sent IS NULL") { DB.int($0, 0) } ?? -1)
        check(before == 2 && store.waitingCount(connector: "dt") == 0 && store.pendingOutbox(connector: "dt", limit: 50, now: Date().addingTimeInterval(9e6)).isEmpty
              && store.oldestUnsentNextTry(connector: "dt") == nil && detached == 2 && outboxCount("dt") == 2
              && activityHas("2 unsent changes kept but not sent — connector removed"), "remove_connector_detaches_outbox")
    } catch { check(false, "remove_connector_detaches_outbox: \(error)") }

    // leftover_card_changes_detached: edits/deletes of a removed connector's cards are kept but never sent
    do {
        try ConnectorAccounts.add(id: "lf", name: "Lf", baseURL: URL(string: "https://lf1.example")!, key: "k", store: store)
        let prov = Provenance(model: "m", skillVersion: "1", created: "2026-11-07T10:00:00Z")
        try Reconciler.apply(["lf-m1", "lf-m2"].map { mid in
            Proposal(id: "p-" + mid, kind: .task, sourceKey: SourceKey(messageID: mid, sentAt: "2026-11-07T10:00:00Z"), title: "Left " + mid,
                     why: "", due: nil, hasTime: false, group: nil, importance: 1, sourceLabel: "x", link: "", summary: nil,
                     taskRef: nil, learned: nil, provenance: prov) }, connector: "lf", store: store,
            defaultGroup: store.areas.first?.name ?? "Personal", autoAdd: true)
        try ConnectorAccounts.remove(id: "lf", store: store)
        let left = store.cards.filter { $0.connector == "lf" }
        if left.count == 2 {
            store.setImportance(left[0], .high)
            store.deleteCard(left[1], verdict: "not_action")
        }
        try ConnectorAccounts.add(id: "lf", name: "Lf", baseURL: URL(string: "https://lf2.example")!, key: "k", store: store)
        let detached = Int(one("SELECT count(*) FROM outbox WHERE connector='lf' AND detached=1 AND sent IS NULL") { DB.int($0, 0) } ?? -1)
        let corrections = Int(one("SELECT count(*) FROM corrections WHERE connector='lf'") { DB.int($0, 0) } ?? -1)
        // try?-ok: a failed query fails the check
        let uuids = Set((try? store.db.query("SELECT uuid FROM outbox WHERE connector='lf'") { DB.text($0, 0) }) ?? []) // try?-ok: test helper
        let notes = store.recentActivity(limit: 300).filter { $0.message == "Change kept but not sent — connector removed" && uuids.contains($0.trace ?? "") }.count
        check(left.count == 2 && store.waitingCount(connector: "lf") == 0 && detached == 2 && corrections == 2 && notes == 2
              && store.card(left[0].id)?.importance == .high, "leftover_card_changes_detached")
    } catch { check(false, "leftover_card_changes_detached: \(error)") }

    // settings_save_refuses_unreadable_stored
    do {
        try ConnectorAccounts.add(id: "ur", name: "Ur", baseURL: URL(string: "https://ur.example")!, key: "k", store: store)
        try store.db.run("UPDATE connectors SET settings_json='not json {', settings_version=3 WHERE id='ur'")
        var threw = false
        do { try store.saveConnectorSettings(connector: "ur", values: ["vip": ["a"]]) } catch { threw = true }
        let row = one("SELECT settings_json, settings_version FROM connectors WHERE id='ur'") { (DB.text($0, 0), DB.int($0, 1)) }
        check(threw && row?.0 == "not json {" && row?.1 == 3 && outboxCount("ur") == 0
              && store.recentActivity(limit: 50).contains { $0.level == .error && $0.detail?.contains("not json {") == true },
              "settings_save_refuses_unreadable_stored")
    } catch { check(false, "settings_save_refuses_unreadable_stored: \(error)") }

    // settings_save_needs_existing_connector
    var ghostThrew = false
    do { try store.saveConnectorSettings(connector: "ghost", values: ["a": 1]) } catch { ghostThrew = true }
    check(ghostThrew && one("SELECT count(*) FROM connectors WHERE id='ghost'") { DB.int($0, 0) } == 0 && outboxCount("ghost") == 0
          && store.recentActivity(limit: 20).contains { $0.level == .warning && $0.component == "connector:ghost" },
          "settings_save_needs_existing_connector")

    // v2_status_fixture_decodes (the engine's /v2/status example, kept in app/Tests/Fixtures)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/v2-status.example.json")
    var schema: [SettingField] = []
    do {
        let st = try JSONDecoder().decode(ConnectorStatus.self, from: Data(contentsOf: fixture))
        schema = st.schema
        let kinds = Set(["text", "longtext", "list", "bool", "int", "choice", "groupNotes"])
        check(st.settingsVersion == 3 && st.schema.count == 11 && st.schema.allSatisfy { kinds.contains($0.kind) }
              && st.schema.first { $0.key == "learn_at" }?.options == ["50", "100"] && st.needsAttention.count == 1
              && st.lastRunOK == "2026-11-08T10:00:00.000Z" && st.lastRunError == nil, "v2_status_fixture_decodes")
    } catch { check(false, "v2_status_fixture_decodes: \(error)") }

    // settings_draft_rebases_untouched_keys: a newer stored value reaches the form unless you edited that field,
    // and saving sends only what you changed (choices as the option text).
    do {
        var d = ConnectorSettingsDraft(settings: ["learned": "- a", "ignore_senders": ["x@y.io"], "learn_at": 50], schema: schema, groups: ["Work"])
        let loadedChoice = d.text["learn_at"]
        d.text["ignore_senders"] = "x@y.io\nz@y.io"
        d.rebase(stored: ["learned": "- a\n- b", "ignore_senders": ["x@y.io"], "learn_at": 50], schema: schema, groups: ["Work"])
        let afterRebase = (d.text["learned"], d.text["ignore_senders"])
        let first = try d.changedValues(groups: ["Work"])
        d.text["learn_at"] = "100"
        let second = try d.changedValues(groups: ["Work"])
        check(loadedChoice == "50" && afterRebase.0 == "- a\n- b" && afterRebase.1 == "x@y.io\nz@y.io"
              && first.keys.sorted() == ["ignore_senders"] && first["ignore_senders"] as? [String] == ["x@y.io", "z@y.io"]
              && second["learn_at"] as? String == "100", "settings_draft_rebases_untouched_keys")
        d.text["critical_hours"] = "soon"
        var invalid = false
        do { _ = try d.changedValues(groups: ["Work"]) } catch { invalid = true }
        check(invalid, "settings_draft_rejects_bad_number")
    } catch { check(false, "settings_draft_rebases_untouched_keys: \(error)") }
}
