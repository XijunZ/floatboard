import Foundation
import SQLite3

/// An email picked from a search to link to a task (only ids, the inbox, and what the search showed).
public struct LinkedEmail: Equatable {
    /// The Gmail inbox it is in.
    public var account: String
    /// Gmail's own message id (letters and digits).
    public var gmailID: String
    /// The email's Message-ID header (what Draft reply and the engine look it up by).
    public var messageID: String
    /// When it was sent (ISO 8601), as the search gave it.
    public var sentAt: String?
    public var subject: String
    public var from: String

    public init(account: String, gmailID: String, messageID: String, sentAt: String?, subject: String = "", from: String = "") {
        self.account = account; self.gmailID = gmailID; self.messageID = messageID; self.sentAt = sentAt
        self.subject = subject; self.from = from
    }

    /// Opens the email in Gmail, in the right inbox (the same form the engine writes).
    public var gmailLink: String { "https://mail.google.com/mail/u/\(account)/#all/\(gmailID)" }

    /// Ids that are safe to store and to put in a link.
    var isValid: Bool {
        !messageID.trimmingCharacters(in: .whitespaces).isEmpty && messageID.count <= 998
            && gmailID.range(of: "^[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
            && account.contains("@") && account.count <= 320 && account.range(of: "[\\s/#?]", options: .regularExpression) == nil
    }
}

/// Why linking or unlinking was refused. Texts are shown to the user as they are.
public enum EmailLinkError: Error, Equatable, CustomStringConvertible {
    case noCard, fromEmailSorting, alreadyLinked, notLinkedByUser, badEmail, linkedElsewhere
    public var description: String {
        switch self {
        case .noCard: "This task no longer exists."
        case .fromEmailSorting: "This task came from the email sorting; its email can't be changed."
        case .alreadyLinked: "This task already has an email. Remove that link first."
        case .notLinkedByUser: "Only an email you linked yourself can be removed."
        case .badEmail: "That email couldn't be read. Search again."
        case .linkedElsewhere: "That email is already on another task."
        }
    }
}

extension Store {
    /// Links an email to a task the user made (on this Mac or from the phone): the card gets the connector, the source
    /// key (message id, sent time) and the Gmail link, but never an external id, so Draft reply and Open email appear
    /// and the teach choices do not. Refused for the email sorting's own tasks and for a task that already has an email.
    public func linkEmail(cardID: Int64, connector: String, email: LinkedEmail, now: Date = Date()) throws {
        try performThrowing { try linkEmailRow(cardID, connector: connector, email: email, now: now) }
    }

    /// Removes an email the user linked; the email features switch off. Refused for the email sorting's own tasks.
    public func unlinkEmail(cardID: Int64, now: Date = Date()) throws {
        try performThrowing { try unlinkEmailRow(cardID, now: now) }
    }

    /// The stored card's link state, read inside the transaction (never the caller's copy).
    private func linkState(_ id: Int64) throws -> (connector: String, externalID: String, mid: String)? {
        try db.query("SELECT connector, external_id, source_mid, deleted FROM cards WHERE id=?", [id]) { s in
            DB.int(s, 3) != 0 ? nil : (DB.text(s, 0), DB.text(s, 1), sqlite3_column_type(s, 2) == SQLITE_NULL ? "" : DB.text(s, 2))
        }.first ?? nil
    }

    func linkEmailRow(_ id: Int64, connector: String, email: LinkedEmail, now: Date) throws {
        guard let st = try linkState(id) else { throw EmailLinkError.noCard }
        if !st.connector.isEmpty && !st.externalID.isEmpty { throw EmailLinkError.fromEmailSorting }
        if !st.mid.isEmpty { throw EmailLinkError.alreadyLinked }
        guard email.isValid, !connector.isEmpty else { throw EmailLinkError.badEmail }
        // One task per email and connector (the board's unique source key): the sorting's task, or another linked one.
        let taken = try db.query("SELECT count(*) FROM cards WHERE connector=? AND source_mid=? AND COALESCE(source_sent,'')=? AND id<>?",
                                 [connector, email.messageID, email.sentAt ?? "", id]) { DB.int($0, 0) }.first ?? 0
        if taken > 0 { throw EmailLinkError.linkedElsewhere }
        var meta = ["account": email.account, "gmailId": email.gmailID]
        if !email.from.isEmpty { meta["sender"] = email.from }
        if !email.subject.isEmpty { meta["subject"] = email.subject }
        let metaJSON = String(decoding: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]), as: UTF8.self)
        try db.run("""
            UPDATE cards SET connector=?, source=?, source_mid=?, source_sent=?, source_link=?, source_meta=?, updated=? WHERE id=?
            """, [connector, connector, email.messageID, email.sentAt ?? "", email.gmailLink, metaJSON, now, id])
        try insertEvent(id, "email linked", actor: .user, at: now)
    }

    func unlinkEmailRow(_ id: Int64, now: Date) throws {
        guard let st = try linkState(id) else { throw EmailLinkError.noCard }
        guard !st.connector.isEmpty, st.externalID.isEmpty, !st.mid.isEmpty else { throw EmailLinkError.notLinkedByUser }
        try db.run("""
            UPDATE cards SET connector='', source='', source_mid=NULL, source_sent=NULL, source_link='', source_meta='{}',
                reply_draft_state=NULL, reply_draft_link='', reply_draft_error='', reply_draft_request='', reply_draft_sent_at=NULL,
                updated=? WHERE id=?
            """, [now, id])
        try insertEvent(id, "email link removed", actor: .user, at: now)
    }
}
