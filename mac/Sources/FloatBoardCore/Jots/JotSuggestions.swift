import Foundation

/// J5: Claude's tag suggestions after a jot is saved, each answered ✓ (the tag is added; primary when the jot has none) or ✗.
@MainActor public struct JotSuggestions {
    let store: Store
    public init(store: Store) { self.store = store }

    /// Jots to ask Claude about: new since the last ask, not deleted, untagged, oldest first, at most `limit`.
    public func toAsk(limit: Int = 20) -> [Jot] {
        let ids = (try? store.db.query("""
            SELECT j.id FROM jots j LEFT JOIN jot_sync s ON s.jot_id=j.id
            WHERE j.deleted=0 AND coalesce(s.tags_asked,0)=0 AND NOT EXISTS (SELECT 1 FROM item_tags t WHERE t.item='J-' || j.id)
            ORDER BY j.id LIMIT ?
            """, [limit]) { DB.int($0, 0) }) ?? [] // try?-ok: unreadable = nothing asked this time; the next pass asks again
        return ids.compactMap { JotStore(store: store).jot($0) }
    }

    /// Records Claude's answer: the asked jots are marked (never asked again) and known, unused tags become open suggestions.
    public func record(asked: [Int64], suggestions: [Int64: [String]], now: Date = Date()) {
        store.perform {
            for id in asked {
                try store.db.run("INSERT INTO jot_sync(jot_id, tags_asked) VALUES(?,1) ON CONFLICT(jot_id) DO UPDATE SET tags_asked=1", [id])
                let have = Set(store.itemTags(ShortID(kind: .jot, number: id)).all.map { $0.lowercased() })
                for tag in store.knownTags(suggestions[id] ?? []).prefix(3) where !have.contains(tag.lowercased()) {
                    try store.db.run("INSERT OR IGNORE INTO jot_suggestions(jot_id, tag, state, at) VALUES(?,?,'open',?)", [id, tag, now])
                }
            }
        }
    }

    /// Open suggestions for a jot, in the order they came.
    public func open(_ jotID: Int64) -> [String] {
        (try? store.db.query("SELECT tag FROM jot_suggestions WHERE jot_id=? AND state='open' ORDER BY at, rowid", [jotID]) { DB.text($0, 0) }) ?? [] // try?-ok: unreadable = none shown
    }

    /// ✓: adds the tag (primary when the jot has none).
    public func accept(_ jotID: Int64, _ tag: String, now: Date = Date()) {
        let me = ShortID(kind: .jot, number: jotID)
        var t = store.itemTags(me)
        if t.primary == nil { t.primary = tag } else if !t.all.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { t.others.append(tag) }
        if let why = JotStore(store: store).setTags(jotID, t.all, now: now) {
            store.activity("jots", .warning, "Could not add the suggested tag", detail: why)
            return
        }
        answer(jotID, tag, "accepted", now)
    }

    /// ✗: the suggestion goes away.
    public func dismiss(_ jotID: Int64, _ tag: String, now: Date = Date()) { answer(jotID, tag, "dismissed", now) }

    private func answer(_ jotID: Int64, _ tag: String, _ state: String, _ now: Date) {
        store.perform { try store.db.run("UPDATE jot_suggestions SET state=?, at=? WHERE jot_id=? AND tag=?", [state, now, jotID, tag]) }
    }
}
