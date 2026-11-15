import Foundation

/// Who made a change: the person using the app, or a connector acting for them.
/// Stored in `events.actor` as "user" / "connector:<id>".
public enum Actor: Equatable {
    case user
    case connector(String)

    public var stored: String {
        switch self { case .user: "user"; case .connector(let id): "connector:\(id)" }
    }

    public static func parse(_ s: String) -> Actor {
        s.hasPrefix("connector:") ? .connector(String(s.dropFirst("connector:".count))) : .user
    }
}

/// Identifies the source message a connector built a card from.
public struct SourceKey: Hashable, Codable {
    public let messageID: String
    /// When the email was sent (ISO UTC). Empty when unknown: engine items made before send dates were recorded come
    /// with `sent_at: null`, and those match a card by message id alone.
    public let sentAt: String
    public init(messageID: String, sentAt: String) { self.messageID = messageID; self.sentAt = sentAt }
    enum CodingKeys: String, CodingKey { case messageID = "message_id", sentAt = "sent_at" }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        messageID = try c.decode(String.self, forKey: .messageID)
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt) ?? ""
    }
    /// True for a key without a send date (see `sentAt`).
    public var undated: Bool { sentAt.isEmpty }
}

extension Store {
    /// True once the user has done anything to the card (connector-only history does not count).
    public func isTouched(_ cardID: Int64) -> Bool {
        do {
            return (try db.query("SELECT count(*) FROM events WHERE card_id=? AND actor='user'", [cardID]) { DB.int($0, 0) }.first ?? 0) > 0
        } catch {
            activity("store", .error, "Could not read card history", detail: "\(error)")
            return true // when unsure, treat as touched so connectors never overwrite user work
        }
    }

    /// Puts a withdrawn card back on the board. Recorded as the user's own action, so the card counts as touched and
    /// a later re-check will not withdraw it again.
    public func restoreWithdrawn(_ cardID: Int64) {
        let now = Date()
        perform {
            let is1 = try db.query("SELECT count(*) FROM cards WHERE id=? AND withdrawn=1", [cardID]) { DB.int($0, 0) }.first ?? 0
            guard is1 > 0 else { return }   // not withdrawn: nothing to restore, no history row
            try db.run("UPDATE cards SET withdrawn=0, updated=? WHERE id=? AND withdrawn=1", [now, cardID])
            try insertEvent(cardID, "restored by you", actor: .user, at: now)
        }
    }

    /// Add a history row for a card, attributed to `actor`.
    public func record(_ cardID: Int64, _ kind: String, actor: Actor) {
        let now = Date()
        perform { try insertEvent(cardID, kind, actor: actor, at: now) }
    }

    func insertEvent(_ cardID: Int64, _ kind: String, from: Status? = nil, to: Status? = nil,
                     actor: Actor, at: Date) throws {
        try db.run("INSERT INTO events(card_id,at,kind,from_status,to_status,actor,uuid) VALUES(?,?,?,?,?,?,?)",
                   [cardID, at, kind, from?.rawValue, to?.rawValue, actor.stored, UUID().uuidString])
    }
}
