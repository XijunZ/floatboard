import Foundation

public enum Status: String, CaseIterable, Identifiable {
    case todo, doing, done
    public var id: String { rawValue }
    public var title: String {
        switch self { case .todo: "To do"; case .doing: "Doing"; case .done: "Done" }
    }
    public var next: Status? { switch self { case .todo: .doing; case .doing: .done; case .done: nil } }
    public var prev: Status? { switch self { case .todo: nil; case .doing: .todo; case .done: .doing } }
}

public enum Importance: Int, CaseIterable, Identifiable {
    case low = 0, medium = 1, high = 2
    public var id: Int { rawValue }
    public var title: String { switch self { case .low: "Low"; case .medium: "Medium"; case .high: "High" } }
    /// Importance is shown by shape and weight, not colour, so it never clashes with group colours.
    public var marks: String { switch self { case .low: "!"; case .medium: "!!"; case .high: "!!!" } }
    public var label: String { "\(marks)  \(title)" }
}

/// A user-editable group (Acme, Personal, …). Stored in the `areas` table.
public struct Category: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var colorHex: String
    public var position: Double
    public init(id: Int64, name: String, colorHex: String, position: Double) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.position = position
    }
}

public enum Palette {
    public static let colors: [(name: String, hex: String)] = [
        ("Blue", "#0A84FF"), ("Purple", "#BF5AF2"), ("Green", "#30D158"), ("Orange", "#FF9F0A"),
        ("Red", "#FF453A"), ("Pink", "#FF375F"), ("Teal", "#40C8E0"), ("Yellow", "#FFD60A"),
        ("Indigo", "#5E5CE6"), ("Brown", "#AC8E68"), ("Grey", "#8E8E93"),
    ]
}

/// Where a card's reply draft request stands. Nil when the card never asked for one.
public enum ReplyDraftState: String { case requested, ready, failed }

public struct Card: Identifiable, Equatable {
    public var id: Int64
    public var title: String
    public var notes: String
    public var area: String // group name
    public var importance: Importance
    public var due: Date?
    public var status: Status
    public var created: Date
    public var started: Date?
    public var done: Date?
    /// Optional link, e.g. a Google Meet call or the Google Calendar event.
    public var link: String = ""
    /// Set once the task has been added to Google Calendar from FloatBoard.
    public var gcalAccount: String = ""
    public var gcalLink: String = ""
    /// Set when a connector created the card (e.g. "email"); empty for cards typed in.
    public var source: String = ""
    public var externalID: String = ""
    public var sourceLink: String = ""
    public var sourceMeta: [String: String] = [:]
    public var importedAt: Date? = nil
    /// The source message a connector built this card from (nil for typed cards).
    public var sourceKey: SourceKey? = nil
    /// True when the source says the task no longer applies.
    public var withdrawn: Bool = false
    /// Text written by a connector's AI; kept apart from the user's own `notes`.
    public var aiSummary: String = ""
    /// Id of the connector that created the card; empty for typed cards.
    public var connector: String = ""
    /// The newest reply draft request for this card and its result (see `Store.requestReplyDraft`).
    public var replyDraftState: ReplyDraftState? = nil
    /// Link to the finished draft (when ready).
    public var replyDraftLink: String = ""
    /// Why the draft could not be made (when failed).
    public var replyDraftError: String = ""
    /// Id of the newest request; results for any other id are ignored.
    public var replyDraftRequest: String = ""
    /// When the request reached the engine; the 10-minute timeout counts from here. Nil while it waits to be sent.
    public var replyDraftSentAt: Date? = nil

    public init(id: Int64, title: String, notes: String, area: String, importance: Importance, due: Date?, status: Status,
                created: Date, started: Date?, done: Date?, link: String = "", gcalAccount: String = "",
                gcalLink: String = "", source: String = "", externalID: String = "", sourceLink: String = "",
                sourceMeta: [String: String] = [:], importedAt: Date? = nil, sourceKey: SourceKey? = nil,
                withdrawn: Bool = false, aiSummary: String = "", connector: String = "",
                replyDraftState: ReplyDraftState? = nil, replyDraftLink: String = "", replyDraftError: String = "",
                replyDraftRequest: String = "", replyDraftSentAt: Date? = nil) {
        self.replyDraftState = replyDraftState; self.replyDraftLink = replyDraftLink; self.replyDraftError = replyDraftError
        self.replyDraftRequest = replyDraftRequest; self.replyDraftSentAt = replyDraftSentAt
        self.sourceKey = sourceKey; self.withdrawn = withdrawn; self.aiSummary = aiSummary; self.connector = connector
        self.link = link; self.gcalAccount = gcalAccount; self.gcalLink = gcalLink; self.source = source
        self.externalID = externalID; self.sourceLink = sourceLink; self.sourceMeta = sourceMeta; self.importedAt = importedAt
        self.id = id; self.title = title; self.notes = notes; self.area = area; self.importance = importance
        self.due = due; self.status = status; self.created = created; self.started = started; self.done = done
    }

    /// The call to join: the Link field if it's a URL, otherwise a meet.google.com link found in the notes.
    public var meetLink: URL? {
        let l = link.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: l), u.scheme?.hasPrefix("http") == true { return u }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil } // try?-ok: optional parsing of untrusted display text
        let ns = notes as NSString
        return detector.matches(in: notes, range: NSRange(location: 0, length: ns.length))
            .compactMap(\.url)
            .first { $0.host?.contains("meet.google.com") == true }
    }

    /// A pre-filled "new event" page in Google Calendar: 30 min if the task has a time, all-day otherwise.
    public var googleCalendarURL: URL? {
        guard let due else { return nil }
        let dates: String
        if dueHasTime {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
            dates = f.string(from: due) + "/" + f.string(from: due.addingTimeInterval(30 * 60))
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            let next = Calendar.current.date(byAdding: .day, value: 1, to: due) ?? due
            dates = f.string(from: due) + "/" + f.string(from: next)
        }
        var details = notes
        if let m = meetLink { details += (details.isEmpty ? "" : "\n\n") + m.absoluteString }
        var c = URLComponents(string: "https://calendar.google.com/calendar/render")!
        c.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: title),
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "details", value: details),
        ]
        if let m = meetLink { c.queryItems?.append(URLQueryItem(name: "location", value: m.absoluteString)) }
        return c.url
    }

    /// Short name of where a connector card came from, for its chip: the connector's label, else the display name
    /// in an older card's "sender" ("Rosa Allen <rosa@x.io>" -> "Rosa Allen", or the address), else the connector id.
    public var sourceLabel: String {
        let label = (sourceMeta["source_label"] ?? "").trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { return label }
        let s = (sourceMeta["sender"] ?? "").trimmingCharacters(in: .whitespaces)
        if let lt = s.firstIndex(of: "<") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            return String(s[s.index(after: lt)...]).trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        if !s.isEmpty { return s }
        return connector.isEmpty ? source : connector
    }

    /// Due dates without a time are stored at 00:00; anything else has a time (e.g. a meeting).
    public var dueHasTime: Bool { due.map(Due.hasTime) ?? false }

    /// 0 = due today, 1 = tomorrow, negative = overdue, nil = no due date. Done tasks return nil.
    var dueInDays: Int? {
        guard let due, status != .done else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due)).day
    }

    /// How urgent the due date is, for colouring (bar chips and board cards use the same scheme).
    public enum Urgency { case overdue, today, tomorrow, none }
    public var urgency: Urgency {
        if isOverdue { return .overdue }
        switch dueInDays {
        case 0?: return .today
        case 1?: return .tomorrow
        default: return .none
        }
    }

    public var isOverdue: Bool {
        guard let due, status != .done else { return false }
        if dueHasTime { return due < Date() }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date())
    }

    /// For ordering: a date-only task counts as due at the end of that day,
    /// so today's timed meetings come before today's "sometime today" tasks.
    public var dueSortKey: Date? {
        guard let due else { return nil }
        if dueHasTime { return due }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: Calendar.current.startOfDay(for: due))
    }
}

/// Search: every word in the query must appear somewhere in the task (any order, any case).
public enum Search {
    public static func words(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
    public static func matches(_ card: Card, _ q: String) -> Bool {
        let w = words(q)
        guard !w.isEmpty else { return true }
        let hay = [card.title, card.notes, card.area, card.link].joined(separator: " ")
        return w.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum Due {
    public static func hasTime(_ d: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }
    /// Day from `day`, plus hour:minute from `time` if given; otherwise 00:00 (date only).
    public static func combine(day: Date, time: Date?) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let time else { return start }
        let t = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: start) ?? start
    }
    /// A sensible default time for a new meeting: next whole hour.
    public static var nextHour: Date {
        let cal = Calendar.current
        let h = cal.component(.hour, from: Date())
        return cal.date(bySettingHour: min(h + 1, 23), minute: 0, second: 0, of: Date()) ?? Date()
    }
}

public enum Fmt {
    private static let day: DateFormatter = make("yyyy-MM-dd")
    private static let dayYear: DateFormatter = make("yyyy-MM-dd")
    private static let dayTime: DateFormatter = make("yyyy-MM-dd HH:mm")
    private static let time: DateFormatter = make("HH:mm")
    private static let longDay: DateFormatter = make("yyyy-MM-dd EEEE")
    private static let csv: DateFormatter = make("yyyy-MM-dd HH:mm")

    private static func make(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = f; return d
    }
    public static func short(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? day.string(from: d) : dayYear.string(from: d)
    }
    public static func withTime(_ d: Date) -> String { dayTime.string(from: d) }
    /// "12 Nov" for date-only, "12 Nov 14:30" when a time is set.
    public static func due(_ d: Date) -> String { Due.hasTime(d) ? withTime(d) : short(d) }
    public static func clock(_ d: Date) -> String { time.string(from: d) }
    public static func heading(_ d: Date) -> String { longDay.string(from: d) }
    public static func csvDate(_ d: Date?) -> String { d.map { csv.string(from: $0) } ?? "" }
    public static func duration(from a: Date, to b: Date) -> String {
        let mins = Int(b.timeIntervalSince(a) / 60)
        if mins < 60 { return "\(max(mins, 1))m" }
        if mins < 60 * 24 { return "\(mins / 60)h" }
        return "\(mins / (60 * 24))d"
    }
}

