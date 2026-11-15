import Foundation

/// What kind of place a link opens: an email, a call to join, or anything else.
public enum LinkKind: String { case email, meeting, link }

/// Reading links on a task: web links only, and their kind from the host.
public enum CardLinks {
    /// Hosts (and their subdomains) of video calls.
    static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "webex.com"]
    /// Hosts of web mail (the links the email connector writes).
    static let mailHosts = ["mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com"]

    static func host(_ u: URL, in domains: [String]) -> Bool {
        guard let h = u.host?.lowercased() else { return false }
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    public static func kind(_ u: URL) -> LinkKind {
        if host(u, in: meetingHosts) { return .meeting }
        if host(u, in: mailHosts) { return .email }
        return .link
    }

    /// The text as a web address (http or https with a host), else nil.
    public static func web(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", !(u.host ?? "").isEmpty else { return nil }
        return u
    }

    /// Web addresses written out in a text (starting http:// or https://), in order, without trailing punctuation.
    public static func found(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive]) else { return [] } // try?-ok: constant pattern
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?)]}".contains(last) { s.removeLast() }
            return web(s) == nil ? nil : s
        }
    }
}

/// Every task is the same kind: a feature shows when the task has what it needs, whatever created it.
/// (The UI asks these, never `connector` / `source` / `externalID` directly.)
extension Card {
    /// Where the task came from (the email, the meeting notes): the source link, when it parses with a scheme.
    public var sourceURL: URL? {
        URL(string: sourceLink.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
    }

    /// The source link when it opens an email (Open email).
    public var emailLink: URL? { sourceURL.flatMap { CardLinks.kind($0) == .email ? $0 : nil } }

    /// The call to join: the Link field when it is a Meet / Zoom / Teams / Whereby / Webex address, else a
    /// meet.google.com link found in the notes. (`meetLink` stays what goes into a calendar event.)
    public var meetingLink: URL? {
        if let u = CardLinks.web(link), CardLinks.kind(u) == .meeting { return u }
        return notesMeetLink
    }

    /// The Link field when it is a web address but not a call (Open link).
    public var otherLink: URL? { CardLinks.web(link).flatMap { CardLinks.kind($0) == .meeting ? nil : $0 } }

    /// Made by the email sorting (Claude's own decision), so a delete can teach it. A task the user made and later
    /// linked to an email has the connector and the message, but no external id.
    public var isFromEmailSorting: Bool { !connector.isEmpty && !externalID.isEmpty }

    /// Delete offers the "teach" choices: only the sorting's own decisions can be corrected.
    public var teachOnDelete: Bool { isFromEmailSorting }

    /// Draft reply: a linked email (a message id) on a connector that can draft it.
    public var canDraftReply: Bool { !connector.isEmpty && !(sourceKey?.messageID ?? "").isEmpty }

    /// The source chip ("✉ label"): the sorting's own cards (they carry why), and any task with a source link.
    public var showsSourceChip: Bool { isFromEmailSorting || sourceURL != nil }

    /// The task has an email linked (a message id), by the sorting or by the user.
    public var hasLinkedEmail: Bool { !(sourceKey?.messageID ?? "").isEmpty }

    /// The user linked this email ("Link an email"), so they can remove it.
    public var emailLinkedByUser: Bool { !connector.isEmpty && externalID.isEmpty && hasLinkedEmail }

    /// "Link an email" is offered: a task the email sorting did not make, with no email yet.
    public var canLinkEmail: Bool { !isFromEmailSorting && !hasLinkedEmail }
}
