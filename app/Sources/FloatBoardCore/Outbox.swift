import Foundation
import SQLite3

public enum OutboxKind: String, Codable {
    case done, deleted, changed, correction, settings
    /// The user asked for a reply draft (see `Store.requestReplyDraft`).
    case draftReply = "draft_reply"
}

/// One thing a connector still has to be told. Rows are written in the same transaction as the board change
/// that caused them, so a crash or going offline never loses one. `uuid` is the id that travels to the engine.
public struct OutboxItem: Codable, Equatable {
    public var uuid: String
    public var connector: String
    public var kind: OutboxKind
    public var payload: [String: String]
    public var created: Date
    public var attempts: Int
    public var nextTry: Date
    public var lastError: String?
}

extension Store {
    // MARK: Reading the queue

    /// Oldest first; only items that are unsent and due for a try.
    public func pendingOutbox(connector: String, limit: Int, now: Date) -> [OutboxItem] {
        do {
            detachUnreadableOutbox(connector: connector)
            let items: [OutboxItem?] = try db.query("""
                SELECT uuid,connector,kind,payload_json,created,attempts,next_try,last_error FROM outbox
                WHERE connector=? AND sent IS NULL AND detached=0 AND next_try<=? ORDER BY created, rowid LIMIT ?
                """, [connector, now, limit]) { s in
                let payload: [String: String]
                // Unreadable rows were detached just above; this guards the impossible race and never sends an empty change.
                guard let decoded = try? Self.decodePayload(DB.text(s, 3)) else { return nil } // try?-ok: row was just checked readable
                payload = decoded
                return OutboxItem(uuid: DB.text(s, 0), connector: DB.text(s, 1),
                           kind: OutboxKind(rawValue: DB.text(s, 2)) ?? .changed,
                           payload: payload,
                           created: DB.date(s, 4) ?? now, attempts: Int(DB.int(s, 5)),
                           nextTry: DB.date(s, 6) ?? now,
                           lastError: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : DB.text(s, 7))
            }
            return items.compactMap { $0 }
        } catch {
            activity("outbox", .error, "Could not read the outbox", detail: "\(error)")
            return []
        }
    }

    /// Unsent rows whose payload can't be decoded are set aside (detached, reason 'unreadable'): kept for the record, never
    /// sent, and no longer counted as waiting. Each is logged once, because after this it is no longer a candidate.
    public func detachUnreadableOutbox(connector: String? = nil) {
        do {
            let rows = try db.query("SELECT uuid,payload_json FROM outbox WHERE sent IS NULL AND detached=0 AND (?1 IS NULL OR connector=?1)",
                                    [connector]) { (DB.text($0, 0), DB.text($0, 1)) }
            for (id, json) in rows {
                do { _ = try Self.decodePayload(json) } catch {
                    do {
                        try db.run("UPDATE outbox SET detached=1, detach_reason='unreadable' WHERE uuid=?", [id])
                        activity("outbox", .warning, "A queued change can't be read, so it was set aside (kept for the record, never sent)",
                                 detail: "\(error)", trace: id)
                    } catch {
                        activity("outbox", .error, "Could not set aside an unreadable queued change", detail: "\(error)", trace: id)
                    }
                }
            }
        } catch {
            activity("outbox", .error, "Could not check the outbox for unreadable changes", detail: "\(error)")
        }
    }

    /// When the oldest unsent item may next be tried (nil if the queue is empty). Connectors use it to keep order:
    /// nothing newer goes out while the oldest is backing off.
    public func oldestUnsentNextTry(connector: String) -> Date? {
        do {
            return try db.query("SELECT next_try FROM outbox WHERE connector=? AND sent IS NULL AND detached=0 ORDER BY created, rowid LIMIT 1",
                                [connector]) { DB.date($0, 0) }.first ?? nil
        } catch {
            activity("outbox", .error, "Could not read the outbox", detail: "\(error)")
            return nil
        }
    }

    /// Everything not yet delivered, including items waiting out a back-off.
    public func waitingCount(connector: String) -> Int {
        do {
            return Int(try db.query("SELECT count(*) FROM outbox WHERE connector=? AND sent IS NULL AND detached=0", [connector]) { DB.int($0, 0) }.first ?? 0)
        } catch {
            activity("outbox", .error, "Could not count the outbox", detail: "\(error)")
            return 0
        }
    }

    // MARK: Delivery results

    /// A delivered reply draft request also starts its card's timeout, if it is still the card's current request.
    public func markSent(_ uuids: [String], now: Date, log: Bool = true) {
        var draftClockStarted = false
        for id in uuids {
            do {
                // One transaction: a delivered draft request and its card's sent time are both recorded or neither.
                try performThrowing {
                    try db.run("UPDATE outbox SET sent=?, last_error=NULL WHERE uuid=?", [now, id])
                    if log { activity("outbox", .info, "Delivered to the engine", trace: id) }
                    guard let json = try db.query("SELECT payload_json FROM outbox WHERE uuid=? AND kind=?", [id, OutboxKind.draftReply.rawValue],
                                                  { DB.text($0, 0) }).first else { return }
                    let request = try Self.decodePayload(json)["request_id"] ?? ""
                    try db.run("""
                        UPDATE cards SET reply_draft_sent_at=? WHERE reply_draft_request=? AND reply_draft_request<>''
                            AND reply_draft_state='requested' AND reply_draft_sent_at IS NULL
                        """, [now, request])
                    if (try db.query("SELECT changes()") { DB.int($0, 0) }.first ?? 0) > 0 { draftClockStarted = true }
                }
            } catch {
                activity("outbox", .error, "Could not mark an outbox item sent", detail: "\(error)", trace: id)
            }
        }
        if draftClockStarted { reload() }
    }

    /// attempts + 1; retry after min(3600, 30 * 2^(attempts-1)) seconds.
    public func markFailed(_ uuids: [String], error message: String, now: Date, log: Bool = true) {
        for id in uuids {
            do {
                let prev = try db.query("SELECT attempts FROM outbox WHERE uuid=?", [id]) { DB.int($0, 0) }.first ?? 0
                let attempts = Int(prev) + 1
                let delay = min(3600.0, 30.0 * pow(2.0, Double(min(attempts - 1, 20))))
                try db.run("UPDATE outbox SET attempts=?, next_try=?, last_error=? WHERE uuid=?",
                           [attempts, now.addingTimeInterval(delay), message, id])
                if log {
                    activity("outbox", .warning, "Delivery failed (attempt \(attempts)); retry in \(Int(delay)) s",
                             detail: message, trace: id)
                }
            } catch { activity("outbox", .error, "Could not record a failed delivery", detail: "\(error)", trace: id) }
        }
    }

    /// The network is back: rows waiting out a back-off are due now, so sending resumes at once instead of up to an
    /// hour later. Returns how many rows were made due (logged once when any were).
    @discardableResult
    public func retryOutboxNow(now: Date) -> Int {
        do {
            try db.run("UPDATE outbox SET next_try=? WHERE sent IS NULL AND detached=0 AND next_try>?", [now, now])
            let n = Int(try db.query("SELECT changes()") { DB.int($0, 0) }.first ?? 0)
            if n > 0 { activity("outbox", .info, "Network is back: \(n) queued change\(n == 1 ? "" : "s") will be sent now") }
            return n
        } catch {
            activity("outbox", .error, "Could not reset the outbox back-off after the network came back", detail: "\(error)")
            return 0
        }
    }

    /// Marks rows as being sent (the request is on the wire) or no longer in flight. A change is never merged into a row
    /// in flight: the engine may already have its old payload.
    public func setOutboxInFlight(_ uuids: [String], _ inFlight: Bool) {
        if inFlight { outboxInFlight.formUnion(uuids) } else { outboxInFlight.subtract(uuids) }
    }

    nonisolated(unsafe) private static var reportedMeta = Set<Int64>()

    // MARK: Writing the queue (called inside Store.perform, so inside the board change's transaction)

    /// Done / deleted for a connector card. A verdict also writes a correction row.
    func queueOutbox(_ card: Card, kind: OutboxKind, verdict: String?, now: Date) throws {
        guard !card.connector.isEmpty else { return }
        let uuid = UUID().uuidString
        var payload = basePayload(card, now: now)
        if let verdict { payload["verdict"] = verdict }
        let reason = try insertOutbox(uuid, card.connector, kind, payload, now)
        if let verdict {
            try insertCorrection(uuid, card, verdict: verdict, detail: "", now: now)
        }
        activity("outbox", .info, reason.map { Self.detachedNote(reason: $0) } ?? "Queued \(kind.rawValue) for \(card.connector)", trace: uuid)
    }

    /// Group / importance / title / due change on a connector card. Changes within 5 s of the pending one
    /// collapse into it (first state -> latest state); a change back to the original removes it. Only a row that was
    /// never tried and isn't being sent right now is merged into; otherwise the change gets its own row.
    func queueChange(old: Card, new: Card, now: Date) throws {
        guard !old.connector.isEmpty else { return }
        let allPending = try db.query("""
            SELECT uuid,payload_json FROM outbox
            WHERE connector=? AND kind='changed' AND sent IS NULL AND detached=0 AND attempts=0 ORDER BY created DESC, rowid DESC
            """, [old.connector]) { s -> (String, [String: String]?) in
            do { return (DB.text(s, 0), try Self.decodePayload(DB.text(s, 1))) } catch { return (DB.text(s, 0), nil) }
        }.filter { !outboxInFlight.contains($0.0) }   // only rows never sent: the engine may already hold a tried or in-flight one
        // A pending change that can't be read is left exactly as it is; this change gets its own row.
        for p in allPending where p.1 == nil {
            activity("outbox", .warning, "A pending change can't be read; it was left untouched and this change is queued separately", trace: p.0)
        }
        let pending = allPending
            .compactMap { p in p.1.map { (p.0, $0) } }
            .first { p in
                p.1["card_id"] == String(old.id)
                    && abs(now.timeIntervalSince(Date(timeIntervalSince1970: Double(p.1["last_at"] ?? "") ?? 0))) <= 5
            }
        let base: (area: String, imp: String, title: String, due: Date?)
        if let p = pending?.1 {
            base = (p["from_area"] ?? old.area, p["from_importance"] ?? old.importance.title,
                    p["from_title"] ?? old.title, Double(p["from_due"] ?? "").map { Date(timeIntervalSince1970: $0) })
        } else {
            base = (old.area, old.importance.title, old.title, old.due)
        }
        var parts: [String] = []
        if base.area != new.area { parts.append("group: \(base.area) → \(new.area)") }
        if base.imp != new.importance.title { parts.append("importance: \(base.imp) → \(new.importance.title)") }
        if base.title != new.title { parts.append("title: \(base.title) → \(new.title)") }
        if base.due != new.due {
            let f = { (d: Date?) in d.map { Fmt.due($0) } ?? "none" }
            parts.append("due: \(f(base.due)) → \(f(new.due))")
        }
        if parts.isEmpty {
            if let id = pending?.0 {
                try db.run("DELETE FROM outbox WHERE uuid=?", [id])
                try db.run("DELETE FROM corrections WHERE uuid=?", [id])
                activity("outbox", .info, "Change reverted before sending; dropped", trace: id)
            }
            return
        }
        let detail = parts.joined(separator: "; ")
        // Activity gets the same description with titles left out (a title can be email text).
        let safeDetail = parts.map { $0.hasPrefix("title:") ? "title changed" : $0 }.joined(separator: "; ")
        var payload = basePayload(old, now: now)
        payload["verdict"] = "changed"
        payload["detail"] = detail
        payload["card_id"] = String(old.id)
        payload["last_at"] = String(now.timeIntervalSince1970)
        payload["from_area"] = base.area; payload["from_importance"] = base.imp; payload["from_title"] = base.title
        payload["from_due"] = base.due.map { String($0.timeIntervalSince1970) } ?? ""
        if let id = pending?.0 {
            try db.run("UPDATE outbox SET payload_json=? WHERE uuid=?", [try Self.encodePayload(payload), id])
            try db.run("UPDATE corrections SET detail=?, at=? WHERE uuid=?", [detail, now, id])
            activity("outbox", .info, "Merged into pending change", detail: safeDetail, trace: id)
        } else {
            let id = UUID().uuidString
            let reason = try insertOutbox(id, old.connector, .changed, payload, now)
            try insertCorrection(id, old, verdict: "changed", detail: detail, now: now)
            activity("outbox", .info, reason.map { Self.detachedNote(reason: $0) } ?? "Queued changed for \(old.connector)", detail: safeDetail, trace: id)
        }
    }

    /// The card as currently stored (committed or earlier in this transaction), plus whether it is deleted.
    /// Callers' Card values may be stale, so writes derive from this.
    func currentCard(_ id: Int64) throws -> (card: Card, deleted: Bool)? {
        try db.query("""
            SELECT title,area,importance,due,status,connector,source_mid,source_sent,source_meta,deleted
            FROM cards WHERE id=?
            """, [id]) { s in
            let sent = sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : DB.text(s, 7)
            let mid = sqlite3_column_type(s, 6) == SQLITE_NULL ? nil : DB.text(s, 6)
            var meta: [String: String] = [:]
            let raw = DB.text(s, 8)
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    // Any value types are allowed in meta; only the text ones are carried (item_id is one).
                    guard let any = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw DBError.sql("not an object") }
                    for (k, v) in any { if let t = v as? String { meta[k] = t } }
                } catch {
                    if Self.reportedMeta.insert(id).inserted {
                        activity("outbox", .warning, "A task's saved details can't be read, so its engine id is missing from this change", detail: "task \(id): \(error)")
                    }
                }
            }
            let card = Card(id: id, title: DB.text(s, 0), notes: "", area: DB.text(s, 1),
                            importance: Importance(rawValue: Int(DB.int(s, 2))) ?? .medium, due: DB.date(s, 3),
                            status: Status(rawValue: DB.text(s, 4)) ?? .todo, created: Date(), started: nil, done: nil,
                            sourceMeta: meta, sourceKey: mid.map { SourceKey(messageID: $0, sentAt: sent ?? "") },
                            connector: DB.text(s, 5))
            return (card, DB.int(s, 9) == 1)
        }.first
    }

    private func basePayload(_ card: Card, now: Date) -> [String: String] {
        ["source_mid": card.sourceKey?.messageID ?? "", "source_sent": card.sourceKey?.sentAt ?? "",
         "item_id": card.sourceMeta["itemId"] ?? "", "verdict": "", "detail": "",
         "at": String(now.timeIntervalSince1970)]
    }

    /// What the Activity row says about a row stored detached: 'no_connector' (no connector row yet) or 'removed'.
    public static func detachedNote(reason: String) -> String {
        reason == "removed" ? "Change kept but not sent — connector removed"
            : "Change kept — it will be sent once the connector is set up"
    }

    /// Returns nil when the row was queued normally, otherwise why it was stored detached: kept for the record but never
    /// sent. 'removed' when the user removed that connector earlier (a later connector with the same id may be a different
    /// engine); 'no_connector' when no connector row exists yet.
    @discardableResult
    func insertOutbox(_ uuid: String, _ connector: String, _ kind: OutboxKind,
                      _ payload: [String: String], _ now: Date) throws -> String? {
        let exists = (try db.query("SELECT count(*) FROM connectors WHERE id=?", [connector]) { DB.int($0, 0) }.first ?? 0) > 0
        var reason = ""
        if !exists {
            let removed = try db.query("SELECT count(*) FROM meta WHERE key=?", ["user_removed:\(connector)"]) { DB.int($0, 0) }.first ?? 0
            reason = removed > 0 ? "removed" : "no_connector"
        }
        try db.run("INSERT INTO outbox(uuid,connector,kind,payload_json,created,attempts,next_try,detached,detach_reason) VALUES(?,?,?,?,?,0,?,?,?)",
                   [uuid, connector, kind.rawValue, try Self.encodePayload(payload), now, now, exists ? 0 : 1, reason])
        return exists ? nil : reason
    }

    private func insertCorrection(_ uuid: String, _ card: Card, verdict: String, detail: String, now: Date) throws {
        let proposal = try db.query("SELECT proposal_json FROM cards WHERE id=?", [card.id]) { DB.text($0, 0) }.first ?? ""
        try db.run("INSERT INTO corrections(uuid,connector,source_mid,source_sent,proposed_json,verdict,detail,at) VALUES(?,?,?,?,?,?,?,?)",
                   [uuid, card.connector, card.sourceKey?.messageID ?? "", card.sourceKey?.sentAt ?? "",
                    proposal, verdict, detail, now])
    }

    /// Throws rather than queueing an empty change: the whole board change then rolls back and is logged.
    private static func encodePayload(_ p: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: p, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decodePayload(_ s: String) throws -> [String: String] {
        guard let d = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String] else {
            throw DBError.sql("queued change is not a list of text values")
        }
        return d
    }
}
