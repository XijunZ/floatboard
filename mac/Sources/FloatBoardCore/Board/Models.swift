import Foundation

public enum Status: String, CaseIterable, Identifiable {
    /// `watch` = waiting on someone else: still open, but not on you, so it stays off the bar.
    case todo, doing, watch, done
    public var id: String { rawValue }
    public var title: String {
        switch self { case .todo: "To do"; case .doing: "Doing"; case .watch: "Watch"; case .done: "Done" }
    }
    /// Only what's on you shows on the bar.
    public var onBar: Bool { self == .todo || self == .doing }
    public var next: Status? { switch self { case .todo: .doing; case .doing, .watch: .done; case .done: nil } }
    public var prev: Status? { switch self { case .todo: nil; case .doing: .todo; case .watch, .done: .doing } }
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
    /// The calendar and Google event id of the task's event (empty when it has none).
    public var gcalCalendar: String = ""
    public var gcalEvent: String = ""
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
    /// Watch: whom the task waits on (a name), how their reply is recognised ("email:<address>", "wa:<chat id>" or
    /// empty), and when it went to Watch (nil when not on Watch).
    public var watchPerson: String = ""
    public var watchContact: String = ""
    public var watchSince: Date? = nil
    /// Whether `due` carries a time of day. Stored, not guessed from the clock, so a time zone change never turns a
    /// date-only task into a timed one (or the reverse).
    public var dueHasTime: Bool = false
    /// Where the task came from when recorded ("phone"); empty = worked out from the task (`itemSource`).
    public var itemSourceRaw: String = ""

    public init(id: Int64, title: String, notes: String, area: String, importance: Importance, due: Date?, status: Status,
                created: Date, started: Date?, done: Date?, link: String = "", gcalAccount: String = "",
                gcalLink: String = "", source: String = "", externalID: String = "", sourceLink: String = "",
                sourceMeta: [String: String] = [:], importedAt: Date? = nil, sourceKey: SourceKey? = nil,
                withdrawn: Bool = false, aiSummary: String = "", connector: String = "",
                replyDraftState: ReplyDraftState? = nil, replyDraftLink: String = "", replyDraftError: String = "",
                replyDraftRequest: String = "", replyDraftSentAt: Date? = nil, dueHasTime: Bool = false, gcalCalendar: String = "", gcalEvent: String = "") {
        self.dueHasTime = dueHasTime
        self.gcalCalendar = gcalCalendar; self.gcalEvent = gcalEvent
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
        return notesMeetLink
    }

    /// A meet.google.com link found in the notes.
    var notesMeetLink: URL? {
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
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
            dates = f.string(from: due) + "/" + f.string(from: due.addingTimeInterval(30 * 60))
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = AppTime.zone
            f.dateFormat = "yyyyMMdd"
            let next = AppTime.calendar.date(byAdding: .day, value: 1, to: due) ?? due
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
        let from = connector.isEmpty ? source : connector
        return from.isEmpty ? "Source" : from
    }

    /// 0 = due today, 1 = tomorrow, negative = overdue, nil = no due date. Done tasks return nil.
    public var dueInDays: Int? {
        guard let due, status != .done else { return nil }
        let cal = AppTime.calendar
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
        let cal = AppTime.calendar
        return cal.startOfDay(for: due) < cal.startOfDay(for: Date())
    }

    /// For ordering: a date-only task counts as due at the end of that day,
    /// so today's timed meetings come before today's "sometime today" tasks.
    public var dueSortKey: Date? {
        guard let due else { return nil }
        if dueHasTime { return due }
        let cal = AppTime.calendar
        return cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: due))
    }
}

/// Search: every word in the query must appear somewhere in the task (any order, any case). A query that is an id
/// ("T-142") finds exactly that task, never T-1420 or a task that mentions the id.
public enum Search {
    public static func words(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
    public static func matches(_ card: Card, _ q: String) -> Bool {
        if let id = ShortID.parse(q) { return id == ShortID(kind: .task, number: card.id) }
        let w = words(q)
        guard !w.isEmpty else { return true }
        let hay = [card.title, card.notes, card.area, card.link, ShortID(kind: .task, number: card.id).text].joined(separator: " ")
        return w.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum Due {
    /// The old rule: a due at 00:00 in this Mac's zone has no time. Only the upgrade to schema 11 uses it, to fill in
    /// the stored flag for tasks made before it existed.
    public static func hasTime(_ d: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }
    /// Whether `d` is not midnight in `calendar`'s zone (the app's, by default).
    public static func hasTime(_ d: Date, in calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }
    /// The calendar day of `d` in the app's zone, "yyyy-MM-dd": how a date-only due is stored.
    public static func dayString(_ d: Date) -> String {
        let c = AppTime.calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// The start of a stored "yyyy-MM-dd" day in the app's zone; nil if it is not a real day.
    public static func startOfDay(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return AppTime.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    /// What a due is stored as: (due instant, day, has-time flag). A date-only due is the start of its day in the
    /// app's zone with its day kept apart; a timed due is the instant and has no day.
    static func stored(_ due: Date?, hasTime: Bool) -> (due: Date?, day: String?, hasTime: Int) {
        guard let due else { return (nil, nil, 0) }
        if hasTime { return (due, nil, 1) }
        let day = dayString(due)
        return (startOfDay(day) ?? due, day, 0)
    }
    /// Day from `day`, plus hour:minute from `time` if given; otherwise 00:00 (date only).
    public static func combine(day: Date, time: Date?) -> Date {
        let cal = AppTime.calendar
        let start = cal.startOfDay(for: day)
        guard let time else { return start }
        let t = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: start) ?? start
    }
    /// A sensible default time for a new meeting: next whole hour.
    public static var nextHour: Date {
        let cal = AppTime.calendar
        let h = cal.component(.hour, from: Date())
        return cal.date(bySettingHour: min(h + 1, 23), minute: 0, second: 0, of: Date()) ?? Date()
    }
}

public enum Fmt {
    /// Formatters are cached per pattern and zone, and the zone is read at every call, so a change of time zone shows at once.
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func formatter(_ f: String) -> DateFormatter {
        let zone = AppTime.zone
        let key = f + "|" + zone.identifier
        lock.lock(); defer { lock.unlock() }
        if let d = cache[key] { return d }
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = zone; d.dateFormat = f
        cache[key] = d
        return d
    }
    public static func short(_ d: Date) -> String {
        let f = formatter("yyyy-MM-dd")
        return f.string(from: d)
    }
    public static func withTime(_ d: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: d) }
    /// "12 Nov" for date-only, "12 Nov 14:30" when a time is set.
    public static func due(_ d: Date, hasTime: Bool) -> String { hasTime ? withTime(d) : short(d) }
    public static func clock(_ d: Date) -> String { formatter("HH:mm").string(from: d) }
    /// A meeting's time in a short line: "Thu 11:00" within a few days of `now`, "12 Nov 11:00" otherwise.
    public static func meeting(_ d: Date, now: Date = Date()) -> String {
        let near = abs(d.timeIntervalSince(now)) < 5 * 86400
        return formatter(near ? "EEE HH:mm" : "d MMM HH:mm").string(from: d)
    }
    public static func heading(_ d: Date) -> String { formatter("yyyy-MM-dd EEEE").string(from: d) }
    public static func csvDate(_ d: Date?) -> String { d.map { formatter("yyyy-MM-dd HH:mm").string(from: $0) } ?? "" }
    public static func duration(from a: Date, to b: Date) -> String {
        let mins = Int(b.timeIntervalSince(a) / 60)
        if mins < 60 { return "\(max(mins, 1))m" }
        if mins < 60 * 24 { return "\(mins / 60)h" }
        return "\(mins / (60 * 24))d"
    }
}

