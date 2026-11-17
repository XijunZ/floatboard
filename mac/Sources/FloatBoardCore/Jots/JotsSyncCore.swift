import Foundation

/// A jot as sent to the engine's 30-day copy (design §4).
public struct PushJot: Equatable {
    public let id: Int64
    public let text: String
    public let kind: JotKind
    public let source: ItemSource
    public let tags: [String]
    public let added: Date
    public let updated: Date
    public let deleted: Bool
}

/// A row the engine holds for the Mac: a phone capture, edit, delete or restore, meeting notes, or a phone Make task /
/// Make decision (`kind` "action:make_task" / "action:make_decision", `ref` = the jot's key).
public struct EngineJot: Equatable {
    public var key: String
    public var macID: Int64?
    public var text: String
    public var kind: String
    public var source: String
    public var tags: [String]
    public var added: Date
    public var updated: Date
    public var deleted: Bool
    public var rev: Int
    public var ref: String?
    public var meeting: MeetingMeta?
    public init(key: String, macID: Int64?, text: String, kind: String, source: String, tags: [String] = [], added: Date, updated: Date,
                deleted: Bool = false, rev: Int, ref: String? = nil, meeting: MeetingMeta? = nil) {
        self.key = key; self.macID = macID; self.text = text; self.kind = kind; self.source = source; self.tags = tags; self.added = added
        self.updated = updated; self.deleted = deleted; self.rev = rev; self.ref = ref; self.meeting = meeting
    }
}

/// What the Mac tells the engine it saved: the row's key and the version (`rev`) it saw, and the jot's number.
public struct JotAck: Equatable {
    public let key: String
    public let rev: Int
    public let macID: Int64?
    public init(key: String, rev: Int, macID: Int64?) { self.key = key; self.rev = rev; self.macID = macID }
}

/// The Mac's side of the online copy, without the network (Connectors' `JotsSync` does the calls).
@MainActor public struct JotsSyncCore {
    let store: Store
    public init(store: Store) { self.store = store }
    /// The phone shows jots added in the last 30 days, so only those are sent.
    public static let window: TimeInterval = 30 * 86400

    /// Jots added in the last 30 days that changed since the engine last accepted them (deleted ones too), oldest change first.
    public func toPush(now: Date = Date(), limit: Int = 200) -> [PushJot] {
        let sql = """
            SELECT j.id FROM jots j LEFT JOIN jot_sync s ON s.jot_id=j.id
            WHERE j.added>=? AND (s.pushed IS NULL OR j.updated>s.pushed) ORDER BY j.updated, j.id LIMIT ?
            """
        let rows = (try? store.db.query(sql, [now.addingTimeInterval(-Self.window), limit]) { DB.int($0, 0) }) ?? [] // try?-ok: unreadable = nothing sent this time; the next pass sends it
        let js = JotStore(store: store)
        return rows.compactMap { js.jot($0) }.map {
            PushJot(id: $0.id, text: $0.text, kind: $0.kind, source: $0.source, tags: store.itemTags($0.shortID).all, added: $0.added,
                    updated: $0.updated, deleted: $0.deleted)
        }
    }

    /// The engine accepted these versions.
    public func markPushed(_ jots: [PushJot]) {
        store.perform {
            for j in jots {
                try store.db.run("INSERT INTO jot_sync(jot_id, pushed) VALUES(?,?) ON CONFLICT(jot_id) DO UPDATE SET pushed=excluded.pushed", [j.id, j.updated])
            }
        }
    }

    /// Applies what waits on the engine and returns the acks to send. Newest change wins: a phone edit, delete or restore
    /// older than this Mac's version is not applied (and the Mac's version is sent again). A phone Make decision waits on
    /// the engine until the Decisions area takes it (`JotActions.makeDecision`).
    public func apply(_ rows: [EngineJot], now: Date = Date()) -> [JotAck] {
        let js = JotStore(store: store)
        var acks: [JotAck] = []
        for r in rows {
            if r.kind.hasPrefix("action:") {
                if applyAction(r, now: now) { acks.append(JotAck(key: r.key, rev: r.rev, macID: nil)) }
                continue
            }
            if let id = r.macID ?? js.jot(origin: r.key)?.id {
                guard let j = js.jot(id) else { acks.append(JotAck(key: r.key, rev: r.rev, macID: id)); continue }
                if r.updated > j.updated {
                    if !r.deleted && j.deleted { js.undoDelete(id, now: r.updated) }
                    if r.text != j.text && !r.deleted { js.update(id, text: r.text, now: r.updated) }
                    if r.deleted && !j.deleted { js.delete(id, now: r.updated) }
                    store.activity("jots", .info, "Took in a change from the phone", detail: j.shortID.text)
                } else {
                    resend(id)   // this Mac's version is newer: the engine's copy gets it again
                }
                acks.append(JotAck(key: r.key, rev: r.rev, macID: id))
                continue
            }
            let saved: Jot?
            if r.kind == JotKind.meetingNotes.rawValue {
                saved = js.takeMeetingNotes(r.text, meta: r.meeting ?? MeetingMeta(recapKey: r.key, received: r.added), origin: r.key, now: r.added)
            } else {
                saved = js.add(r.text, kind: JotKind(rawValue: r.kind) ?? .jot, source: ItemSource(rawValue: r.source) ?? .phone, origin: r.key,
                               tags: r.tags, now: r.added)
                if let s = saved, r.updated > r.added { store.perform { try store.db.run("UPDATE jots SET updated=? WHERE id=?", [r.updated, s.id]) } }
                if let s = saved, r.deleted { js.delete(s.id, now: r.updated) }
            }
            guard let saved else { continue }   // not saved (empty, or the write failed and is in Activity): it stays waiting
            acks.append(JotAck(key: r.key, rev: r.rev, macID: saved.id))
        }
        return acks
    }

    /// Phone Make task / Make decision on a jot's text. True when done (acked).
    private func applyAction(_ r: EngineJot, now: Date) -> Bool {
        let js = JotStore(store: store)
        let source = r.ref.flatMap { ref in ShortID.parse(ref).map(\.number) ?? js.jot(origin: ref)?.id }.map { ShortID(kind: .jot, number: $0) }
        if r.kind == "action:make_decision" {
            guard let hook = JotActions.makeDecision, let source else { return false }
            return hook(store, r.text, source)
        }
        guard r.kind == "action:make_task" else { return true }   // an action this version does not know: dropped
        let draft = MakeTask.draft(selection: r.text, sourceTags: source.map(store.itemTags), groups: store.areas.map(\.name))
        let due = MakeTask.dueMentioned(in: r.text, now: r.added)
        guard let id = store.makeTask(draft, due: due?.date, dueHasTime: due?.hasTime ?? false, from: source, now: r.updated) else { return false }
        store.perform { try store.db.run("UPDATE cards SET item_source='phone' WHERE id=?", [id]) }
        return true
    }

    /// Makes the engine get this jot again at the next push.
    func resend(_ id: Int64) {
        store.perform { try store.db.run("UPDATE jot_sync SET pushed=NULL WHERE jot_id=?", [id]) }
    }
}
