import Foundation

/// How a person can be reached and recognised in message metadata (features §3 P2, P4).
public enum HandleKind: String, CaseIterable, Codable {
    case phone, email, whatsapp, wechat, linkedin
    /// Kinds whose exact match merges two people automatically (P4); any other match is only a suggestion.
    public var mergesOnMatch: Bool { self == .phone || self == .email }
    public var title: String {
        switch self { case .phone: "Phone"; case .email: "Email"; case .whatsapp: "WhatsApp"; case .wechat: "WeChat"; case .linkedin: "LinkedIn" }
    }
}

/// One handle, stored normalised (`Handles.normalize`).
public struct Handle: Equatable, Hashable, Codable {
    public let kind: HandleKind
    public let value: String
    public init(kind: HandleKind, value: String) { self.kind = kind; self.value = value }
}

/// Handles in one stored form, so the same person is found whatever way a number or address was written.
public enum Handles {
    /// Phone numbers without an international prefix are taken as UK numbers (builder's call; the owner's home country).
    public static let defaultCountryCode = "44"

    /// The stored form of a raw handle, or nil when it isn't one.
    /// phone: international digits ("07700 900123" → "447700900123"); email: lower case; linkedin: "linkedin.com/in/<slug>";
    /// whatsapp: the chat id in lower case; wechat: the chat's name, trimmed.
    public static func normalize(_ kind: HandleKind, _ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch kind {
        case .phone:
            if t.contains("@") { return nil }   // a WhatsApp id ("<digits>@lid", a chat id) is never a phone number
            var d = String(t.filter(\.isNumber))
            if t.hasPrefix("+") { /* already international */ }
            else if d.hasPrefix("00") { d.removeFirst(2) }
            else if d.hasPrefix("0") { d = defaultCountryCode + d.dropFirst() }
            return (8...15).contains(d.count) ? d : nil
        case .email:
            let e = t.lowercased()
            guard let at = e.firstIndex(of: "@"), at != e.startIndex, e[e.index(after: at)...].contains("."), !e.contains(" ") else { return nil }
            return e
        case .linkedin:
            let l = t.lowercased()
            guard let r = l.range(of: "linkedin.com/in/") else { return nil }
            let slug = l[r.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            return slug.isEmpty ? nil : "linkedin.com/in/" + slug
        case .whatsapp:
            return t.lowercased()
        case .wechat:
            return String(t.prefix(200))
        }
    }

    /// A WhatsApp chat id as a handle: its phone number when it has one, else the id itself.
    /// True for a WhatsApp linked id ("<digits>@lid"): the contact chose not to share a number.
    public static func isLinkedID(_ h: Handle) -> Bool { h.kind == .whatsapp && h.value.hasSuffix("@lid") }

    /// How a handle is shown to the owner: a linked id in words (its digits are not a phone number), the rest as stored.
    public static func display(_ h: Handle) -> String { isLinkedID(h) ? "WhatsApp contact (no number shared)" : h.value }

    public static func fromWhatsApp(_ jid: String) -> Handle? {
        let j = jid.lowercased()
        if j.hasSuffix("@s.whatsapp.net") {
            let d = String(j.prefix { $0 != "@" })
            if d.allSatisfy(\.isNumber), (8...15).contains(d.count) { return Handle(kind: .phone, value: d) }
        }
        return normalize(.whatsapp, j).map { Handle(kind: .whatsapp, value: $0) }
    }

    /// A link that opens a conversation with this handle, when the app has one.
    public static func chatLink(_ h: Handle) -> String? {
        switch h.kind {
        case .phone: return "https://wa.me/\(h.value)"
        case .email: return "mailto:\(h.value)"
        case .linkedin: return "https://www." + h.value
        case .whatsapp, .wechat: return nil
        }
    }
}

/// Where an exchange was seen. `manual` = "I contacted them" or "We talked".
public enum Channel: String, CaseIterable, Codable {
    case whatsapp, wechat, gmail, outlook, calendar, manual
    public var title: String {
        switch self {
        case .whatsapp: "WhatsApp"; case .wechat: "WeChat"; case .gmail: "Gmail"; case .outlook: "Outlook"; case .calendar: "Calendar"
        case .manual: "By hand"
        }
    }
    /// What this channel can't see, said on the card instead of guessing (§9).
    public var limits: String? {
        switch self {
        case .outlook: "incoming only (the extension can't see what you send)"
        case .wechat: "incoming only, from Mac notifications (muted chats and cleared notifications aren't seen)"
        case .calendar: "meetings both of you accepted, from the calendar's last 30 days"
        default: nil
        }
    }
}

/// Which way a message went; `met` = a meeting both accepted, or "We talked".
public enum Direction: String, Codable {
    case incoming = "in", outgoing = "out", met
}

/// A message or meeting seen by a reader: metadata only (who, when, channel, direction). `ref` says where to open it
/// (an event id "E-41", the inbox address of a Gmail message); `name` is the display name from the header.
public struct ExchangeInput: Equatable {
    public var channel: Channel
    public var direction: Direction
    public var at: Date
    public var handle: Handle
    public var name: String
    public var ref: String
    public var key: String?
    public init(channel: Channel, direction: Direction, at: Date, handle: Handle, name: String = "", ref: String = "", key: String? = nil) {
        self.channel = channel; self.direction = direction; self.at = at; self.handle = handle; self.name = name; self.ref = ref; self.key = key
    }
}

/// An exchange as stored (one per handle, channel, day and direction; a meeting each).
public struct Exchange: Equatable, Identifiable {
    public let id: Int64
    public var channel: Channel
    public var direction: Direction
    public var at: Date
    /// nil for one made by hand ("I contacted them", "We talked").
    public var handle: Handle?
    public var name: String
    public var ref: String
    public var ignored: Bool
    public init(id: Int64, channel: Channel, direction: Direction, at: Date, handle: Handle?, name: String, ref: String, ignored: Bool) {
        self.id = id; self.channel = channel; self.direction = direction; self.at = at; self.handle = handle; self.name = name; self.ref = ref
        self.ignored = ignored
    }
}

/// A prospect's purpose and stage (P10), moved by hand.
public enum ProspectPurpose: String, CaseIterable { case career, investing, venture, learning
    public var title: String { rawValue.capitalized }
}
public enum ProspectStage: String, CaseIterable { case wantToMeet = "want_to_meet", inTouch = "in_touch", regular, dropped
    public var title: String { switch self { case .wantToMeet: "Want to meet"; case .inTouch: "In touch"; case .regular: "Regular"; case .dropped: "Dropped" } }
    public var active: Bool { self != .dropped }
}

/// Circle's fields of a person (the `circle_people` row; defaults when there is none yet).
public struct CircleDetails: Equatable {
    public var howKnown = "", company = "", role = "", birthday = "", language = "", notes = ""
    /// Days between conversations, set per person; nil = the tier's default.
    public var intervalDays: Int?
    public var firm = "", focus = "", purpose = "", stage = ""
    public var stageAt: Date?
    public var snoozedUntil: Date?
    public var remindedAt: Date?
    public var reminderTask: Int64?
    /// Updates (P11) turned on by request for someone who isn't Investor or Prospect (or is Family).
    public var updatesOn = false
    public var newsMuted = false
    public var feedURL = ""
    public var officerID = "", officerName = ""
    public var officerConfirmed: Date?
    /// Chinese contacts (P13): when the owner last looked by hand.
    public var manualChecked: Date?
    public init() {}
}

/// The three clocks and the due date of one person (§9).
public struct Clocks: Equatable {
    public var lastConversation: Date?
    public var conversationVia: Channel?
    public var lastHeard: Date?
    public var lastOutreach: Date?
    public var snoozedUntil: Date?
    public var dueDate: Date
    public var due: Bool
    public var interval: DateComponents
}

/// A merge, with what moved (so it can be split).
public struct MergeRecord: Equatable, Identifiable {
    public let id: Int64
    public let kept: Int64
    public let merged: Int64
    public let auto: Bool
    public let at: Date
}

/// Two people who might be one, said by code (same name, or a name that is the other's alias).
public struct MergeSuggestion: Equatable, Identifiable {
    public let a: Int64
    public let b: Int64
    public let reason: String
    public var key: String { "merge:\(min(a, b)):\(max(a, b))" }
    public var id: String { key }
}

/// Someone with replies both ways who isn't in Circle yet (P3).
public struct HandleSuggestion: Equatable, Identifiable {
    public let handle: Handle
    public let name: String
    public let channels: [Channel]
    public let exchanges: Int
    public let last: Date
    public var key: String { "handle:\(handle.kind.rawValue):\(handle.value)" }
    public var id: String { key }
}

/// What adding a handle did.
public enum HandleResult: Equatable {
    case added, exists
    /// The handle was another person's phone or email: this person was merged into that one (split undoes it).
    case merged(into: Int64)
    case refused(String)
}

/// Dates as Circle words them ("21 Nov", "Wed 21 Nov"), in the app's zone.
public enum CircleFmt {
    public static func f(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB"); f.timeZone = AppTime.zone; f.dateFormat = pattern
        return f.string(from: d)
    }
    /// "today", "yesterday", "3 days ago", "21 Nov", "21 Nov 2025".
    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let cal = AppTime.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days > 1 && days < 7 { return "\(days) days ago" }
        return cal.component(.year, from: d) == cal.component(.year, from: now) ? f("d MMM", d) : f("d MMM yyyy", d)
    }
}
