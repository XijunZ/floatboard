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
    /// Kept per connector: each engine holds its own copy.
    public func toPush(connector: String, now: Date = Date(), limit: Int = 200) -> [PushJot] {
        let sql = """
            SELECT j.id FROM jots j LEFT JOIN jot_pushed s ON s.jot_id=j.id AND s.connector=?
            WHERE j.added>=? AND (s.pushed IS NULL OR j.updated>s.pushed) ORDER BY j.updated, j.id LIMIT ?
            """
        let rows = (try? store.db.query(sql, [connector, now.addingTimeInterval(-Self.window), limit]) { DB.int($0, 0) }) ?? [] // try?-ok: unreadable = nothing sent this time; the next pass sends it
        let js = JotStore(store: store)
        return rows.compactMap { js.jot($0) }.map {
            // The phone's tag rules (at most 20, each up to 60 characters): the engine refuses a request with any other.
            PushJot(id: $0.id, text: $0.text, kind: $0.kind, source: $0.source, tags: TagRules.forPhone(store.itemTags($0.shortID).all), added: $0.added,
                    updated: $0.updated, deleted: $0.deleted)
        }
    }

    /// The connector's engine accepted these versions.
    public func markPushed(_ jots: [PushJot], connector: String) {
        store.perform {
            for j in jots {
                try store.db.run("""
                    INSERT INTO jot_pushed(connector, jot_id, pushed) VALUES(?,?,?) ON CONFLICT(connector, jot_id) DO UPDATE SET pushed=excluded.pushed
                    """, [connector, j.id, j.updated])
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
            // Looked up with errors kept apart from "not here": a read that fails leaves the row waiting (never acked as gone).
            var found: Int64?, known: Jot?, reused = false
            do {
                found = try r.macID ?? js.jotIDOrThrow(origin: r.key)
                known = try found.flatMap { try js.jotOrThrow($0) }
                // The same jot only when it was added at the same moment: after an older backup is restored, a new jot here
                // can have the number the phone still uses for another one; that one is never touched (recovered below).
                if r.macID != nil, let k = known, !Self.sameJot(k, r) { known = nil; reused = true }
                // A jot this Mac no longer has (an older backup was restored): one recovered earlier is found by its key.
                if r.macID != nil, known == nil, let again = try js.jotIDOrThrow(origin: r.key),
                   let k = try js.jotOrThrow(again), Self.sameJot(k, r) {
                    found = again; known = k; reused = false
                }
            } catch {
                store.activity("jots", .error, "Could not read a jot for a change from the phone; it stays on the engine and is tried again",
                               detail: "\(r.key): \(error)")
                continue
            }
            if let id = found {
                guard let j = known else {
                    // Missing here: nothing with words is ever acked unsaved. It is recovered (text, earlier texts, deletion) in one
                    // transaction under its key, then acked with the recovered jot's number; a failure leaves it waiting.
                    guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        // Nothing to keep; a number now used by another jot is not handed back with it.
                        acks.append(JotAck(key: r.key, rev: r.rev, macID: reused ? nil : id)); continue
                    }
                    do {
                        let n = try store.performThrowing { () throws -> Int64 in
                            let n = try js.addRow(r.text, kind: JotKind(rawValue: r.kind) ?? .jot, source: ItemSource(rawValue: r.source) ?? .phone,
                                                  origin: r.key, taskID: nil, tags: r.tags, now: r.added)
                            if r.deleted || r.updated > r.added { try applyPhoneRow(n, r) }
                            try js.keepInHistoryRow(n, r.versions)
                            return n
                        }
                        store.activity("jots", .warning, "Recovered a jot this Mac no longer had (an older backup?) from the phone's copy",
                                       detail: "\(ShortID(kind: .jot, number: id).text) → \(ShortID(kind: .jot, number: n).text)")
                        acks.append(JotAck(key: r.key, rev: r.rev, macID: n))
                    } catch {
                        store.activity("jots", .error, "A jot from the phone is missing on this Mac and could not be recovered; it stays on the engine and is tried again",
                                       detail: "\(r.key): \(error)")
                    }
                    continue
                }
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
            }
            guard let saved else { continue }   // the write failed (it is in Activity): it stays waiting
            // A later edit time and a delete made on the phone, with the earlier texts, in one transaction: acked only after it.
            do {
                try store.performThrowing {
                    // Meeting notes too: notes deleted (or edited) on the phone before this first intake arrive that way,
                    // so they are never sent back as live (round 28).
                    if r.updated > r.added || r.deleted { try applyPhoneRow(saved.id, r) }
                    try js.keepInHistoryRow(saved.id, r.versions)
                }
            } catch {
                // The jot is saved; its earlier texts are not: not acked, so the next pass (finding it by key) tries the history again.
                store.activity("jots", .error, "Could not keep a jot's earlier texts from the phone; tried again", detail: "\(saved.shortID.text): \(error)")
                continue
            }
            acks.append(JotAck(key: r.key, rev: r.rev, macID: saved.id))
        }
        return acks
    }

    /// Phone Make task / Make decision on a jot's text. True when done (acked). Applied once: a marker written in the same
    /// transaction as the task or decision makes one sent again (its acknowledgement lost) an ack with nothing made.
    private func applyAction(_ r: EngineJot, now: Date) -> Bool {
        let js = JotStore(store: store)
        do {
            if try store.db.query("SELECT 1 FROM jot_actions_done WHERE key=?", [r.key], { DB.int($0, 0) }).first != nil { return true }
        } catch {
            store.activity("jots", .error, "Could not read which phone actions were applied; it stays on the engine and is tried again", detail: "\(r.key): \(error)")
            return false
        }
        let marker: (ShortID) throws -> Void = { [store] _ in
            try store.db.run("DELETE FROM jot_actions_done WHERE done<?", [now.addingTimeInterval(-30 * 86400)])
            try store.db.run("INSERT OR IGNORE INTO jot_actions_done(key, done) VALUES(?,?)", [r.key, now])
        }
        // The jot it was made from; a lookup that fails is not "no jot": the action waits (not acked) and comes again.
        let source: ShortID?
        do {
            source = try r.ref.flatMap { ref in try ShortID.parse(ref).map(\.number) ?? js.jotIDOrThrow(origin: ref) }.map { ShortID(kind: .jot, number: $0) }
        } catch {
            store.activity("jots", .error, "Could not read the jot of a phone action; it stays on the engine and is tried again", detail: "\(r.key): \(error)")
            return false
        }
        // Legacy (phones before the Decisions queue, 17 Nov 2026): remove with the engine's "make_decision" op, not before 1 Feb 2027.
        if r.kind == "action:make_decision" {
            guard let hook = JotActions.makeDecision, let source else { return false }
            return hook(store, r.text, source, marker)
        }
        guard r.kind == "action:make_task" else { return true }   // an action this version does not know: dropped
        let draft = MakeTask.draft(selection: r.text, sourceTags: source.map(store.itemTags), groups: store.areas.map(\.name))
        let due = MakeTask.dueMentioned(in: r.text, now: r.added)
        do {
            // One transaction: a task half made (say, not marked as from the phone) never stays; the action is tried again.
            return try store.makeTaskOrThrow(draft, due: due?.date, dueHasTime: due?.hasTime ?? false, from: source, itemSource: .phone, now: r.updated,
                                             extra: { try marker(ShortID(kind: .task, number: $0)) }) != nil
        } catch {
            store.activity("jots", .error, "Could not make the phone's task; it stays on the engine and is tried again", detail: "\(r.key): \(error)")
            return false
        }
    }

    /// Whether a local jot and the phone's copy are the same jot: added at the same moment (the copy's time has millisecond
    /// precision). A Mac jot and a phone capture keep their added time for life, here and on the engine.
    static func sameJot(_ j: Jot, _ r: EngineJot) -> Bool { abs(j.added.timeIntervalSince(r.added)) < 0.002 }

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

    /// Where a connector's engine account (fingerprint) is kept.
    public static func engineKey(_ connector: String) -> String { "jots.pushed_engine.\(connector)" }

    /// The engine account `connector` sends the phone's copy to (a fingerprint of its address and key). Another one (a new
    /// engine, a re-pointed connector, a new key) holds none of this Mac's jots: every recent jot is sent to it again.
    /// Other connectors keep their own state.
    public func useEngine(_ fingerprint: String, connector: String) {
        let current = (try? store.db.query("SELECT value FROM meta WHERE key=?", [Self.engineKey(connector)]) { DB.text($0, 0) })?.first // try?-ok: unknown = treated as another engine (sent again: harmless)
        guard current != fingerprint else { return }
        store.perform {
            try store.db.run("DELETE FROM jot_pushed WHERE connector=?", [connector])
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [Self.engineKey(connector), fingerprint])
        }
    }

    /// Forgets what `connector` was sent (it was added again or moved): its engine gets every recent jot.
    public func forget(connector: String) throws {
        try store.db.run("DELETE FROM jot_pushed WHERE connector=?", [connector])
        try store.db.run("DELETE FROM meta WHERE key=?", [Self.engineKey(connector)])
    }

    /// Makes every engine get this jot again at the next push.
    func resend(_ id: Int64) {
        store.perform { try store.db.run("DELETE FROM jot_pushed WHERE jot_id=?", [id]) }
    }
}
