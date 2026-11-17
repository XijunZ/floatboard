import Foundation

/// What the phone's Circle screen shows (§10), sent with `PUT /v2/circle` and kept encrypted by the engine.
public struct CirclePhoneCopy: Codable, Equatable {
    public struct Update: Codable, Equatable { public let kind: String; public let title: String; public let url: String; public let at: String?; public let possible: Bool }
    public struct Task: Codable, Equatable { public let id: Int64; public let title: String }
    public struct Line: Codable, Equatable { public let at: String; public let title: String; public let channel: String }
    public struct Person: Codable, Equatable {
        public let id: String
        public let name: String
        public let tier: String
        public let tags: [String]
        public let company: String
        public let lastTalked: String?
        public let lastHeard: String?
        public let lastOutreach: String?
        public let snoozedUntil: String?
        public let dueAt: String
        public let due: Bool
        public let interval: String
        public let context: [String]
        public let whatsNew: [Update]
        public let openTasks: [Task]
        public let timeline: [Line]
        /// International phone digits for WhatsApp (wa.me), and an email address, when known.
        public let wa: String?
        public let email: String?
        public let language: String
        public let notes: String
        enum CodingKeys: String, CodingKey {
            case id, name, tier, tags, company, due, interval, context, timeline, wa, email, language, notes
            case lastTalked = "last_talked", lastHeard = "last_heard", lastOutreach = "last_outreach", snoozedUntil = "snoozed_until", dueAt = "due_at"
            case whatsNew = "whats_new", openTasks = "open_tasks"
        }
    }
    public let due: [String]
    public let people: [Person]
    /// Per reader, when its data is from ("whatsapp": ISO).
    public let asOf: [String: String]
    enum CodingKeys: String, CodingKey { case due, people, asOf = "as_of" }
}

/// One person the engine follows for What's new (P11): only eligible people, only what the searches need.
public struct WatchPerson: Codable, Equatable {
    public let person: String
    public let name: String
    public let firm: String
    public let company: String
    public let officerID: String
    /// "YYYY-MM" from the birthday, for matching Companies House officers (never the day).
    public let born: String
    public let feedURL: String
    public let news: Bool
    public let ch: Bool
    enum CodingKeys: String, CodingKey { case person, name, firm, company, born, news, ch, officerID = "officer_id", feedURL = "feed_url" }
}

/// An action from the phone (the Circle screen, Plan, or a notification button).
public struct CirclePhoneAction: Codable, Equatable {
    public let id: String
    public let person: String
    public let action: String
    public let madeAt: String
    public init(id: String, person: String, action: String, madeAt: String) { self.id = id; self.person = person; self.action = action; self.madeAt = madeAt }
    enum CodingKeys: String, CodingKey { case id, person, action, madeAt = "made_at" }
}

@MainActor public enum CircleCopy {
    public static let maxPeople = 300
    public static let maxTimeline = 12

    static func iso(_ d: Date?) -> String? { d.map { ISO8601DateFormatter().string(from: $0) } }

    /// The phone copy: the due list and up to 300 cards (due people first, then by last talked).
    public static func phone(store: Store, now: Date = Date()) -> CirclePhoneCopy {
        let c = CircleStore(store: store)
        let due = CircleDue.entries(store: store, now: now)
        let dueByID = Dictionary(uniqueKeysWithValues: due.map { ($0.person.id, $0) })
        let details = c.allDetails(), handles = c.allHandles(), clocks = c.allClocks(now: now)
        let everyone = PeopleStore(store: store).people().sorted { a, b in
            let da = dueByID[a.id] != nil, db = dueByID[b.id] != nil
            if da != db { return da }
            return (clocks[a.id]?.lastConversation ?? .distantPast) > (clocks[b.id]?.lastConversation ?? .distantPast)
        }.prefix(maxPeople)
        let people = everyone.map { p -> CirclePhoneCopy.Person in
            let d = details[p.id] ?? CircleDetails(), k = clocks[p.id], hs = handles[p.id] ?? []
            let updates = c.updates(p.id).prefix(5).map { u in
                CirclePhoneCopy.Update(kind: u.kind.rawValue, title: u.title, url: u.url, at: iso(u.at), possible: u.kind.isNews && u.verdict == .none)
            }
            let tasks = store.links(of: p.shortID).filter { $0.kind == .task }.compactMap { store.card($0.number) }.filter { $0.status != .done }
                .prefix(8).map { CirclePhoneCopy.Task(id: $0.id, title: $0.title) }
            let lines = CircleTimeline.rows(store: store, personID: p.id, limit: maxTimeline).map {
                CirclePhoneCopy.Line(at: iso($0.at) ?? "", title: $0.title, channel: $0.channel?.rawValue ?? "")
            }
            return CirclePhoneCopy.Person(
                id: p.shortID.text, name: p.name, tier: p.tier.rawValue, tags: store.itemTags(p.shortID).all, company: d.company,
                lastTalked: iso(k?.lastConversation), lastHeard: iso(k?.lastHeard), lastOutreach: iso(k?.lastOutreach), snoozedUntil: iso(k?.snoozedUntil),
                dueAt: iso(k?.dueDate) ?? "", due: dueByID[p.id]?.overdue ?? false, interval: k.map { CircleClock.label($0.interval) } ?? "",
                context: dueByID[p.id]?.context ?? [], whatsNew: Array(updates), openTasks: Array(tasks), timeline: lines,
                wa: hs.first { $0.kind == .phone }?.value, email: hs.first { $0.kind == .email }?.value, language: d.language,
                notes: String(d.notes.prefix(500)))
        }
        var asOf: [String: String] = [:]
        for ch in c.channels() { if let a = iso(ch.asOf) { asOf[ch.channel] = a } }
        return CirclePhoneCopy(due: due.filter(\.overdue).map(\.person.shortID.text), people: Array(people), asOf: asOf)
    }

    public static func body(_ copy: CirclePhoneCopy) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(copy)
    }

    /// The people the engine follows (eligible for updates), with only what the searches need.
    public static func watchList(store: Store) -> [WatchPerson] {
        let c = CircleStore(store: store)
        let details = c.allDetails()
        return PeopleStore(store: store).people().compactMap { p in
            let d = details[p.id] ?? CircleDetails()
            guard c.wantsUpdates(p, d) else { return nil }
            let born = d.birthday.count >= 7 && d.birthday.split(separator: "-").count == 3 ? String(d.birthday.prefix(7)) : ""
            return WatchPerson(person: p.shortID.text, name: p.name, firm: d.firm, company: d.company, officerID: d.officerID, born: born,
                               feedURL: d.feedURL, news: !d.newsMuted, ch: true)
        }
    }
}

extension CircleStore {
    public struct PhoneResult { public var applied: [String] = []; public var skipped: [(id: String, reason: String)] = [] }

    /// Applies the phone's Circle actions: contacted (outreach at the time made), talked (a conversation), snooze (one
    /// interval from the time made; a later snooze wins). Unknown people or actions are skipped with a reason.
    public func applyPhoneActions(_ actions: [CirclePhoneAction], now: Date = Date()) -> PhoneResult {
        var r = PhoneResult()
        let isoF = ISO8601DateFormatter(), frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for a in actions {
            guard let pid = livePerson(a.person), let p = people.person(pid) else { r.skipped.append((a.id, "unknown person")); continue }
            let at = min(isoF.date(from: a.madeAt) ?? frac.date(from: a.madeAt) ?? now, now)
            switch a.action {
            case "contacted": contacted(pid, at: at)
            case "talked": talked(pid, at: at)
            case "snooze":
                var d = details(pid)
                let until = CircleClock.add(CircleClock.interval(tier: p.tier, tags: store.itemTags(p.shortID).all, intervalDays: d.intervalDays), to: at)
                if (d.snoozedUntil ?? .distantPast) < until { d.snoozedUntil = until; store.perform { try writeDetailsRow(pid, d) } }
            default: r.skipped.append((a.id, "unknown action")); continue
            }
            r.applied.append(a.id)
        }
        return r
    }
}
