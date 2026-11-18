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
    /// Earlier texts the engine kept until this Mac has them in the jot's history (never thrown away).
    public var versions: [EarlierText]
    public init(key: String, macID: Int64?, text: String, kind: String, source: String, tags: [String] = [], added: Date, updated: Date,
                deleted: Bool = false, rev: Int, ref: String? = nil, meeting: MeetingMeta? = nil, versions: [EarlierText] = []) {
        self.versions = versions
        self.key = key; self.macID = macID; self.text = text; self.kind = kind; self.source = source; self.tags = tags; self.added = added
        self.updated = updated; self.deleted = deleted; self.rev = rev; self.ref = ref; self.meeting = meeting
    }
}

/// A text the engine kept for a jot's history: one a phone change replaced, or a phone edit older than this Mac's version.
public struct EarlierText: Equatable {
    public let text: String
    public let at: Date
    public init(text: String, at: Date) { self.text = text; self.at = at }
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
                // History, text and deletion in ONE transaction that throws; acked only after it commits. A failure (in Activity)
                // leaves the row waiting on the engine, which keeps its copies.
                let newer = r.updated > j.updated
                do {
                    try store.performThrowing {
                        try js.keepInHistoryRow(id, r.versions + (newer ? [] : [EarlierText(text: r.text, at: r.updated)]))
                        if newer { try applyPhoneRow(id, r) }
                    }
                } catch {
                    store.activity("jots", .error, "Could not take in a change from the phone; it stays on the engine and is tried again",
                                   detail: "\(j.shortID.text): \(error)")
                    continue
                }
                if newer { store.activity("jots", .info, "Took in a change from the phone", detail: j.shortID.text) } else { resend(id) }
                acks.append(JotAck(key: r.key, rev: r.rev, macID: id))
                continue
            }
            if r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A delete or restore of a jot this Mac never had (or an empty capture): nothing to keep; taken, not left waiting.
                acks.append(JotAck(key: r.key, rev: r.rev, macID: nil))
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
            guard let saved else { continue }   // the write failed (it is in Activity): it stays waiting
            do { try store.performThrowing { try js.keepInHistoryRow(saved.id, r.versions) } } catch {
                // The jot is saved; its earlier texts are not: not acked, so the next pass (finding it by key) tries the history again.
                store.activity("jots", .error, "Could not keep a jot's earlier texts from the phone; tried again", detail: "\(saved.shortID.text): \(error)")
                continue
            }
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

    /// The phone's newer version of a jot, inside the caller's transaction (throws, never swallows): its text first (the old
    /// text to the history, ids typed in it linked), then restore or delete, so an edit followed by a delete keeps the latest text.
    private func applyPhoneRow(_ id: Int64, _ r: EngineJot) throws {
        guard let cur = try store.db.query("SELECT text, deleted FROM jots WHERE id=?", [id], { (DB.text($0, 0), DB.int($0, 1) != 0) }).first else { return }
        let hasText = !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText && r.text != cur.0 {
            try store.db.run("INSERT INTO jot_history(jot_id, text, at) VALUES(?,?,?)", [id, cur.0, r.updated])
            try store.db.run("UPDATE jots SET text=?, updated=? WHERE id=?", [r.text, r.updated, id])
            try store.linkMentionsRow(in: r.text, previous: cur.0, from: ShortID(kind: .jot, number: id), now: r.updated)
        }
        if r.deleted != cur.1 {
            try store.db.run("UPDATE jots SET deleted=?, updated=? WHERE id=?", [r.deleted ? 1 : 0, r.updated, id])
            if r.deleted { _ = try store.hideLinks(of: ShortID(kind: .jot, number: id)) } else { try store.unhideLinks(of: ShortID(kind: .jot, number: id)) }
        } else {
            try store.db.run("UPDATE jots SET updated=max(updated, ?) WHERE id=?", [r.updated, id])
        }
    }

    /// Makes the engine get this jot again at the next push.
    func resend(_ id: Int64) {
        store.perform { try store.db.run("UPDATE jot_sync SET pushed=NULL WHERE jot_id=?", [id]) }
    }
}
