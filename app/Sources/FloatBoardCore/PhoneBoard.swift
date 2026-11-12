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

    enum CodingKeys: String, CodingKey {
        case id, title, group, color, importance, due, hasTime = "has_time", status, link, doneAt = "done_at"
    }

    /// Every field is written, nil ones as null (the engine requires them all).
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(group, forKey: .group)
        try c.encode(color, forKey: .color); try c.encode(importance, forKey: .importance); try c.encode(due, forKey: .due)
        try c.encode(hasTime, forKey: .hasTime); try c.encode(status, forKey: .status); try c.encode(link, forKey: .link)
        try c.encode(doneAt, forKey: .doneAt)
    }
}

/// One change made on the phone, waiting on the engine for the Mac (`GET /v2/phone-actions`).
public struct PhoneAction: Codable, Equatable {
    public var id: String
    public var cardID: Int64?
    /// todo | doing | watch | done | add
    public var action: String
    public var title: String?
    public var group: String?

    public init(id: String, cardID: Int64?, action: String, title: String? = nil, group: String? = nil) {
        self.id = id; self.cardID = cardID; self.action = action; self.title = title; self.group = group
    }

    enum CodingKeys: String, CodingKey { case id, cardID = "card_id", action, title, group }
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
    @MainActor
    public static func payload(store: Store, now: Date, calendar: Calendar = .current) -> [BoardCard] {
        let colors = Dictionary(store.areas.map { ($0.name, $0.colorHex) }, uniquingKeysWith: { a, _ in a })
        let open = store.active
        let doneToday = store.cards(in: .done).filter { c in c.done.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        return (open + doneToday).prefix(maxCards).map { card(for: $0, color: colors[$0.area], calendar: calendar) }
    }

    static func card(for c: Card, color: String?, calendar: Calendar) -> BoardCard {
        let hex = color.flatMap { $0.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil ? $0 : nil } ?? fallbackColor
        let hasTime = c.due.map { Due.hasTime($0) } ?? false
        return BoardCard(id: c.id, title: clip(c.title), group: clip(c.area), color: hex, importance: c.importance.rawValue,
                         due: c.due.map { hasTime ? iso($0, calendar) : day($0, calendar) }, hasTime: hasTime,
                         status: c.status.rawValue, link: webLink(c.sourceLink) ?? webLink(c.link),
                         doneAt: c.status == .done ? c.done.map { iso($0, calendar) } : nil)
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

    /// The body sent to the engine: `{"cards":[...]}` with sorted keys, so equal boards give equal bytes.
    public static func body(_ cards: [BoardCard]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(["cards": cards])
    }

    /// A stable fingerprint of the board for one engine address (a different engine always gets a push).
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

    /// The hash of the board last accepted by this connector's engine, or nil.
    public func lastBoardHash(connector: String) -> String? {
        do { return try db.query("SELECT value FROM meta WHERE key=?", [Self.boardHashKey(connector)]) { DB.text($0, 0) }.first }
        catch {
            activity("connector:\(connector)", .warning, "Could not read when the phone's board was last sent; sending it again", detail: "\(error)")
            return nil
        }
    }

    /// Records (or with nil forgets) the hash of the board the engine accepted.
    public func setLastBoardHash(_ hash: String?, connector: String) {
        do {
            if let hash { try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [Self.boardHashKey(connector), hash]) }
            else { try db.run("DELETE FROM meta WHERE key=?", [Self.boardHashKey(connector)]) }
        } catch {
            activity("connector:\(connector)", .warning, "Could not record the phone's board as sent; it will be sent again", detail: "\(error)")
        }
    }

    /// Applies changes made on the phone and returns the ids to acknowledge. Moves are made as the user (so a connector
    /// card moved to Done still tells its engine); `add` makes a To do task (medium, no due) in the named group, or the
    /// first group. Each id is applied once, also when it arrives again before the ack reached the engine (applied ids
    /// are kept for 7 days). Unknown or deleted cards are logged and acked. Activity never carries task titles.
    @discardableResult
    public func applyPhoneActions(_ actions: [PhoneAction], connector: String, now: Date = Date()) -> [String] {
        let component = "connector:\(connector)"
        var ack: [String] = []
        var moved = 0, added = 0, repeated = 0
        var unknown: [String] = []
        do {
            try db.run("DELETE FROM meta WHERE key LIKE ? AND CAST(value AS REAL) < ?",
                       ["phone_action:\(connector):%", (now.addingTimeInterval(-PhoneBoard.rememberApplied)).timeIntervalSince1970])
        } catch {
            activity(component, .warning, "Could not clear old phone action records", detail: "\(error)")
        }
        for a in actions {
            let key = Self.appliedKey(connector, a.id)
            do {
                var outcome = "skip"
                try performThrowing {
                    if try db.query("SELECT 1 FROM meta WHERE key=?", [key], { DB.int($0, 0) }).first != nil { outcome = "repeat"; return }
                    if a.action == "add" {
                        let title = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if title.isEmpty { outcome = "bad" } else {
                            let group = areas.contains { $0.name == a.group } ? a.group! : (areas.first?.name ?? "Personal")
                            let id = try db.run(
                                "INSERT INTO cards(title,area,importance,due,status,created,updated) VALUES(?,?,?,?,?,?,?)",
                                [PhoneBoard.clip(title), group, Importance.medium.rawValue, nil, Status.todo.rawValue, now, now])
                            try insertEvent(id, "created (from the phone)", to: .todo, actor: .user, at: now)
                            outcome = "added"
                        }
                    } else if let status = Status(rawValue: a.action), let cardID = a.cardID {
                        let row = try db.query("SELECT deleted, withdrawn FROM cards WHERE id=?", [cardID]) { (DB.int($0, 0), DB.int($0, 1)) }.first
                        if let row, row.0 == 0, row.1 == 0 {
                            try moveRow(cardID, to: status, now: now)
                            outcome = "moved"
                        } else { outcome = "unknown" }
                    } else { outcome = "bad" }
                    try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [key, String(now.timeIntervalSince1970)])
                }
                switch outcome {
                case "moved": moved += 1
                case "added": added += 1
                case "repeat": repeated += 1
                case "unknown": unknown.append(a.cardID.map(String.init) ?? "?")
                default: activity(component, .warning, "A phone action could not be read and was skipped", detail: "kind \(a.action)", trace: a.id)
                }
                ack.append(a.id)
            } catch {
                // Not acked: the engine keeps it and the next poll tries again.
                activity(component, .error, "Could not apply a phone action; will try again", detail: "\(error)", trace: a.id)
            }
        }
        if !unknown.isEmpty {
            activity(component, .warning, "\(unknown.count) phone action(s) were for tasks no longer on the board; skipped",
                     detail: "card ids " + unknown.joined(separator: ","))
        }
        if moved + added > 0 {
            var parts: [String] = []
            if moved > 0 { parts.append("\(moved) moved") }
            if added > 0 { parts.append("\(added) added") }
            activity(component, .info, "From the phone: " + parts.joined(separator: ", "))
        }
        if repeated > 0 { activity(component, .info, "\(repeated) phone action(s) were already applied; acknowledged again") }
        return ack
    }
}
