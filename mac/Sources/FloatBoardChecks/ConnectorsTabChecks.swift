import FloatBoardConnectors
import FloatBoardCore
import Foundation
import SQLite3

/// Checks for the Connectors tab's data side: connect links, settings saves, removing a connector.
@MainActor func connectorsTabChecks(_ store: Store) {
    // connect_link_parsed
    func parsed(_ s: String) -> (url: URL, key: String, name: String)? { URL(string: s).flatMap(ConnectLink.parse) }
    let good = parsed("floatboard://connect?url=https%3A%2F%2Fengine.example.com&key=k-123&name=Email")
    let local = parsed("floatboard://connect?url=http://localhost:8787&key=k&name=Dev")
    let loop = parsed("floatboard://connect?url=http://127.0.0.1:8787&key=k&name=Dev")
    check(good?.url.absoluteString == "https://engine.example.com" && good?.key == "k-123" && good?.name == "Email"
          && local?.url.host == "localhost" && loop?.url.host == "127.0.0.1"
          && parsed("floatboard://connect?url=http://engine.example.com&key=k&name=E") == nil
          && parsed("floatboard://connect?url=ftp://engine.example.com&key=k&name=E") == nil
          && parsed("floatboard://connect?url=https://engine.example.com&key=&name=E") == nil
          && parsed("floatboard://connect?url=https://engine.example.com&name=E") == nil
          && parsed("floatboard://other?url=https://engine.example.com&key=k&name=E") == nil
          && parsed("https://connect?url=https://engine.example.com&key=k&name=E") == nil
          && parsed("floatboard://connect?url=https://engine.example.com&key=k")?.name == "engine.example.com",
          "connect_link_parsed")
    check(ConnectLink.id(forName: "Email") == "email" && ConnectLink.id(forName: "My Calendar!") == "my-calendar"
          && ConnectLink.id(forName: "  ") == "connector", "connect_link_name_to_id")

    // settings_save_bumps_version_and_queues
    func row(_ id: String) -> (json: String, version: Int)? {
        // try?-ok: a failed query makes the check fail
        (try? store.db.query("SELECT settings_json, settings_version FROM connectors WHERE id=?", [id]) { // try?-ok: test helper
            (DB.text($0, 0), Int(DB.int($0, 1)))
        })?.first
    }
    func settingsRows(_ id: String) -> Int {
        // try?-ok: a failed query makes the check fail
        Int((try? store.db.query("SELECT count(*) FROM outbox WHERE connector=? AND kind='settings'", [id]) { DB.int($0, 0) })?.first ?? -1) // try?-ok: test helper
    }
    store.performForTest("""
        INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version)
        VALUES('st','st','{"learned":"- likes mornings","default_group":"Work","vip":["a"]}',4)
        """)
    do {
        try store.saveConnectorSettings(connector: "st", values: ["vip": ["a", "b"], "hours": 24,
                                                                  "group_notes": ["Work": "office"]])
        let r = row("st")
        // try?-ok: unreadable JSON fails the check
        let d = (try? JSONSerialization.jsonObject(with: Data((r?.json ?? "").utf8))) as? [String: Any] ?? [:] // try?-ok: test helper
        check(r?.version == 5 && settingsRows("st") == 1
              && d["learned"] as? String == "- likes mornings" && d["default_group"] as? String == "Work"
              && d["vip"] as? [String] == ["a", "b"] && d["hours"] as? Int == 24
              && (d["group_notes"] as? [String: String]) == ["Work": "office"],
              "settings_save_bumps_version_and_queues")
        check(store.connectors.first { $0.id == "st" }?.settingsVersion == 5, "connector_list_reloaded_after_save")
    } catch { check(false, "settings_save_bumps_version_and_queues: \(error)") }
    do {
        try store.saveConnectorSettings(connector: "st", values: ["bad": Date()])
        check(false, "settings_save_rejects_unsavable_values")
    } catch {
        check(row("st")?.version == 5 && settingsRows("st") == 1, "settings_save_rejects_unsavable_values")
    }
    do {
        try store.saveConnectorSettings(connector: "st", values: ["learned": "- edited", "default_group": "Personal"])
        let d = (try? JSONSerialization.jsonObject(with: Data((row("st")?.json ?? "").utf8))) as? [String: Any] ?? [:] // try?-ok: fails the check
        check(d["learned"] as? String == "- edited" && d["default_group"] as? String == "Personal" && row("st")?.version == 6
              && settingsRows("st") == 2, "settings_save_edits_learned_and_default_group")
    } catch { check(false, "settings_save_edits_learned_and_default_group: \(error)") }

    // remove_connector_keeps_cards
    do {
        try ConnectorAccounts.add(id: "rmtab", name: "Removable", baseURL: URL(string: "https://rm.example")!, key: "secret-rm", store: store)
        let info = store.connectors.first { $0.id == "rmtab" }
        check(info?.baseURL == "https://rm.example" && info?.name == "Removable"
              && (try? ConnectorAccounts.key(for: "rmtab")) == "secret-rm", "connector_added_with_key") // try?-ok: nil fails the check
        try Reconciler.apply([Proposal(id: "rm-p1", kind: .task, sourceKey: SourceKey(messageID: "rm-m1", sentAt: "2026-11-07T10:00:00Z"),
                                       title: "Card from rm", why: "asked", due: nil, hasTime: false, group: nil, importance: 1,
                                       sourceLabel: "Rosa", link: "https://example.com/m1", summary: nil, taskRef: nil, learned: nil,
                                       provenance: Provenance(model: "m", skillVersion: "1", created: "2026-11-07T10:00:00Z"))],
                             connector: "rmtab", store: store, defaultGroup: store.areas.first?.name ?? "Personal", autoAdd: true)
        let card = store.cards.first { $0.connector == "rmtab" }
        let eventsBefore = card.map { c in ((try? store.db.query("SELECT count(*) FROM events WHERE card_id=?", [c.id]) { DB.int($0, 0) })?.first) ?? 0 } ?? 0 // try?-ok: fails the check
        try ConnectorAccounts.remove(id: "rmtab", store: store)
        let gone = ((try? store.db.query("SELECT count(*) FROM connectors WHERE id='rmtab'") { DB.int($0, 0) })?.first) == 0 // try?-ok: fails the check
        let after = card.flatMap { store.card($0.id) }
        let eventsAfter = card.map { c in ((try? store.db.query("SELECT count(*) FROM events WHERE card_id=?", [c.id]) { DB.int($0, 0) })?.first) ?? 0 } ?? -1 // try?-ok: fails the check
        check(card != nil && gone && after?.connector == "rmtab" && after?.title == "Card from rm" && eventsAfter == eventsBefore
              && eventsBefore > 0 && (try? ConnectorAccounts.key(for: "rmtab")) == .some(nil) // try?-ok: fails the check
              && !store.connectors.contains { $0.id == "rmtab" }, "remove_connector_keeps_cards")
    } catch { check(false, "remove_connector_keeps_cards: \(error)") }

    // Source chip label (moved from the old UI self-test)
    var c = Card(id: 0, title: "Reply", notes: "", area: "Personal", importance: .medium, due: nil, status: .todo,
                 created: Date(), started: nil, done: nil)
    c.connector = "email"
    c.sourceMeta = ["source_label": "Rosa Allen", "why": "asked"]
    let fromLabel = c.sourceLabel
    c.sourceMeta = ["sender": "Rosa Allen <rosa@x.io>"]
    let fromSender = c.sourceLabel
    c.sourceMeta = ["sender": "<rosa@x.io>"]
    let fromAddress = c.sourceLabel
    c.sourceMeta = [:]
    check(fromLabel == "Rosa Allen" && fromSender == "Rosa Allen" && fromAddress == "rosa@x.io" && c.sourceLabel == "email",
          "source_chip_label")
}
