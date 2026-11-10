import Foundation
import SQLite3

/// Turns a connector's proposals into board state. The AI proposes; this decides, with fixed rules and no
/// randomness: the same proposals on the same board always give the same result.
/// Everything one `apply` does happens in a single transaction. Changes are attributed to the connector,
/// so they never count as the user touching a card and never queue outbox rows.
public enum Reconciler {
    /// "YYYY-MM-DD" -> 00:00 that day (the board's "no time" convention); "YYYY-MM-DDTHH:mm" -> that wall-clock time.
    /// Both are read in `zone`, the device's time zone unless given (the engine is told the same zone). Nil if invalid.
    public static func parseDue(_ s: String, in zone: TimeZone = .current) -> Date? {
        let parts = s.split(separator: "T", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        let ymd = parts[0].split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard ymd.count == 3, parts[0].split(separator: "-").count == 3 else { return nil }
        var hm = [0, 0]
        if parts.count == 2 {
            let t = parts[1].split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard t.count == 2, parts[1].split(separator: ":").count == 2 else { return nil }
            hm = t
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let comps = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: hm[0], minute: hm[1])
        guard let d = cal.date(from: comps) else { return nil }
        // Reject rolled-over values such as 2026-02-30 or 25:00.
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        guard back.year == ymd[0], back.month == ymd[1], back.day == ymd[2], back.hour == hm[0], back.minute == hm[1] else { return nil }
        return d
    }

    private struct Row {
        var id: Int64, title: String, area: String, importance: Int, due: Date?, deleted: Bool, withdrawn: Bool
        var sent: String?, proposalJSON: String, sourceLink: String, metaJSON: String, aiSummary: String
    }

    /// Decodes an engine batch (a JSON array). A proposal missing a required field is rejected with an Activity
    /// warning naming the field; the others are returned. Throws only if the data is not a JSON array at all.
    @MainActor
    public static func decodeBatch(_ data: Data, store: Store) throws -> [Proposal] {
        var out: [Proposal] = []
        for item in try JSONDecoder().decode([LossyProposal].self, from: data) {
            switch item.result {
            case .success(let p): out.append(p)
            case .failure(let e):
                store.activity("reconciler", .warning, "Proposal rejected: \(Proposal.describe(e))", detail: "\(e)", trace: item.id)
            }
        }
        return out
    }

    @MainActor
    public static func apply(_ ps: [Proposal], connector: String, store: Store, defaultGroup: String,
                             autoAdd: Bool) throws -> ReconcileSummary {
        var sum = ReconcileSummary()
        var current: Proposal?
        do {
            try store.performThrowing {
                for p in ps {
                    current = p
                    try handle(p, connector: connector, store: store, defaultGroup: defaultGroup, autoAdd: autoAdd, sum: &sum)
                }
            }
        } catch {
            store.activity("reconciler", .error, "Reconcile failed; nothing was changed", detail: "\(error)", trace: current?.id)
            throw error
        }
        if sum.undatedSkipped > 0 {   // one line per page, not one per item
            store.activity("reconciler", .info, "\(sum.undatedSkipped) older suggestion\(sum.undatedSkipped == 1 ? "" : "s") without a send date had no matching task; not added")
        }
        return sum
    }

    // MARK: One proposal

    @MainActor
    private static func handle(_ p: Proposal, connector: String, store: Store, defaultGroup: String,
                               autoAdd: Bool, sum: inout ReconcileSummary) throws {
        let actor = Actor.connector(connector)
        let now = Date()
        func info(_ m: String, _ level: ActivityLevel = .info) { store.activity("reconciler", level, m, trace: p.id) }   // never the title: Activity must be safe to share

        if p.kind == .learned {
            guard let text = p.learned else { info("Learned ignored: proposal has no learned text", .warning); return }
            do {
                if try store.applyLearned(connector: connector, text: text, trace: p.id) { sum.learnedUpdates += 1 }
            } catch ConnectorRecordError.unreadableStored {
                info("Learned update skipped: the connector's saved settings can't be read", .warning)
            }
            return
        }
        if p.kind == .correction {
            guard let key = p.sourceKey else { info("Correction ignored: no source key", .warning); return }
            let exists = try store.db.query("SELECT count(*) FROM corrections WHERE uuid=?", [p.id]) { DB.int($0, 0) }.first ?? 0
            if exists > 0 { sum.skippedExisting += 1; return }
            let at = ISO8601DateFormatter().date(from: p.provenance.created) ?? now
            try store.db.run("""
                INSERT INTO corrections(uuid,connector,source_mid,source_sent,proposed_json,verdict,detail,at) VALUES(?,?,?,?,?,?,?,?)
                """, [p.id, connector, key.messageID, key.sentAt, json(p), "missed_action", p.summary ?? "", at])
            sum.corrections += 1
            info("Learned from a missed email")
            return
        }
        let row = try find(p, connector: connector, store: store, now: now)

        switch p.kind {
        case .learned: break
        case .task:
            guard let key = p.sourceKey else { info("Ignored task without a source key", .warning); return }
            if key.undated {
                // From before the engine recorded send dates: the card (if any) came from the old app; leave it as it is.
                if row != nil { sum.skippedExisting += 1 } else { sum.undatedSkipped += 1 }
                return
            }
            guard let row else {
                let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { info("Ignored task with an empty title", .warning); return }
                guard autoAdd else { info("Not added (auto-add is off)"); return }
                let newID = try store.insertConnectorCard(
                    connector: connector, title: title, area: area(p, store, defaultGroup), importance: min(max(p.importance, 0), 2),
                    due: dueValue(p, info).date, externalID: "\(connector):\(key.messageID)", sourceKey: (key.messageID, key.sentAt),
                    sourceLink: p.link, metaJSON: try meta(p, merging: [:]), proposalJSON: try json(p),
                    aiSummary: (p.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines), now: now)
                sum.added += 1
                info("Added card #\(newID)")
                return
            }
            if row.deleted { sum.skippedExisting += 1; return }
            // Notes the connector sends with a task (its links, a meeting's notes) fill an empty AI section once; never overwritten.
            let note = (p.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if row.aiSummary.isEmpty && !note.isEmpty {
                try store.appendAISummary(cardID: row.id, text: note, actor: actor, kind: "notes added by connector")
            }
            let parsedDue = dueValue(p, info)
            let newDue = parsedDue.invalid ? row.due : parsedDue.date   // unreadable due: keep what the card has
            let newArea = area(p, store, defaultGroup), imp = min(max(p.importance, 0), 2)
            let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let (oldMeta, metaUnreadable) = metaDict(row.metaJSON)
            if metaUnreadable { info("A task's saved details can't be read; they are kept as they are (\"unreadable_meta\")", .warning) }
            let newMeta = try meta(p, merging: oldMeta)
            let oldWhy = oldMeta["why"] as? String
            var changed: [String] = []
            if !title.isEmpty && title != row.title { changed.append("title") }
            if newArea != row.area { changed.append("group") }
            if imp != row.importance { changed.append("importance") }
            if newDue != row.due { changed.append("due") }
            if oldWhy != p.why { changed.append("why") }
            if p.link != row.sourceLink { changed.append("link") }
            if store.isTouched(row.id) {
                sum.keptTouched += 1
                if !changed.isEmpty { try recordIgnored(row.id, actor, store, now) }
                return
            }
            let restore = row.withdrawn
            if changed.isEmpty && !restore { sum.skippedExisting += 1; return }
            try store.db.run("""
                UPDATE cards SET withdrawn=0, title=?, area=?, importance=?, due=?, source_link=?, source_meta=?, proposal_json=?, updated=? WHERE id=?
                """, [title.isEmpty ? row.title : title, newArea, imp, newDue, p.link, newMeta, json(p), now, row.id])
            if restore { try store.insertEvent(row.id, "restored by connector", actor: actor, at: now) }
            if !changed.isEmpty || !restore { try store.insertEvent(row.id, "refreshed by connector" + (changed.isEmpty ? "" : ": " + changed.joined(separator: ", ")),
                                  actor: actor, at: now) }
            sum.refreshed += 1
            info("Refreshed card #\(row.id)")
        case .withdraw:
            guard let row else { info("Withdraw ignored: no matching card", .info); return }
            if row.deleted || row.withdrawn { sum.skippedExisting += 1; return }
            if store.isTouched(row.id) {
                sum.keptTouched += 1
                try recordIgnored(row.id, actor, store, now)
                return
            }
            try store.db.run("UPDATE cards SET withdrawn=1, updated=? WHERE id=?", [now, row.id])
            try store.insertEvent(row.id, "withdrawn by connector", actor: actor, at: now)
            sum.withdrawn += 1
            info("Withdrawn card #\(row.id)")
        case .summary:
            let text = (p.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let row, !text.isEmpty else { info("Meeting notes not attached: no linked card"); return }
            let tag = "AI summary appended [\(p.id)]"
            let done = try store.db.query("SELECT count(*) FROM events WHERE card_id=? AND kind=?", [row.id, tag]) { DB.int($0, 0) }.first ?? 0
            if row.deleted || done > 0 { sum.skippedExisting += 1; return }
            try store.appendAISummary(cardID: row.id, text: text, actor: actor, kind: tag)
            sum.summaries += 1
            info("Summary added to card #\(row.id)")
        case .correction: break // handled before matching
        case .draft:
            try applyDraft(p, row: row, connector: connector, store: store, now: now, sum: &sum)
        }
    }

    /// A reply draft result. Applied only to the card's current request (an older request's answer is ignored), even
    /// when that request already timed out: a late answer still counts. Activity never gets the subject or the Notes.
    @MainActor
    private static func applyDraft(_ p: Proposal, row: Row?, connector: String, store: Store, now: Date,
                                   sum: inout ReconcileSummary) throws {
        func log(_ m: String, _ level: ActivityLevel = .info, detail: String? = nil) {
            store.activity("reconciler", level, m, detail: detail, trace: p.id)
        }
        guard let row else { log("Reply draft result ignored: no matching card"); return }
        guard let cur = try store.db.query("""
            SELECT reply_draft_request, reply_draft_state, reply_draft_link, reply_draft_error FROM cards WHERE id=?
            """, [row.id], { (request: DB.text($0, 0), state: DB.text($0, 1), link: DB.text($0, 2), error: DB.text($0, 3)) }).first,
              !cur.request.isEmpty, p.taskRef == cur.request else {
            sum.skippedExisting += 1
            log("Reply draft result for an older request ignored (card #\(row.id))")
            return
        }
        let why = p.why.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = p.link.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = why.isEmpty && link.isEmpty ? "No link to the draft came back" : why
        let state: ReplyDraftState = error.isEmpty ? .ready : .failed
        if cur.state == state.rawValue && (state == .ready ? cur.link == link && cur.error.isEmpty : cur.error == error) {
            sum.skippedExisting += 1   // the same answer delivered again
            return
        }
        if state == .ready {
            try store.db.run("UPDATE cards SET reply_draft_state='ready', reply_draft_link=?, reply_draft_error='', updated=? WHERE id=?",
                             [link, now, row.id])
            try store.insertEvent(row.id, "Reply draft ready", actor: .connector(connector), at: now)
            log("Reply draft ready for card #\(row.id)")
        } else {
            try store.db.run("UPDATE cards SET reply_draft_state='failed', reply_draft_error=?, updated=? WHERE id=?",
                             [error, now, row.id])
            try store.insertEvent(row.id, "Reply draft failed", actor: .connector(connector), at: now)
            log("Reply draft failed for card #\(row.id)", .warning, detail: error)
        }
        sum.drafts += 1
    }

    /// One history row per ignored update, not one per sync.
    @MainActor
    private static func recordIgnored(_ id: Int64, _ actor: Actor, _ store: Store, _ now: Date) throws {
        let kind = "update ignored (you changed this card)"
        let last = try store.db.query("SELECT kind FROM events WHERE card_id=? AND actor<>'user' ORDER BY id DESC LIMIT 1", [id]) { DB.text($0, 0) }.first
        if last != kind { try store.insertEvent(id, kind, actor: actor, at: now) }
    }

    // MARK: Helpers

    /// The card a proposal is about, in any state (deleted included). Legacy cards with no sent date match on
    /// message id alone and get their sent date filled in.
    @MainActor
    private static func find(_ p: Proposal, connector: String, store: Store, now: Date) throws -> Row? {
        let cols = "id,title,area,importance,due,deleted,withdrawn,source_sent,proposal_json,source_link,source_meta,ai_summary"
        func rows(_ sql: String, _ args: [Any?]) throws -> [Row] {
            try store.db.query("SELECT \(cols) FROM cards WHERE \(sql) ORDER BY id", args) { s in
                Row(id: DB.int(s, 0), title: DB.text(s, 1), area: DB.text(s, 2), importance: Int(DB.int(s, 3)), due: DB.date(s, 4),
                    deleted: DB.int(s, 5) != 0, withdrawn: DB.int(s, 6) != 0,
                    sent: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : DB.text(s, 7), proposalJSON: DB.text(s, 8),
                    sourceLink: DB.text(s, 9), metaJSON: DB.text(s, 10), aiSummary: DB.text(s, 11))
            }
        }
        if p.kind == .summary || p.kind == .withdraw || p.sourceKey == nil, let ref = p.taskRef, ref.hasPrefix("card:"),
           let id = Int64(ref.dropFirst(5)), let r = try rows("id=? AND connector=?", [id, connector]).first {
            return r
        }
        guard let key = p.sourceKey else { return nil }
        let all = try rows("connector=? AND source_mid=?", [connector, key.messageID])
        if key.undated { return all.first(where: { $0.sent == nil }) ?? all.first }   // message id alone; nothing filled in
        if let exact = all.first(where: { $0.sent == key.sentAt }) { return exact }
        guard var legacy = all.first(where: { $0.sent == nil }) else { return nil }
        try store.db.run("UPDATE cards SET source_sent=? WHERE id=?", [key.sentAt, legacy.id])
        try store.insertEvent(legacy.id, "source date filled in", actor: .connector(connector), at: now)
        legacy.sent = key.sentAt
        return legacy
    }

    /// Group by case-insensitive name; unknown or missing groups use the default.
    @MainActor
    private static func area(_ p: Proposal, _ store: Store, _ defaultGroup: String) -> String {
        if let g = p.group, let hit = store.areas.first(where: { $0.name.caseInsensitiveCompare(g) == .orderedSame }) { return hit.name }
        return store.resolve(defaultGroup)
    }

    private static func dueValue(_ p: Proposal, _ info: (String, ActivityLevel) -> Void) -> (date: Date?, invalid: Bool) {
        guard let s = p.due, !s.isEmpty else { return (nil, false) }
        if let d = parseDue(s) { return (d, false) }
        info("Ignored unreadable due date \"\(s)\"", .warning)
        return (nil, true)
    }

    private static func json(_ p: Proposal) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(p), as: UTF8.self)
    }

    /// Existing meta as a dictionary. Meta that can't be read is kept verbatim under "unreadable_meta", never dropped.
    private static func metaDict(_ json: String) -> (meta: [String: Any], unreadable: Bool) {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ([:], false) }
        do {
            if let d = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { return (d, false) }
        } catch {}
        return (["unreadable_meta": json], true)
    }

    /// Existing meta (any value types) with the proposal's why / source label set; no other key is touched.
    private static func meta(_ p: Proposal, merging existing: [String: Any]) throws -> String {
        var m = existing
        m["why"] = p.why
        m["source_label"] = p.sourceLabel
        return String(decoding: try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]), as: UTF8.self)
    }
}
