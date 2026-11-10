import Foundation
import Combine
import SQLite3

/// All reads and writes go through here; every change is written to SQLite immediately
/// and logged in the `events` table so there's a full history of what happened when.
@MainActor
public final class Store: ObservableObject {
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var areas: [Category] = []
    /// Online connectors (Connectors tab); reloaded with the board.
    @Published public private(set) var connectors: [ConnectorInfo] = []
    @Published public var lastError: String?
    /// What the health watchdog last found (set by `Health.refresh`); the bar warning reads this and nothing else.
    @Published public internal(set) var healthProblems: [HealthProblem] = []
    public let db: DB
    /// Activity rows logged while a transaction is open; written after it ends so a rollback can't erase them.
    var txOpen = false
    var txActivity: [(Date, String, ActivityLevel, String, String?, String?)] = []
    /// Outbox rows whose send request is on the wire (set by the connector sync around the request).
    var outboxInFlight = Set<String>()

    public init(db: DB) {
        self.db = db
        pruneActivity()
        detachUnreadableOutbox()
        seedAreas()
        reload()
    }

    public func reload() {
        do {
            areas = try db.query("SELECT id,name,color,position FROM areas ORDER BY position, id") { s in
                Category(id: DB.int(s, 0), name: DB.text(s, 1), colorHex: DB.text(s, 2),
                         position: sqlite3_column_double(s, 3))
            }
            cards = try db.query("""
                SELECT id,title,notes,area,importance,due,status,created,started,done,link,gcal_account,gcal_link,
                       source,external_id,source_link,source_meta,imported_at,
                       source_mid,source_sent,withdrawn,ai_summary,connector,
                       reply_draft_state,reply_draft_link,reply_draft_error,reply_draft_request,reply_draft_sent_at
                FROM cards WHERE deleted=0 ORDER BY created
                """) { s in
                Card(
                    id: DB.int(s, 0),
                    title: DB.text(s, 1),
                    notes: DB.text(s, 2),
                    area: DB.text(s, 3),
                    importance: Importance(rawValue: Int(DB.int(s, 4))) ?? .medium,
                    due: DB.date(s, 5),
                    status: Status(rawValue: DB.text(s, 6)) ?? .todo,
                    created: DB.date(s, 7) ?? Date(),
                    started: DB.date(s, 8),
                    done: DB.date(s, 9),
                    link: DB.text(s, 10),
                    gcalAccount: DB.text(s, 11),
                    gcalLink: DB.text(s, 12),
                    source: DB.text(s, 13),
                    externalID: DB.text(s, 14),
                    sourceLink: DB.text(s, 15),
                    sourceMeta: Self.decodeMeta(DB.text(s, 16)),
                    importedAt: DB.date(s, 17),
                    sourceKey: sqlite3_column_type(s, 18) == SQLITE_NULL ? nil
                        : SourceKey(messageID: DB.text(s, 18), sentAt: DB.text(s, 19)),
                    withdrawn: DB.int(s, 20) != 0,
                    aiSummary: DB.text(s, 21),
                    connector: DB.text(s, 22),
                    replyDraftState: ReplyDraftState(rawValue: DB.text(s, 23)),
                    replyDraftLink: DB.text(s, 24),
                    replyDraftError: DB.text(s, 25),
                    replyDraftRequest: DB.text(s, 26),
                    replyDraftSentAt: DB.date(s, 27)
                )
            }
        } catch {
            lastError = "\(error)"
            activity("store", .error, "Could not read the board", detail: "\(error)")
        }
        do { connectors = try loadConnectors() } catch {
            activity("store", .error, "Could not read the connectors list", detail: "\(error)")
        }
    }

    // MARK: Views of the data

    /// Open tasks (To do, Doing, Watch). Order: tasks with a due date first (soonest first),
    /// then Doing, then the rest; ties broken by importance, then oldest first.
    public var active: [Card] {
        cards.filter { $0.status != .done && !$0.withdrawn }.sorted { a, b in
            switch (a.dueSortKey, b.dueSortKey) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.status != b.status { return a.status == .doing }
            if a.importance != b.importance { return a.importance.rawValue > b.importance.rawValue }
            return a.created < b.created
        }
    }

    public func cards(in status: Status) -> [Card] {
        if status == .done {
            return cards.filter { $0.status == .done && !$0.withdrawn }
                .sorted { ($0.done ?? .distantPast) > ($1.done ?? .distantPast) }
        }
        return active.filter { $0.status == status }
    }

    /// Cards a connector took off the board (restorable). Never shown on the board itself.
    public var withdrawnCards: [Card] { cards.filter(\.withdrawn).sorted { $0.created > $1.created } }

    public func card(_ id: Int64) -> Card? { cards.first { $0.id == id } }

    // MARK: Changes

    /// A new task of the user's, straight into any step (To do by default).
    public func add(title: String, area: String, importance: Importance, due: Date?, status: Status = .todo) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let now = Date()
        let started: Date? = status == .doing ? now : nil
        let done: Date? = status == .done ? now : nil
        perform {
            let id = try db.run(
                "INSERT INTO cards(title,area,importance,due,status,created,started,done,updated) VALUES(?,?,?,?,?,?,?,?,?)",
                [t, area, importance.rawValue, due, status.rawValue, now, started, done, now])
            try log(id, "created", nil, status, now)
        }
    }

    /// Decides from the stored row (read inside the transaction), never the caller's copy, so a stale card can't
    /// finish a task twice, record the wrong "from" status, or skip a move.
    public func move(_ card: Card, to status: Status, now: Date = Date()) {
        perform {
            guard let stored = try db.query("SELECT status, started FROM cards WHERE id=?", [card.id], { s in
                (Status(rawValue: DB.text(s, 0)) ?? .todo, DB.date(s, 1)) }).first, stored.0 != status else { return }
            var started = stored.1
            if status == .doing && started == nil { started = now }
            let done: Date? = status == .done ? now : nil
            try db.run("UPDATE cards SET status=?, started=?, done=?, updated=? WHERE id=?",
                       [status.rawValue, started, done, now, card.id])
            try log(card.id, "moved", stored.0, status, now)
            if status == .done, let cur = try currentCard(card.id) { try queueOutbox(cur.card, kind: .done, verdict: nil, now: now) }
        }
    }

    public func update(_ card: Card, now: Date = Date()) {
        perform {
            let old = try currentCard(card.id)?.card
            try db.run("UPDATE cards SET title=?, notes=?, area=?, importance=?, due=?, link=?, updated=? WHERE id=?",
                       [card.title, card.notes, card.area, card.importance.rawValue, card.due,
                        card.link.trimmingCharacters(in: .whitespaces), now, card.id])
            try log(card.id, "edited", nil, nil, now)
            if let old { var new = old; new.title = card.title; new.area = card.area; new.importance = card.importance; new.due = card.due
                try queueChange(old: old, new: new, now: now) }
        }
    }

    public func setImportance(_ card: Card, _ importance: Importance, now: Date = Date()) {
        perform {
            let old = try currentCard(card.id)?.card ?? card
            guard old.importance != importance else { return }
            var new = old; new.importance = importance
            try db.run("UPDATE cards SET importance=?, updated=? WHERE id=?", [importance.rawValue, now, card.id])
            try insertEvent(card.id, "importance: \(old.importance.title) → \(importance.title)", actor: .user, at: now)
            try queueChange(old: old, new: new, now: now)
        }
    }

    public func setArea(_ card: Card, _ area: String, now: Date = Date()) {
        perform {
            let old = try currentCard(card.id)?.card ?? card
            guard old.area != area else { return }
            var new = old; new.area = area
            try db.run("UPDATE cards SET area=?, updated=? WHERE id=?", [area, now, card.id])
            try insertEvent(card.id, "group: \(old.area) → \(area)", actor: .user, at: now)
            try queueChange(old: old, new: new, now: now)
        }
    }

    /// Soft delete: the row stays in the database (and in exports) for the record.
    public func delete(_ card: Card) { deleteCard(card, verdict: nil) }

    /// Soft delete. For a connector card this also queues the deletion (and, with a verdict of
    /// `not_action` / `wrong_details` / `duplicate`, a correction) in the same transaction. The engine learns from the
    /// first two; `duplicate` is only logged there.
    public func deleteCard(_ card: Card, verdict: String?, now: Date = Date()) {
        perform {
            guard let cur = try currentCard(card.id), !cur.deleted else { return }
            try db.run("UPDATE cards SET deleted=1, updated=? WHERE id=?", [now, card.id])
            try log(card.id, "deleted", cur.card.status, nil, now)
            try queueOutbox(cur.card, kind: .deleted, verdict: verdict, now: now)
        }
    }

    // MARK: Reply drafts

    /// How long a delivered request may go unanswered before the card shows it as failed.
    public static let replyDraftTimeout: TimeInterval = 600
    public static let replyDraftTimeoutMessage = "No answer from the engine yet"

    /// Asks the card's connector for a reply draft written from the card's Notes as they are now (save the card first).
    /// One transaction: the card becomes `requested` with this request's id (any earlier request's answer is then
    /// ignored), its error is cleared, a `draft_reply` outbox row is queued (sent when online, kept across restarts),
    /// and a history row is added. Returns the request id. Throws, changing nothing, when the card is gone, did not come
    /// from a connector, has empty Notes, or its connector was removed.
    @discardableResult
    public func requestReplyDraft(cardID: Int64, now: Date = Date()) throws -> String {
        let request = UUID().uuidString.lowercased()
        let outboxID = UUID().uuidString
        try performThrowing {
            guard let cur = try currentCard(cardID), !cur.deleted else { throw ReplyDraftRequestError.noCard }
            let card = cur.card
            guard !card.connector.isEmpty, let key = card.sourceKey else { throw ReplyDraftRequestError.noSource }
            let notes = (try db.query("SELECT notes FROM cards WHERE id=?", [cardID]) { DB.text($0, 0) }.first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { throw ReplyDraftRequestError.noNotes }
            try db.run("""
                UPDATE cards SET reply_draft_state='requested', reply_draft_error='', reply_draft_request=?, reply_draft_sent_at=NULL,
                    updated=? WHERE id=?
                """, [request, now, cardID])
            let payload = ["source_mid": key.messageID, "source_sent": key.sentAt, "item_id": card.sourceMeta["itemId"] ?? "",
                           "notes": notes, "request_id": request]
            // A press before the first one was ever tried replaces it (never a tried or in-flight row, as queueChange).
            let untried = try db.query("""
                SELECT uuid,payload_json FROM outbox WHERE connector=? AND kind=? AND sent IS NULL AND detached=0 AND attempts=0
                """, [card.connector, OutboxKind.draftReply.rawValue]) { (DB.text($0, 0), DB.text($0, 1)) }
            for (uuid, json) in untried where !outboxInFlight.contains(uuid) {
                let old = try? Self.decodePayload(json) // try?-ok: an unreadable pending row is simply left in place
                if old?["source_mid"] == key.messageID && (old?["source_sent"] ?? "") == (key.sentAt ?? "") {
                    try db.run("DELETE FROM outbox WHERE uuid=?", [uuid])
                }
            }
            if try insertOutbox(outboxID, card.connector, .draftReply, payload, now) != nil {
                throw ReplyDraftRequestError.noConnector   // never sent, so it would never be answered
            }
            try insertEvent(cardID, "Reply draft requested", actor: .user, at: now)
            activity("outbox", .info, "Reply draft requested for card #\(cardID)", trace: outboxID)
        }
        return request
    }

    /// Connectors with a delivered reply draft request still waiting for its answer (not yet timed out: see
    /// `expireReplyDrafts`). While a connector is listed, the app syncs it often so the answer shows in seconds.
    public func connectorsAwaitingReplyDrafts() -> Set<String> {
        do {
            return Set(try db.query("""
                SELECT DISTINCT connector FROM cards WHERE reply_draft_state='requested' AND reply_draft_sent_at IS NOT NULL
                    AND deleted=0 AND connector<>''
                """) { DB.text($0, 0) })
        } catch {
            activity("store", .error, "Could not check for reply drafts waiting for an answer", detail: "\(error)")
            return []
        }
    }

    /// Requests delivered more than `replyDraftTimeout` ago with no answer become failed. Requests still waiting to
    /// be sent (offline) never time out. A late answer for the current request still turns the card ready.
    public func expireReplyDrafts(now: Date = Date()) {
        do {
            let due = try db.query("""
                SELECT id, connector FROM cards WHERE reply_draft_state='requested' AND reply_draft_sent_at IS NOT NULL
                    AND reply_draft_sent_at < ?
                """, [now.addingTimeInterval(-Self.replyDraftTimeout)]) { (DB.int($0, 0), DB.text($0, 1)) }
            guard !due.isEmpty else { return }
            try performThrowing {
                for (id, connector) in due {
                    try db.run("UPDATE cards SET reply_draft_state='failed', reply_draft_error=?, updated=? WHERE id=? AND reply_draft_state='requested'",
                               [Self.replyDraftTimeoutMessage, now, id])
                    try insertEvent(id, "Reply draft failed", actor: connector.isEmpty ? .user : .connector(connector), at: now)
                    activity("store", .warning, "Reply draft for card #\(id) timed out", detail: Self.replyDraftTimeoutMessage)
                }
            }
        } catch {
            activity("store", .error, "Could not check reply drafts for a timeout", detail: "\(error)")
        }
    }

    // MARK: Connector cards

    private static func decodeMeta(_ s: String) -> [String: String] {
        // try?-ok: unreadable display meta just shows no extra details; the stored text is untouched
        (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: String]) ?? [:] // try?-ok: optional parsing of untrusted display data
    }

    /// The one place connector cards are inserted. Writes the card and its "created" history row, attributed to
    /// the connector. Must run inside a transaction.
    @discardableResult
    func insertConnectorCard(connector: String, title: String, area: String, importance: Int, due: Date?, externalID: String,
                             sourceKey: (mid: String, sent: String?)?, sourceLink: String, metaJSON: String,
                             proposalJSON: String, aiSummary: String = "", now: Date) throws -> Int64 {
        let id = try db.run("""
            INSERT INTO cards(title,area,importance,due,status,created,updated,source,external_id,source_link,source_meta,imported_at,
                              connector,source_mid,source_sent,proposal_json,ai_summary)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [title, area, importance, due, Status.todo.rawValue, now, now, connector, externalID, sourceLink, metaJSON, now,
                  connector, sourceKey?.mid, sourceKey?.sent, proposalJSON, aiSummary])
        try insertEvent(id, "created (from \(connector))", to: .todo, actor: .connector(connector), at: now)
        return id
    }

    /// Like `perform` but rethrows (for callers that must report failure) and returns the closure's value.
    /// Activity rows buffered inside are written after commit or rollback.
    func performThrowing<T>(_ work: () throws -> T) throws -> T {
        txOpen = true
        var out: T?
        do {
            try db.transaction { out = try work() }
        } catch {
            // Rolled back: keep warnings and errors, drop "done" info rows that describe writes that no longer exist.
            txActivity.removeAll { $0.2 == .info }
            txOpen = false; flushTxActivity(); reload()
            throw error
        }
        txOpen = false; flushTxActivity(); lastError = nil; reload()
        return out!
    }

    // MARK: Learned preferences

    /// What a connector has learned about the user's preferences (stored in connectors.settings_json["learned"]).
    public func learned(connector: String) -> String {
        do {
            return try learnedText(connector)
        } catch {
            activity("store", .error, "Could not read learned preferences", detail: "\(error)")
            return ""
        }
    }

    func learnedText(_ connector: String) throws -> String {
        let json = try db.query("SELECT settings_json FROM connectors WHERE id=?", [connector]) { DB.text($0, 0) }.first ?? ""
        return try Self.settingsDict(json, connector)["learned"] as? String ?? ""
    }

    /// Empty settings read as none; settings that exist but can't be read throw, so a write never replaces them.
    private static func settingsDict(_ json: String, _ connector: String) throws -> [String: Any] {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        do {
            if let d = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { return d }
        } catch {}
        throw ConnectorRecordError.unreadableStored(connector)
    }

    /// Stores the text, creating the connectors row if needed and keeping other settings keys.
    /// Returns true (and logs an Activity row) only when the text actually changed.
    @discardableResult
    public func setLearned(connector: String, text: String, trace: String? = nil) -> Bool {
        var changed = false
        perform { changed = try applyLearned(connector: connector, text: text, trace: trace) }
        return changed
    }

    /// Transaction-safe core of `setLearned`; logs "Learned: +added -removed" vs the previous text.
    func applyLearned(connector: String, text: String, trace: String?) throws -> Bool {
        // Version 0 means "never pushed" and would match a new engine's 0, so new rows start at 1.
        try db.run("INSERT OR IGNORE INTO connectors(id,name,settings_json,settings_version) VALUES(?,?,'{}',1)", [connector, connector])
        let json = try db.query("SELECT settings_json FROM connectors WHERE id=?", [connector]) { DB.text($0, 0) }.first ?? ""
        var dict = try Self.settingsDict(json, connector)
        let old = dict["learned"] as? String ?? ""
        guard old != text else { return false }
        dict["learned"] = text
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        // A new version: the next settings push carries this text, so an older local copy can never overwrite it.
        try db.run("UPDATE connectors SET settings_json=?, settings_version=settings_version+1 WHERE id=?",
                   [String(decoding: data, as: UTF8.self), connector])
        func lines(_ s: String) -> [String] { s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let (o, n) = (lines(old), lines(text))
        let diff = n.filter { !o.contains($0) }.map { "+" + $0 } + o.filter { !n.contains($0) }.map { "-" + $0 }
        activity("reconciler", .info, "Learned: " + (diff.isEmpty ? "(wording changed)" : diff.joined(separator: " ")),
                 detail: text, trace: trace)
        return true
    }

    /// Reads a JSON setting kept in UserDefaults. Data that can't be decoded is kept under `brokenKey` (not deleted),
    /// logged once, and removed from `key` so the caller falls back to defaults and the next save starts clean.
    public func loadJSONSetting<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String, brokenKey: String,
                                              what: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            // An earlier unreadable copy is never overwritten: later ones go under <brokenKey>.<time>, newest 3 in all kept.
            var target = brokenKey
            if defaults.object(forKey: brokenKey) != nil {
                var stamp = Int(Date().timeIntervalSince1970 * 1000)
                while defaults.object(forKey: "\(brokenKey).\(stamp)") != nil { stamp += 1 }
                target = "\(brokenKey).\(stamp)"
                let older = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(brokenKey + ".") }
                    .sorted { (Int($0.dropFirst(brokenKey.count + 1)) ?? 0) < (Int($1.dropFirst(brokenKey.count + 1)) ?? 0) }
                for k in older.dropLast(1) { defaults.removeObject(forKey: k) }   // leaves 1 + the new one + the first
            }
            defaults.set(data, forKey: target)
            defaults.removeObject(forKey: key)
            activity("settings", .warning, "Your saved \(what) could not be read, so the defaults are used",
                     detail: "the unreadable copy is kept under \(target); \(error)")
            return nil
        }
    }

    /// Append text to a card's AI summary (never its notes). No-op if the card doesn't exist.
    public func setAISummary(cardID: Int64, text: String, actor: Actor) {
        guard cards.contains(where: { $0.id == cardID }) else { return }
        perform { try appendAISummary(cardID: cardID, text: text, actor: actor) }
    }

    /// Transaction-safe core of `setAISummary`; reads the stored summary, not the cache.
    func appendAISummary(cardID: Int64, text: String, actor: Actor, kind: String = "AI summary appended") throws {
        let now = Date()
        let current = try db.query("SELECT ai_summary FROM cards WHERE id=?", [cardID]) { DB.text($0, 0) }.first ?? ""
        let summary = current.isEmpty ? text : current + "\n\n" + text
        try db.run("UPDATE cards SET ai_summary=?, updated=? WHERE id=?", [summary, now, cardID])
        try insertEvent(cardID, kind, actor: actor, at: now)
    }

    /// Record that a task is now in Google Calendar; keep the Meet link on the task if it got one.
    public func markInCalendar(_ card: Card, account: String, eventID: String, htmlLink: String, meetLink: String?) {
        let now = Date()
        perform {
            try db.run("UPDATE cards SET gcal_account=?, gcal_event=?, gcal_link=?, updated=? WHERE id=?",
                       [account, eventID, htmlLink, now, card.id])
            if let meet = meetLink, card.link.trimmingCharacters(in: .whitespaces).isEmpty {
                try db.run("UPDATE cards SET link=? WHERE id=?", [meet, card.id])
            }
            try insertEvent(card.id, "added to Google Calendar (\(account))", actor: .user, at: now)
        }
    }

    // MARK: Groups

    /// First run: create the starter groups, plus any group names already used by tasks.
    private func seedAreas() {
        do {
            let n = try db.query("SELECT count(*) FROM areas") { DB.int($0, 0) }.first ?? 0
            if n == 0 {
                for (i, (name, hex)) in [("Work", "#0A84FF"), ("Personal", "#30D158")].enumerated() {
                    try db.run("INSERT INTO areas(name,color,position) VALUES(?,?,?)", [name, hex, Double(i)])
                }
            }
            try db.run("INSERT OR IGNORE INTO areas(name,color,position) SELECT DISTINCT area, '#8E8E93', 1000 FROM cards")
        } catch {
            lastError = "\(error)"
            activity("store", .error, "Could not set up the groups", detail: "\(error)")
        }
    }

    /// A valid group name: the given one if it still exists, otherwise the first group.
    public func resolve(_ area: String) -> String {
        areas.contains { $0.name == area } ? area : (areas.first?.name ?? "Personal")
    }

    /// Next/previous group (wraps around), for ↑/↓ while typing.
    public func shift(_ area: String, by: Int) -> String {
        guard !areas.isEmpty else { return area }
        let i = areas.firstIndex { $0.name == area } ?? 0
        return areas[(i + by + areas.count * 2) % areas.count].name
    }

    public func taskCount(_ area: String) -> Int { cards.filter { $0.area == area }.count }

    private func nameTaken(_ name: String, except id: Int64? = nil) -> Bool {
        areas.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Returns an error message, or nil on success.
    @discardableResult
    public func addArea(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Give the group a name." }
        guard !nameTaken(name) else { return "There's already a group called \(name)." }
        let used = Set(areas.map { $0.colorHex })
        let hex = Palette.colors.first { !used.contains($0.hex) }?.hex ?? "#8E8E93"
        let pos = (areas.map(\.position).max() ?? -1) + 1
        perform {
            try db.run("INSERT INTO areas(name,color,position) VALUES(?,?,?)", [name, hex, pos])
            try groupsChanged(.added(name), now: Date())
        }
        return nil
    }

    /// Renames the group and every task in it.
    @discardableResult
    public func renameArea(_ area: Category, to raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != area.name else { return nil }
        guard !name.isEmpty else { return "A group needs a name." }
        guard !nameTaken(name, except: area.id) else { return "There's already a group called \(name)." }
        let now = Date()
        perform {
            try db.run("INSERT INTO events(card_id,at,kind,actor,uuid) SELECT id, ?, ?, 'user', lower(hex(randomblob(16))) FROM cards WHERE area=?",
                       [now, "group renamed: \(area.name) → \(name)", area.name])
            try db.run("UPDATE cards SET area=? WHERE area=?", [name, area.name])
            try db.run("UPDATE areas SET name=? WHERE id=?", [name, area.id])
            try groupsChanged(.renamed(area.name, name), now: now)
        }
        return nil
    }

    public func setColor(_ area: Category, _ hex: String) {
        perform { try db.run("UPDATE areas SET color=? WHERE id=?", [hex, area.id]) }
    }

    public func moveArea(_ area: Category, by: Int) {
        var list = areas
        guard let i = list.firstIndex(of: area) else { return }
        let j = i + by
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        perform {
            for (k, a) in list.enumerated() {
                try db.run("UPDATE areas SET position=? WHERE id=?", [Double(k), a.id])
            }
        }
    }

    /// Deletes a group, first moving its tasks (including finished and deleted ones) to another group.
    public func deleteArea(_ area: Category, moveTasksTo target: String) {
        guard areas.count > 1, target != area.name else { return }
        let now = Date()
        perform {
            try db.run("INSERT INTO events(card_id,at,kind,actor,uuid) SELECT id, ?, ?, 'user', lower(hex(randomblob(16))) FROM cards WHERE area=?",
                       [now, "group deleted: \(area.name) → moved to \(target)", area.name])
            try db.run("UPDATE cards SET area=? WHERE area=?", [target, area.name])
            try db.run("DELETE FROM areas WHERE id=?", [area.id])
            try groupsChanged(.deleted(area.name), now: now)
        }
    }

    private func log(_ id: Int64, _ kind: String, _ from: Status?, _ to: Status?, _ at: Date) throws {
        try insertEvent(id, kind, from: from, to: to, actor: .user, at: at)
    }

    func perform(_ work: () throws -> Void) {
        txOpen = true
        do { try db.transaction(work); txOpen = false; flushTxActivity(); lastError = nil } catch {
            txOpen = false; flushTxActivity()
            lastError = "\(error)"
            activity("store", .error, "Database write failed", detail: "\(error)")
        }
        reload()
    }

    /// TEST ONLY: runs one raw SQL statement through `perform` so checks can exercise the error path.
    public func performForTest(_ sql: String) { perform { try db.run(sql) } }
    /// TEST ONLY: runs arbitrary work through `perform`.
    public func performForTest(_ work: () throws -> Void) { perform(work) }

    // MARK: Export

    /// Writes two CSV files (cards, and every change event) to ~/Downloads.
    public func exportCSV() throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = Fmt.csvDate(Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "_")

        var rows = ["id,title,area,importance,status,created,started,done,due,deleted,notes,link,withdrawn"]
        rows += try db.query("SELECT id,title,area,importance,status,created,started,done,due,deleted,notes,link,withdrawn FROM cards ORDER BY id") { s in
            [String(DB.int(s, 0)), DB.text(s, 1), DB.text(s, 2),
             (Importance(rawValue: Int(DB.int(s, 3))) ?? .medium).title, DB.text(s, 4),
             Fmt.csvDate(DB.date(s, 5)), Fmt.csvDate(DB.date(s, 6)), Fmt.csvDate(DB.date(s, 7)),
             Fmt.csvDate(DB.date(s, 8)), DB.int(s, 9) == 1 ? "yes" : "", DB.text(s, 10), DB.text(s, 11),
             DB.int(s, 12) == 1 ? "yes" : ""]
                .map(Self.csvField).joined(separator: ",")
        }
        let cardsURL = downloads.appendingPathComponent("FloatBoard-cards-\(stamp).csv")
        try rows.joined(separator: "\n").write(to: cardsURL, atomically: true, encoding: .utf8)

        var ev = ["at,card_id,title,event,from,to"]
        ev += try db.query("""
            SELECT e.at,e.card_id,c.title,e.kind,e.from_status,e.to_status
            FROM events e JOIN cards c ON c.id=e.card_id ORDER BY e.at
            """) { s in
            [Fmt.csvDate(DB.date(s, 0)), String(DB.int(s, 1)), DB.text(s, 2),
             DB.text(s, 3), DB.text(s, 4), DB.text(s, 5)]
                .map(Self.csvField).joined(separator: ",")
        }
        try ev.joined(separator: "\n")
            .write(to: downloads.appendingPathComponent("FloatBoard-history-\(stamp).csv"), atomically: true, encoding: .utf8)
        return cardsURL
    }

    private static func csvField(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// Why a reply draft could not be requested. Texts are shown to the user as they are.
public enum ReplyDraftRequestError: Error, Equatable, CustomStringConvertible {
    case noCard, noSource, noNotes, noConnector
    public var description: String {
        switch self {
        case .noCard: "This task no longer exists."
        case .noSource: "Only tasks made from an email can get a reply draft."
        case .noNotes: "Write what to say in Notes first."
        case .noConnector: "This task's connector was removed, so a reply draft can't be requested."
        }
    }
}
