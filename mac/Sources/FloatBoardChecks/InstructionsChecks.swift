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
