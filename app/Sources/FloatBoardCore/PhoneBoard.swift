import CryptoKit
import Foundation

/// One task in the copy of the board the engine keeps for the phone app (`PUT /v2/board`).
public struct BoardCard: Codable, Equatable {
    public var id: Int64
    public var title: String
    public var group: String
    public var color: String
    public var importance: Int
    /// All-day: "YYYY-MM-DD" (local day). Timed: ISO 8601 with the local offset.
    public var due: String?
    public var hasTime: Bool
    public var status: String
    public var link: String?
    public var doneAt: String?
    /// When this card's step last changed on this Mac (Mac clock, ISO 8601 UTC with milliseconds).
    public var statusAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, group, color, importance, due, hasTime = "has_time", status, link, doneAt = "done_at", statusAt = "status_at"
    }

    /// Every field is written, nil ones as null (the engine requires them all).
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(group, forKey: .group)
        try c.encode(color, forKey: .color); try c.encode(importance, forKey: .importance); try c.encode(due, forKey: .due)
        try c.encode(hasTime, forKey: .hasTime); try c.encode(status, forKey: .status); try c.encode(link, forKey: .link)
        try c.encode(doneAt, forKey: .doneAt); try c.encode(statusAt, forKey: .statusAt)
    }
}

/// One change made on the phone, waiting on the engine for the Mac (`GET /v2/phone-actions`).
public struct PhoneAction: Codable, Equatable {
    /// The engine's id for this action (acknowledge with this).
    public var id: String
    /// The phone's own id for the action (nil for rows stored before sync v2). Used to apply each action once.
    public var clientID: String?
    public var cardID: Int64?
    /// todo | doing | watch | done | add
    public var action: String
    public var title: String?
    public var group: String?
    /// When the action was made, on the engine's clock (nil when the engine did not say).
    public var madeAt: Date?

    public init(id: String, clientID: String? = nil, cardID: Int64?, action: String, title: String? = nil, group: String? = nil,
                madeAt: Date? = nil) {
        self.id = id; self.clientID = clientID; self.cardID = cardID; self.action = action; self.title = title; self.group = group
        self.madeAt = madeAt
    }

    /// The key that makes an action apply once: the phone's id when there is one, else the engine's.
    public var onceKey: String { clientID.flatMap { $0.isEmpty ? nil : $0 } ?? id }

    enum CodingKeys: String, CodingKey { case id, clientID = "client_id", cardID = "card_id", action, title, group, madeAt = "made_at" }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
        cardID = try c.decodeIfPresent(Int64.self, forKey: .cardID)
        action = try c.decode(String.self, forKey: .action)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        // An unreadable time counts as unknown (applied without the newest-change test), not as a broken action.
        madeAt = (try? c.decodeIfPresent(String.self, forKey: .madeAt)).flatMap { $0 }.flatMap(PhoneBoard.parseISO) // try?-ok: unreadable time is treated as unknown
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encodeIfPresent(clientID, forKey: .clientID); try c.encodeIfPresent(cardID, forKey: .cardID)
        try c.encode(action, forKey: .action); try c.encodeIfPresent(title, forKey: .title); try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(madeAt.map(PhoneBoard.isoUTC), forKey: .madeAt)
    }
}

/// What applying a list of phone actions decided: ids to acknowledge as applied, and ids not applied with the reason.
public struct PhoneApplyResult: Equatable {
    public var applied: [String] = []
    public var skipped: [PhoneSkip] = []
    public init() {}
    public var count: Int { applied.count + skipped.count }
}

public struct PhoneSkip: Equatable {
    public var id: String
    /// "superseded" (a newer change on this Mac won), "gone" (the task is no longer on the board), "invalid"
    public var reason: String
    public init(id: String, reason: String) { self.id = id; self.reason = reason }
}

/// Building the phone's board copy and applying what was done on the phone. Offline and deterministic.
public enum PhoneBoard {
    public static let maxCards = 500
    static let maxText = 200
    static let maxLink = 2000
    static let fallbackColor = "#8E8E93"
    /// How long applied phone action ids are remembered (the engine keeps acked rows about as long).
    public static let rememberApplied: TimeInterval = 7 * 86400

    /// Open tasks (board order) then tasks done today (local day, newest first), at most 500.
    /// Each card carries `status_at`: its last step change on this Mac (see `Store.lastStepChanges`).
    @MainActor
    public static func payload(store: Store, now: Date, calendar: Calendar = .current) -> [BoardCard] {
        let colors = Dictionary(store.areas.map { ($0.name, $0.colorHex) }, uniquingKeysWith: { a, _ in a })
        let open = store.active
        let doneToday = store.cards(in: .done).filter { c in c.done.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        let chosen = Array((open + doneToday).prefix(maxCards))
        let steps = store.lastStepChanges(chosen.map(\.id))
        return chosen.map { c in
            var b = card(for: c, color: colors[c.area], calendar: calendar)
            b.statusAt = isoUTC(steps[c.id] ?? c.created)
            return b
        }
    }

    static func card(for c: Card, color: String?, calendar: Calendar) -> BoardCard {
        let hex = color.flatMap { $0.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil ? $0 : nil } ?? fallbackColor
        let hasTime = c.due.map { Due.hasTime($0) } ?? false
        return BoardCard(id: c.id, title: clip(c.title), group: clip(c.area), color: hex, importance: c.importance.rawValue,
                         due: c.due.map { hasTime ? iso($0, calendar) : day($0, calendar) }, hasTime: hasTime,
                         status: c.status.rawValue, link: webLink(c.sourceLink) ?? webLink(c.link),
                         doneAt: c.status == .done ? c.done.map { iso($0, calendar) } : nil, statusAt: nil)
    }

    /// At most 200 UTF-16 units (what the engine counts), never splitting a character.
    public static func clip(_ s: String) -> String {
        var out = "", n = 0
        for ch in s {
            let w = ch.utf16.count
            if n + w > maxText { break }
            out.append(ch); n += w
        }
        return out
    }

    static func webLink(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= maxLink, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", !(u.host ?? "").isEmpty else { return nil }
        return s
    }

    static func day(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    static func iso(_ d: Date, _ cal: Calendar) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = cal.timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// UTC ISO 8601 with milliseconds, e.g. "2026-11-12T10:00:00.123Z" (the engine's own format).
    public static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Reads ISO 8601 with or without fractional seconds.
    public static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The body sent to the engine: `{"cards":[...], "sent_at": ...}` with sorted keys. Without `sentAt` (as for the
    /// hash), equal boards give equal bytes.
    public static func body(_ cards: [BoardCard], sentAt: Date? = nil) throws -> Data {
        struct Body: Encodable {
            let cards: [BoardCard]; let sentAt: String?
            enum CodingKeys: String, CodingKey { case cards, sentAt = "sent_at" }
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(Body(cards: cards, sentAt: sentAt.map(isoUTC)))
    }

    /// A stable fingerprint of the board for one engine address (a different engine always gets a push). It covers
    /// each card's `status_at`, so a step change is sent even when the card ends on the same step.
    public static func hash(_ cards: [BoardCard], engine: String) throws -> String {
        var data = Data(engine.utf8)
        data.append(0)
        data.append(try body(cards))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Store {
    static func boardHashKey(_ connector: String) -> String { "phone_board_hash:\(connector)" }
    static func appliedKey(_ connector: String, _ id: String) -> String { "phone_action:\(connector):\(id)" }

    /// How long a sent board counts as current: after this it is sent again even if unchanged (covers an engine that
    /// lost its copy).
    public static let boardResendInterval: TimeInterval = 3600

    /// The hash of the board last accepted by this connector's engine, or nil (also when it was sent over an hour ago).
    public func lastBoardHash(connector: String, now: Date = Date()) -> String? {
        do {
            guard let v = try db.query("SELECT value FROM meta WHERE key=?", [Self.boardHashKey(connector)]) { DB.text($0, 0) }.first
            else { return nil }
            let parts = v.split(separator: " ")
            guard parts.count == 2, let at = Double(parts[1]), now.timeIntervalSince1970 - at < Self.boardResendInterval else { return nil }
            return String(parts[0])
        } catch {
            activity("connector:\(connector)", .warning, "Could not read when the phone's board was last sent; sending it again", detail: "\(error)")
            return nil
        }
    }

    /// Records (or with nil forgets) the hash of the board the engine accepted.
    public func setLastBoardHash(_ hash: String?, connector: String, now: Date = Date()) {
        do {
            if let hash { try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                                     [Self.boardHashKey(connector), "\(hash) \(Int(now.timeIntervalSince1970))"]) }
            else { try db.run("DELETE FROM meta WHERE key=?", [Self.boardHashKey(connector)]) }
        } catch {
            activity("connector:\(connector)", .warning, "Could not record the phone's board as sent; it will be sent again", detail: "\(error)")
        }
    }

    /// History kinds that set a card's step: a move, the card being made, or the card coming back.
    static let stepKinds = "(kind = 'moved' OR kind LIKE 'created%' OR kind LIKE 'restored%')"

    /// When each card's step last changed on this Mac (latest 'moved' / 'created' / 'restored' history row). Cards with
    /// no such row are left out (callers use the card's created time).
    public func lastStepChanges(_ ids: [Int64]) -> [Int64: Date] {
        var out: [Int64: Date] = [:]
        do {
            for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try db.query("SELECT card_id, MAX(at) FROM events WHERE card_id IN (\(marks)) AND \(Self.stepKinds) GROUP BY card_id",
                                        chunk.map { $0 as Any? }) { (DB.int($0, 0), DB.date($0, 1)) }
                for (id, at) in rows { if let at { out[id] = at } }
            }
        } catch {
            activity("store", .warning, "Could not read when tasks last changed step; using their created times", detail: "\(error)")
        }
        return out
    }

    func lastStepChange(_ id: Int64) throws -> Date? {
        let at = try db.query("SELECT MAX(at) FROM events WHERE card_id=? AND \(Self.stepKinds)", [id]) { DB.date($0, 0) }.first ?? nil
        if let at { return at }
        return try db.query("SELECT created FROM cards WHERE id=?", [id]) { DB.date($0, 0) }.first ?? nil
    }

    /// Two times this close count as equal (the engine keeps milliseconds); ties go to the phone.
    static let sameTime: TimeInterval = 0.001

    /// Applies changes made on the phone, newest change wins. `engineAhead` is how far the engine's clock is ahead of
    /// this Mac's (server_time minus the Mac's time when the answer arrived); an action's `madeAt` minus it is its time
    /// on this Mac. A move is applied only when it is at least as new as the card's last step change here; else it is
    /// skipped as "superseded" (a move to the step the card is already on is simply acknowledged). A move applied
    /// here is recorded at its own time (not the apply time), so a later phone move in the same batch still wins.
    /// Moves are made as the user (so a connector card moved to Done still tells its engine); `add` makes a To do task
    /// (medium, no due) in the named group, or the first group. Each action applies once (by the phone's id), also when
    /// it arrives again before the ack reached the engine (remembered for 7 days). Unknown or deleted cards are skipped
    /// as "gone". Activity never carries task titles.
    @discardableResult
    public func applyPhoneActions(_ actions: [PhoneAction], connector: String, now: Date = Date(),
                                  engineAhead: TimeInterval = 0) -> PhoneApplyResult {
        let component = "connector:\(connector)"
        var result = PhoneApplyResult()
        var moved = 0, added = 0, repeated = 0, superseded = 0
        var unknown: [String] = []
        do {
            try db.run("DELETE FROM meta WHERE key LIKE ? AND CAST(value AS REAL) < ?",
                       ["phone_action:\(connector):%", (now.addingTimeInterval(-PhoneBoard.rememberApplied)).timeIntervalSince1970])
        } catch {
            activity(component, .warning, "Could not clear old phone action records", detail: "\(error)")
        }
        for a in actions {
            let key = Self.appliedKey(connector, a.onceKey)
            let madeHere = a.madeAt.map { $0.addingTimeInterval(-engineAhead) }
            do {
                var outcome = "skip"
                try performThrowing {
                    if try db.query("SELECT 1 FROM meta WHERE key=?", [key], { DB.int($0, 0) }).first != nil { outcome = "repeat"; return }
                    if a.action == "add" {
                        let title = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if title.isEmpty { outcome = "bad"; return }
                        let group = areas.contains { $0.name == a.group } ? a.group! : (areas.first?.name ?? "Personal")
                        let id = try db.run(
                            "INSERT INTO cards(title,area,importance,due,status,created,updated) VALUES(?,?,?,?,?,?,?)",
                            [PhoneBoard.clip(title), group, Importance.medium.rawValue, nil, Status.todo.rawValue, now, now])
                        try insertEvent(id, "created (from the phone)", to: .todo, actor: .user, at: now)
                        outcome = "added"
                    } else if let status = Status(rawValue: a.action), let cardID = a.cardID {
                        let row = try db.query("SELECT deleted, withdrawn, status FROM cards WHERE id=?", [cardID]) {
                            (DB.int($0, 0), DB.int($0, 1), DB.text($0, 2)) }.first
                        guard let row, row.0 == 0, row.1 == 0 else { outcome = "unknown"; return }
                        let last = try lastStepChange(cardID)
                        if row.2 != status.rawValue, let made = madeHere, let last, made < last.addingTimeInterval(-Self.sameTime) {
                            outcome = "superseded"; return
                        }
                        // At its own time when known (never later than now, never before the last change here).
                        let at = madeHere.map { made in max(min(made, now), min(last ?? made, now)) } ?? now
                        try moveRow(cardID, to: status, now: at)
                        outcome = "moved"
                    } else { outcome = "bad"; return }
                    try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [key, String(now.timeIntervalSince1970)])
                }
                switch outcome {
                case "moved": moved += 1; result.applied.append(a.id)
                case "added": added += 1; result.applied.append(a.id)
                case "repeat": repeated += 1; result.applied.append(a.id)
                case "superseded": superseded += 1; result.skipped.append(PhoneSkip(id: a.id, reason: "superseded"))
                case "unknown": unknown.append(a.cardID.map(String.init) ?? "?"); result.skipped.append(PhoneSkip(id: a.id, reason: "gone"))
                default:
                    activity(component, .warning, "A phone action could not be read and was skipped", detail: "kind \(a.action)", trace: a.id)
                    result.skipped.append(PhoneSkip(id: a.id, reason: "invalid"))
                }
            } catch {
                // Not acked: the engine keeps it and the next poll tries again.
                activity(component, .error, "Could not apply a phone action; will try again", detail: "\(error)", trace: a.id)
            }
        }
        if !unknown.isEmpty {
            activity(component, .warning, "\(unknown.count) phone action(s) were for tasks no longer on the board; skipped",
                     detail: "card ids " + unknown.joined(separator: ","))
        }
        if superseded > 0 {
            activity(component, .info, "Kept a newer change from this Mac", detail: "\(superseded) phone move(s) not applied")
        }
        if moved + added > 0 {
            var parts: [String] = []
            if moved > 0 { parts.append("\(moved) moved") }
            if added > 0 { parts.append("\(added) added") }
            activity(component, .info, "From the phone: " + parts.joined(separator: ", "))
        }
        if repeated > 0 { activity(component, .info, "\(repeated) phone action(s) were already applied; acknowledged again") }
        return result
    }
}
