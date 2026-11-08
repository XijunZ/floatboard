import Foundation
import FloatBoardCore

extension Store {
    /// Test-only: inserts a connector card the way the reconciler stores one, with its "created" history row.
    /// An `email:<id>` external id also sets the source message id (with no sent date), like older email cards.
    @discardableResult
    func seedCard(title: String, area: String = "Personal", importance: Importance = .low, source: String,
                  externalID: String, link: String = "", meta: [String: String] = [:]) -> Bool {
        let now = Date()
        let mid: String? = externalID.hasPrefix("email:") ? String(externalID.dropFirst(6)) : nil
        var ok = false
        performForTest {
            let metaJSON = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)
            let id = try db.run("""
                INSERT INTO cards(title,area,importance,status,created,updated,source,external_id,source_link,source_meta,
                                  imported_at,connector,source_mid)
                VALUES(?,?,?,'todo',?,?,?,?,?,?,?,?,?)
                """, [title, resolve(area), importance.rawValue, now, now, source, externalID, link, metaJSON, now, source, mid])
            try db.run("INSERT INTO events(card_id,at,kind,to_status,actor,uuid) VALUES(?,?,?,'todo',?,?)",
                       [id, now, "created (from \(source))", Actor.connector(source).stored, UUID().uuidString])
            ok = true
        }
        return ok
    }

    /// Test-only: the live card with this external id.
    func card(externalID: String) -> Card? { cards.first { $0.externalID == externalID } }
}
