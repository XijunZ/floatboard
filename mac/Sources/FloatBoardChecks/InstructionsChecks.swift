import Foundation
import FloatBoardConnectors
import FloatBoardCore

/// Instructions with versions (docs/architecture.md, C8): every change kept, learning merged with your edits, restore.
@MainActor func instructionsChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-instr-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "instructions setup: \(error)"); return }
    let prov = Provenance(model: "m", skillVersion: "1", created: "2026-11-07T10:00:00Z")
    func learned(_ id: String, _ text: String) throws {
        try Reconciler.apply([Proposal(id: id, kind: .learned, sourceKey: nil, title: "Learned preferences", why: "", due: nil, hasTime: false,
                                       group: nil, importance: 1, sourceLabel: "", link: "", summary: nil, taskRef: nil, learned: text,
                                       provenance: prov)], connector: "in", store: store, defaultGroup: "Personal", autoAdd: true)
    }
    func current(_ k: String) -> String { store.connectors.first { $0.id == "in" }?.settings[k] as? String ?? "" }

    // Pure rules.
    check(Instructions.diff("- a\n- b", "- b\n- c") == (["- c"], ["- a"]), "instructions_diff_is_per_line")
    check(Instructions.mergeLearned(base: "- a\n- b", current: "- a\n- b", incoming: "- a\n- c") == "- a\n- c",
          "learning_replaces_text_you_did_not_edit")
    check(Instructions.mergeLearned(base: "- a\n- b", current: "- a\n- mine", incoming: "- a\n- b\n- c") == "- a\n- c\n- mine",
          "your_edit_wins_over_a_learning_run")
    check(Instructions.summary("- a", "- b") == "+ b; − a", "instructions_summary_reads_plus_and_minus")

    do {
        try ConnectorAccounts.add(id: "in", name: "In", baseURL: URL(string: "https://in.example")!, key: "k", store: store)
        try store.saveConnectorSettings(connector: "in", values: ["my_rules": "Keep it short"])
        // First learning: no edits yet, taken as it is; the history starts.
        try learned("l1", "- surveys aren't tasks\n- invoices are")
        var v = store.instructionVersions(connector: "in", part: "learned")
        check(current("learned") == "- surveys aren't tasks\n- invoices are" && v.count == 1 && v[0].source == .learning,
              "first_learning_is_a_version")
        // You edit: remove one line, add one. Then learning runs again on the old text: your edit wins.
        try store.saveConnectorSettings(connector: "in", values: ["learned": "- invoices are\n- school emails are tasks"])
        try learned("l2", "- surveys aren't tasks\n- invoices are\n- receipts aren't tasks")
        check(current("learned") == "- invoices are\n- receipts aren't tasks\n- school emails are tasks",
              "learning_keeps_your_edits_and_adds_its_own")
        v = store.instructionVersions(connector: "in", part: "learned")
        check(v.map(\.source) == [.learning, .you, .learning] && v[0].note.contains("kept your own edits"),
              "every_learned_change_is_kept_newest_first")
        // Restore the first version: a new version, nothing deleted.
        try store.restoreInstructions(connector: "in", version: v.last!)
        v = store.instructionVersions(connector: "in", part: "learned")
        check(current("learned") == "- surveys aren't tasks\n- invoices are" && v.count == 4 && v[0].source == .restore,
              "restore_puts_an_old_version_back_as_a_new_one")
        // Your rules: the text you had before versions is kept as the start.
        try store.saveConnectorSettings(connector: "in", values: ["my_rules": "Keep it very short"])
        let r = store.instructionVersions(connector: "in", part: "my_rules")
        check(r.map(\.text) == ["Keep it very short", "Keep it short"] && r.map(\.source) == [.you, .you],
              "your_rules_have_versions")
        // Saving the same text adds nothing.
        try store.saveConnectorSettings(connector: "in", values: ["my_rules": "Keep it very short"])
        check(store.instructionVersions(connector: "in", part: "my_rules").count == 2, "unchanged_text_adds_no_version")
    } catch { check(false, "instructions: \(error)") }
}

/// Keys entered on the Mac reach the engine; while it can't be reached they wait (names only) and are sent later.
@MainActor func keysChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-keys-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: temp cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("board.sqlite"))) } catch { check(false, "keys setup: \(error)"); return }
    do {
        try ConnectorAccounts.add(id: "ky", name: "Ky", baseURL: URL(string: "https://ky.example")!, key: "k", store: store)
        try Keys.setClaude("sk-ant-secret-1", store: store)
        try Keys.setGmailClient(id: "cid.apps", secret: "gsecret", store: store)
        check(Keys.pending(connector: "ky", store: store) == [.claude, .googleClient] && Keys.value(Keys.claude, store: store) == "sk-ant-secret-1",
              "keys_saved_on_the_mac_and_queued")
        let meta = (try? store.db.query("SELECT group_concat(value) FROM meta") { DB.text($0, 0) }.first) ?? "" // try?-ok: empty fails the check
        check(!meta.contains("sk-ant") && !meta.contains("gsecret"), "only_key_names_wait_in_the_board")

        // Engine down: nothing is lost.
        let down = FakeEngine { _, _, _ in (503, "{}") }
        let ok1 = await Keys.push(connector: "ky", store: store, client: down.client())
        check(!ok1 && Keys.pending(connector: "ky", store: store).count == 2, "keys_wait_while_the_engine_is_down")

        // Engine up: both go in one request, then nothing waits.
        let up = FakeEngine { _, p, _ in p == "/v2/keys" ? (200, #"{"ok":true,"keys":{"claude":true,"google_client_id":"cid.apps"}}"#) : (404, "{}") }
        let ok2 = await Keys.push(connector: "ky", store: store, client: up.client())
        let sent = up.bodies("/v2/keys").first ?? [:]
        check(ok2 && Keys.pending(connector: "ky", store: store).isEmpty && sent["claude_key"] as? String == "sk-ant-secret-1"
              && (sent["google_client"] as? [String: String])?["client_secret"] == "gsecret", "keys_sent_once_the_engine_answers")

        // Removing the Claude key sends "" (removes it on the engine too).
        try Keys.setClaude("", store: store)
        _ = await Keys.push(connector: "ky", store: store, client: up.client())
        check(up.bodies("/v2/keys").last?["claude_key"] as? String == "" && Keys.value(Keys.claude, store: store) == nil,
              "removing_a_key_removes_it_on_the_engine")
    } catch { check(false, "keys: \(error)") }
}
