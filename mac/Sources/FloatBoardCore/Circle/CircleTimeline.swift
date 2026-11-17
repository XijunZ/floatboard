import Foundation

/// One line of a person's timeline (P8): an exchange (channel, date, direction; no text), a meeting, or a linked item.
public struct TimelineRow: Identifiable, Equatable {
    public let id: String
    public let at: Date
    public let title: String
    public let detail: String
    public let channel: Channel?
    public let direction: Direction?
    /// The item it opens (a meeting's E-n, a linked jot, task or decision).
    public let item: ShortID?
    /// A link that opens the conversation in its app, when there is one.
    public let link: String?
    /// The stored exchange (a meeting can be corrected as "didn't meet").
    public let exchangeID: Int64?
    public let ignored: Bool
}

@MainActor public enum CircleTimeline {
    /// Newest first: exchanges and meetings, then everything linked to the person (jots, tasks, decisions, events), each once.
    public static func rows(store: Store, personID: Int64, limit: Int = 200) -> [TimelineRow] {
        let c = CircleStore(store: store)
        let person = ShortID(kind: .person, number: personID)
        var out: [TimelineRow] = []
        var seenItems = Set<ShortID>()
        for e in c.exchanges(of: personID) {
            let item = e.channel == .calendar ? ShortID.parse(e.ref) : nil
            if let item { seenItems.insert(item) }
            let meetingTitle = item.flatMap { store.item($0)?.title }
            out.append(TimelineRow(id: "x\(e.id)", at: e.at, title: title(e, meeting: meetingTitle), detail: e.channel.title, channel: e.channel,
                                   direction: e.direction, item: item, link: link(e), exchangeID: e.id, ignored: e.ignored))
        }
        for l in store.itemLinks(of: person) where !seenItems.contains(l.other) {
            guard let s = store.item(l.other), !s.deleted else { continue }
            seenItems.insert(l.other)
            let kind: String
            switch l.other.kind {
            case .jot: kind = "Jot"; case .task: kind = "Task"; case .decision: kind = "Decision"; case .event: kind = "Meeting"
            case .resolution: kind = "Goal"; case .person: kind = "Person"
            }
            out.append(TimelineRow(id: "i\(l.other.text)", at: s.added ?? s.updated ?? l.created, title: s.title, detail: "\(kind) \(l.other.text)",
                                   channel: nil, direction: nil, item: l.other, link: nil, exchangeID: nil, ignored: false))
        }
        return Array(out.sorted { $0.at > $1.at }.prefix(limit))
    }

    static func title(_ e: Exchange, meeting: String?) -> String {
        switch (e.channel, e.direction) {
        case (.gmail, .outgoing): return "Email sent"
        case (.gmail, _), (.outlook, _): return "Email received"
        case (.whatsapp, .outgoing): return "WhatsApp sent"
        case (.whatsapp, _): return "WhatsApp received"
        case (.wechat, _): return "WeChat received"
        case (.calendar, _): return "Met" + (meeting.map { ": \($0)" } ?? "")
        case (.manual, .outgoing): return "You contacted them"
        case (.manual, _): return "You talked"
        }
    }

    /// Where an exchange opens: the WhatsApp chat, or a Gmail search for the address in the inbox it was seen in.
    static func link(_ e: Exchange) -> String? {
        guard let h = e.handle else { return nil }
        switch (e.channel, h.kind) {
        case (.whatsapp, .phone): return "https://wa.me/\(h.value)"
        case (.gmail, .email):
            let q = (e.direction == .outgoing ? "to:" : "from:") + h.value
            let account = e.ref.isEmpty ? "" : "?authuser=" + (e.ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            return "https://mail.google.com/mail/u/\(account)#search/" + (q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q)
        default: return nil
        }
    }
}
