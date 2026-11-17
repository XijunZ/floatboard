import Foundation

/// Fathom's details of a meeting (engine `meetings`, sent with the meeting notes): links, scheduled start, invitees.
public struct MeetingMeta: Equatable {
    public var recapKey: String
    public var fathomURL: String
    public var meetingURL: String
    public var title: String
    public var scheduledStart: Date?
    public var invitees: [String]
    public var received: Date
    public init(recapKey: String, fathomURL: String = "", meetingURL: String = "", title: String = "", scheduledStart: Date? = nil,
                invitees: [String] = [], received: Date = Date()) {
        self.recapKey = recapKey; self.fathomURL = fathomURL; self.meetingURL = meetingURL; self.title = title
        self.scheduledStart = scheduledStart; self.invitees = invitees.map { $0.lowercased() }; self.received = received
    }
}

/// J9: which calendar event a meeting's notes belong to, by code (never AI). A meeting link wins; then the scheduled start
/// with at least one shared invitee; anything less certain is only a suggestion.
public enum MeetingMatch {
    public enum Result: Equatable {
        case link(Int64), time(Int64), suggested(Int64), none
        public var event: Int64? { switch self { case .link(let e), .time(let e), .suggested(let e): e; case .none: nil } }
        public var name: String { switch self { case .link: "link"; case .time: "time"; case .suggested: "suggested"; case .none: "" } }
    }
    /// How far from the scheduled start an event may start and still be this meeting by time.
    public static let startTolerance: TimeInterval = 10 * 60
    /// How far around the meeting (scheduled start, else when the notes arrived) events are looked at.
    public static let window: TimeInterval = 86400

    public static func find(_ m: MeetingMeta, events: [CalEvent]) -> Result {
        let anchor = m.scheduledStart ?? m.received
        let near = events.filter { !$0.allDay && abs($0.start.timeIntervalSince(anchor)) <= window }
        let byStart = { (a: CalEvent, b: CalEvent) in abs(a.start.timeIntervalSince(anchor)) < abs(b.start.timeIntervalSince(anchor)) }
        if !m.meetingURL.isEmpty, let e = near.filter({ sameCall($0.videoLink, m.meetingURL) }).sorted(by: byStart).first { return .link(e.shortID) }
        guard let start = m.scheduledStart else { return .none }
        let onTime = near.filter { abs($0.start.timeIntervalSince(start)) <= startTolerance }.sorted(by: byStart)
        let invited = Set(m.invitees)
        let shared = onTime.filter { e in e.guests.contains { invited.contains($0.email.lowercased()) } }
        if shared.count == 1, let e = shared.first { return .time(e.shortID) }
        if let e = shared.first ?? onTime.first { return .suggested(e.shortID) }
        return .none
    }

    /// Two call links name the same call: scheme, "www.", query, fragment, a trailing "/" and letter case are ignored.
    public static func sameCall(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        return !x.isEmpty && x == y
    }

    static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        if let i = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<i]) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}

/// Meeting notes as stored with their jot.
public struct MeetingNotesInfo: Equatable {
    public let meta: MeetingMeta
    public let matchedBy: String
}

extension JotStore {
    /// Takes in a meeting's notes from the engine: one jot per meeting (`origin`), kind meeting notes, source meeting,
    /// Fathom's details kept, and attached to its event when code can tell which (`attachMeetingNotes`).
    @discardableResult
    public func takeMeetingNotes(_ text: String, meta: MeetingMeta, origin: String, now: Date = Date()) -> Jot? {
        if let j = jot(origin: origin) { return j }
        var id: Int64?
        store.perform {
            let n = try addRow(text, kind: .meetingNotes, source: .meeting, origin: origin, taskID: nil, tags: [], now: now)
            try store.db.run("""
                INSERT INTO jot_meetings(jot_id, recap_key, fathom_url, meeting_url, title, scheduled_start, invitees, received) VALUES(?,?,?,?,?,?,?,?)
                """, [n, meta.recapKey, meta.fathomURL, meta.meetingURL, meta.title, meta.scheduledStart,
                      String(decoding: try JSONSerialization.data(withJSONObject: meta.invitees), as: UTF8.self), meta.received])
            id = n
        }
        guard let id else { return nil }
        attachMeetingNotes(id, now: now)
        return jot(id)
    }

    /// Fathom's details of a meeting notes jot and how it was attached.
    public func meetingInfo(_ jotID: Int64) -> MeetingNotesInfo? {
        let sql = """
            SELECT recap_key, fathom_url, meeting_url, title, scheduled_start, invitees, matched_by, received FROM jot_meetings WHERE jot_id=?
            """
        return (try? store.db.query(sql, [jotID]) { s in // try?-ok: unreadable = shown as plain notes
            let invitees = (try? JSONSerialization.jsonObject(with: Data(DB.text(s, 5).utf8))) as? [String] ?? [] // try?-ok: unreadable = no invitees, so matching falls back to a suggestion
            return MeetingNotesInfo(meta: MeetingMeta(recapKey: DB.text(s, 0), fathomURL: DB.text(s, 1), meetingURL: DB.text(s, 2), title: DB.text(s, 3),
                                                      scheduledStart: DB.date(s, 4), invitees: invitees, received: DB.date(s, 7) ?? Date()),
                                    matchedBy: DB.text(s, 6))
        })?.first // try?-ok: unreadable = shown as plain notes
    }

    /// Tries to attach a meeting notes jot to its event (code: link, then time and invitees; else a suggestion). A jot
    /// already attached, or one the owner linked to an event by hand, is left alone. Returns what was found.
    @discardableResult
    public func attachMeetingNotes(_ jotID: Int64, now: Date = Date()) -> MeetingMatch.Result {
        guard let info = meetingInfo(jotID), info.matchedBy.isEmpty || info.matchedBy == "suggested" else { return .none }
        let me = ShortID(kind: .jot, number: jotID)
        if store.itemLinks(of: me).contains(where: { $0.other.kind == .event && $0.madeBy != .suggested }) { return .none }
        let anchor = info.meta.scheduledStart ?? info.meta.received
        let events = CalendarCache(store: store).meetings(from: anchor.addingTimeInterval(-MeetingMatch.window),
                                                          to: anchor.addingTimeInterval(MeetingMatch.window))
        let result = MeetingMatch.find(info.meta, events: events)
        guard let event = result.event else { return .none }
        if info.matchedBy == "suggested", case .suggested = result { return result }
        let eid = ShortID(kind: .event, number: event)
        if case .suggested = result {} else {
            for l in store.itemLinks(of: me) where l.other.kind == .event && l.madeBy == .suggested && l.other != eid { store.unlink(me, l.other) }
        }
        store.perform {
            try store.linkRow(me, eid, kind: .notesOf, madeBy: result == .suggested(event) ? .suggested : .auto, actor: .user, now: now)
            try store.db.run("UPDATE jot_meetings SET matched_by=? WHERE jot_id=?", [result.name, jotID])
            // Tags: those of the tasks linked to the meeting, once it is certain (else Claude suggests some after the save).
            if case .suggested = result { return }
            try copyMeetingTagsRow(jotID, event: event, now: now)
        }
        return result
    }

    /// Meeting notes not attached yet (or only suggested) that arrived in the last 2 days: tried again (their event may
    /// have synced since).
    public func attachPendingMeetingNotes(now: Date = Date()) {
        let ids = (try? store.db.query("SELECT jot_id FROM jot_meetings WHERE matched_by IN ('', 'suggested') AND received>?", // try?-ok: unreadable = tried on the next pass
                                       [now.addingTimeInterval(-2 * 86400)]) { DB.int($0, 0) }) ?? [] // try?-ok: unreadable = tried on the next pass
        for id in ids { attachMeetingNotes(id, now: now) }
    }

    /// ✓ on a suggested meeting: the link becomes the owner's.
    public func confirmMeeting(_ jotID: Int64, event: Int64, now: Date = Date()) {
        store.link(ShortID(kind: .jot, number: jotID), ShortID(kind: .event, number: event), kind: .notesOf, madeBy: .manual, actor: .user, now: now)
        store.perform {
            try store.db.run("UPDATE jot_meetings SET matched_by='confirmed' WHERE jot_id=?", [jotID])
            try copyMeetingTagsRow(jotID, event: event, now: now)
        }
    }

    /// An untagged meeting notes jot takes the tags of the tasks linked to its meeting.
    private func copyMeetingTagsRow(_ jotID: Int64, event: Int64, now: Date) throws {
        let me = ShortID(kind: .jot, number: jotID)
        guard store.itemTags(me).all.isEmpty else { return }
        let tags = store.knownTags(tasks(ofEvent: event).flatMap { store.itemTags(ShortID(kind: .task, number: $0)).all })
        if let p = tags.first { try store.setTagsRow(me, primary: p, others: Array(tags.dropFirst()), now: now) }
    }

    /// Tasks linked to an event: by a link, or the task whose own event it is.
    func tasks(ofEvent event: Int64) -> [Int64] {
        var out = store.links(of: ShortID(kind: .event, number: event)).filter { $0.kind == .task }.map(\.number)
        if let own = CalendarCache(store: store).event(shortID: event)?.fbCard { out.append(own) }
        return Array(Set(out)).sorted().filter { store.card($0) != nil }
    }

    /// Meeting notes jots (not deleted) attached to an event (auto, suggested or by hand).
    public func meetingNotes(forEvent event: Int64) -> [Jot] {
        store.links(of: ShortID(kind: .event, number: event)).filter { $0.kind == .jot }.compactMap { jot($0.number) }
            .filter { !$0.deleted && $0.kind == .meetingNotes }.sorted { $0.added < $1.added }
    }

    /// The meeting notes a task shows in its notes section (read-only): those of the meetings the task is linked to.
    public func meetingNotes(forTask taskID: Int64) -> [Jot] {
        var events = store.links(of: ShortID(kind: .task, number: taskID)).filter { $0.kind == .event }.map(\.number)
        if let card = store.card(taskID), !card.gcalEvent.isEmpty,
           let own = try? store.db.query("SELECT short_id FROM cal_events WHERE account=? AND event_id=?", [card.gcalAccount, card.gcalEvent], { DB.int($0, 0) }) { // try?-ok: unreadable = the own event's notes are not shown
            events += own
        }
        var seen = Set<Int64>()
        return events.flatMap { meetingNotes(forEvent: $0) }.filter { seen.insert($0.id).inserted }
    }
}
