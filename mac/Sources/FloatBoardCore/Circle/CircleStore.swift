import Foundation

/// Circle on top of the people core (features §3, §9): a person's details and handles, the metadata readers' exchanges,
/// "I contacted them" / "We talked" / snooze, bulk changes, and suggestions. Merges are in CircleMerge.swift.
@MainActor public struct CircleStore {
    let store: Store
    public init(store: Store) { self.store = store }

    public static let maxActiveProspects = 5

    public struct AddResult { public let person: Person?; public let problem: String? }

    var people: PeopleStore { PeopleStore(store: store) }

    // MARK: Details

    static let detailColumns = """
        how_known, company, role, birthday, language, notes, interval_days, firm, focus, purpose, stage, stage_at, snoozed_until,
        reminded_at, reminder_task, updates_on, news_muted, feed_url, officer_id, officer_name, officer_confirmed, manual_checked
        """

    public func details(_ personID: Int64) -> CircleDetails {
        do {
            return try store.db.query("SELECT \(Self.detailColumns) FROM circle_people WHERE person_id=?", [personID]) { Self.readDetails($0) }.first
                ?? CircleDetails()
        } catch {
            store.activity("circle", .error, "Could not read a person's details", detail: "\(error)")
            return CircleDetails()
        }
    }

    /// Every person's details (people without a row are left out).
    public func allDetails() -> [Int64: CircleDetails] {
        do {
            return Dictionary(uniqueKeysWithValues: try store.db.query("SELECT person_id, \(Self.detailColumns) FROM circle_people") { s in
                (DB.int(s, 0), Self.readDetails(s, offset: 1)) })
        } catch {
            store.activity("circle", .error, "Could not read people's details", detail: "\(error)")
            return [:]
        }
    }

    static func readDetails(_ s: OpaquePointer, offset o: Int32 = 0) -> CircleDetails {
        var d = CircleDetails()
        d.howKnown = DB.text(s, o); d.company = DB.text(s, o + 1); d.role = DB.text(s, o + 2); d.birthday = DB.text(s, o + 3)
        d.language = DB.text(s, o + 4); d.notes = DB.text(s, o + 5)
        d.intervalDays = DB.isNull(s, o + 6) ? nil : Int(DB.int(s, o + 6))
        d.firm = DB.text(s, o + 7); d.focus = DB.text(s, o + 8); d.purpose = DB.text(s, o + 9); d.stage = DB.text(s, o + 10)
        d.stageAt = DB.date(s, o + 11); d.snoozedUntil = DB.date(s, o + 12); d.remindedAt = DB.date(s, o + 13)
        d.reminderTask = DB.isNull(s, o + 14) ? nil : DB.int(s, o + 14)
        d.updatesOn = DB.int(s, o + 15) != 0; d.newsMuted = DB.int(s, o + 16) != 0; d.feedURL = DB.text(s, o + 17)
        d.officerID = DB.text(s, o + 18); d.officerName = DB.text(s, o + 19); d.officerConfirmed = DB.date(s, o + 20)
        d.manualChecked = DB.date(s, o + 21)
        return d
    }

    func writeDetailsRow(_ personID: Int64, _ d: CircleDetails) throws {
        try store.db.run("""
            INSERT OR REPLACE INTO circle_people(person_id, \(Self.detailColumns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [personID, d.howKnown, d.company, d.role, d.birthday, d.language, d.notes, d.intervalDays.map { Int64($0) }, d.firm, d.focus,
                  d.purpose, d.stage, d.stageAt, d.snoozedUntil, d.remindedAt, d.reminderTask, d.updatesOn ? 1 : 0, d.newsMuted ? 1 : 0,
                  d.feedURL, d.officerID, d.officerName, d.officerConfirmed, d.manualChecked])
    }

    /// Saves Circle's fields. Refused (with the reason) when it would make a sixth active prospect.
    @discardableResult
    public func save(_ personID: Int64, _ d: CircleDetails, now: Date = Date()) -> String? {
        var d = d
        let tags = store.itemTags(ShortID(kind: .person, number: personID)).all
        if let p = prospectProblem(personID: personID, tags: tags, details: &d, now: now) { return p }
        store.perform { try writeDetailsRow(personID, d) }
        return nil
    }

    /// Prospects: a stage is kept (want to meet when none was given) and at most five are active.
    private func prospectProblem(personID: Int64?, tags: [String], details d: inout CircleDetails, now: Date) -> String? {
        guard tags.contains(where: { $0.caseInsensitiveCompare(TagRules.prospect) == .orderedSame }) else { return nil }
        if ProspectStage(rawValue: d.stage) == nil { d.stage = ProspectStage.wantToMeet.rawValue }
        let old = personID.map { details($0) }
        if old?.stage != d.stage { d.stageAt = now }
        guard ProspectStage(rawValue: d.stage)?.active == true else { return nil }
        let others = activeProspects().filter { $0.id != personID }
        return others.count >= Self.maxActiveProspects ? "You already have \(Self.maxActiveProspects) active prospects. Move one to dropped first." : nil
    }

    /// Live people tagged Prospect whose stage isn't dropped.
    public func activeProspects() -> [Person] {
        let ids = Set(store.items(taggedAny: [TagRules.prospect], kind: .person).map(\.number))
        let all = allDetails()
        return people.people().filter { ids.contains($0.id) && ProspectStage(rawValue: all[$0.id]?.stage ?? "")?.active != false }
    }

    // MARK: Adding a person (P2)

    /// Adds a person with tier, tags, details and handles, after the fixed-tag and prospect rules. A phone or email that
    /// already belongs to someone merges the new person into them (P4); the result is then that person.
    public func add(name: String, aliases: [String] = [], tier: PersonTier, tags: ItemTags, details: CircleDetails, handles: [Handle],
                    source: ItemSource = .typed, now: Date = Date()) -> AddResult {
        if let p = TagRules.problems(tags: tags.all, tier: tier).first { return AddResult(person: nil, problem: p) }
        var d = details
        if let p = prospectProblem(personID: nil, tags: tags.all, details: &d, now: now) { return AddResult(person: nil, problem: p) }
        guard let person = people.create(name: name, aliases: aliases, tier: tier, source: source, now: now) else {
            return AddResult(person: nil, problem: "A person needs a name.")
        }
        if !tags.all.isEmpty, let p = store.setTags(person.shortID, primary: tags.primary ?? tags.all.first, others: tags.others, tier: tier, now: now) {
            store.activity("circle", .warning, "Some tags were not added to \(person.name)", detail: p)
        }
        store.perform { try writeDetailsRow(person.id, d) }
        var result = person
        for h in handles {
            if case .merged(let into) = addHandle(result.id, h, now: now), let p = people.person(into) { result = p }
        }
        return AddResult(person: people.person(result.id) ?? result, problem: nil)
    }

    // MARK: Handles (P4)

    public func handles(_ personID: Int64) -> [Handle] {
        do {
            return try store.db.query("SELECT kind, value FROM person_handles WHERE person_id=? ORDER BY kind, id", [personID]) { s in
                HandleKind(rawValue: DB.text(s, 0)).map { Handle(kind: $0, value: DB.text(s, 1)) } }.compactMap { $0 }
        } catch {
            store.activity("circle", .error, "Could not read a person's handles", detail: "\(error)")
            return []
        }
    }

    /// Every handle by person (one read).
    public func allHandles() -> [Int64: [Handle]] {
        var out: [Int64: [Handle]] = [:]
        do {
            for (pid, h) in try store.db.query("SELECT person_id, kind, value FROM person_handles ORDER BY id", [], { s in
                (DB.int(s, 0), HandleKind(rawValue: DB.text(s, 1)).map { Handle(kind: $0, value: DB.text(s, 2)) }) }) {
                if let h { out[pid, default: []].append(h) }
            }
        } catch { store.activity("circle", .error, "Could not read handles", detail: "\(error)") }
        return out
    }

    /// The live person a handle belongs to (raw or normalised input).
    public func person(owning raw: Handle) -> Int64? {
        guard let v = Handles.normalize(raw.kind, raw.value) else { return nil }
        let id = (try? store.db.query(""" // try?-ok: unreadable = nobody; the next read tries again
            SELECT h.person_id FROM person_handles h JOIN people p ON p.id=h.person_id WHERE h.kind=? AND h.value=? AND p.deleted=0
            """, [raw.kind.rawValue, v]) { DB.int($0, 0) })?.first
        return id
    }

    /// Adds a handle. Another live person's phone or email: this person is merged into them (automatic, split undoes it).
    /// Another person's handle of any other kind: refused, naming them (a suggestion, never a merge).
    @discardableResult
    public func addHandle(_ personID: Int64, _ raw: Handle, now: Date = Date()) -> HandleResult {
        guard let v = Handles.normalize(raw.kind, raw.value) else { return .refused("That isn't a valid \(raw.kind.title.lowercased()).") }
        let h = Handle(kind: raw.kind, value: v)
        let owner = (try? store.db.query( // try?-ok: unreadable = no owner; the insert below then reports
            "SELECT h.person_id, p.deleted FROM person_handles h LEFT JOIN people p ON p.id=h.person_id WHERE h.kind=? AND h.value=?",
                                         [h.kind.rawValue, h.value]) { (DB.int($0, 0), DB.int($0, 1) != 0) })?.first
        if let (other, deleted) = owner {
            if other == personID { return .exists }
            if !deleted {
                if h.kind.mergesOnMatch {
                    if let why = merge(kept: other, merged: personID, auto: true, now: now) { return .refused(why) }
                    return .merged(into: other)
                }
                return .refused("\(h.kind.title) \(h.value) is already on \(people.person(other)?.name ?? "someone else") (P-\(other)). Merge them if they are one person.")
            }
            // A deleted person's handle moves to the live one.
            store.perform { try store.db.run("UPDATE person_handles SET person_id=?, added=? WHERE kind=? AND value=?", [personID, now, h.kind.rawValue, h.value]) }
            return .added
        }
        store.perform {
            try store.db.run("INSERT INTO person_handles(person_id, kind, value, added) VALUES(?,?,?,?)", [personID, h.kind.rawValue, h.value, now])
        }
        return .added
    }

    public func removeHandle(_ personID: Int64, _ h: Handle) {
        store.perform { try store.db.run("DELETE FROM person_handles WHERE person_id=? AND kind=? AND value=?", [personID, h.kind.rawValue, h.value]) }
    }

    // MARK: Exchanges (metadata only)

    /// The stored key: one row per channel, handle, day and direction (a meeting by its own key).
    static func key(_ e: ExchangeInput) -> String {
        if let k = e.key { return k }
        return "\(e.channel.rawValue):\(e.handle.kind.rawValue):\(e.handle.value):\(Due.dayString(e.at)):\(e.direction.rawValue)"
    }

    /// Records what the readers saw (who, when, channel, direction). Each row keeps the day's latest time and a name.
    public func record(_ inputs: [ExchangeInput], now: Date = Date()) {
        guard !inputs.isEmpty else { return }
        store.perform {
            for e in inputs {
                guard let v = Handles.normalize(e.handle.kind, e.handle.value) else { continue }
                var n = e; n.handle = Handle(kind: e.handle.kind, value: v)
                try insertExchange(channel: n.channel, direction: n.direction, at: n.at, handleKind: v.isEmpty ? "" : n.handle.kind.rawValue,
                                   handle: v, name: String(n.name.prefix(200)), key: Self.key(n), ref: n.ref, now: now)
            }
        }
    }

    func insertExchange(channel: Channel, direction: Direction, at: Date, handleKind: String, handle: String, name: String, key: String,
                        ref: String, now: Date) throws {
        try store.db.run("""
            INSERT INTO circle_exchanges(channel, direction, at, handle_kind, handle, name, key, ref, added) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET at=max(at, excluded.at), name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE name END,
                ref=CASE WHEN excluded.ref<>'' THEN excluded.ref ELSE ref END
            """, [channel.rawValue, direction.rawValue, at, handleKind, handle, name, key, ref, now])
    }

    private static let exchangeColumns = "e.id, e.channel, e.direction, e.at, e.handle_kind, e.handle, e.name, e.ref, e.ignored"

    private static func readExchange(_ s: OpaquePointer, _ o: Int32) -> Exchange? {
        guard let ch = Channel(rawValue: DB.text(s, o + 1)), let dir = Direction(rawValue: DB.text(s, o + 2)) else { return nil }
        let handle = HandleKind(rawValue: DB.text(s, o + 4)).map { Handle(kind: $0, value: DB.text(s, o + 5)) }
        return Exchange(id: DB.int(s, o), channel: ch, direction: dir, at: DB.date(s, o + 3) ?? .distantPast, handle: handle,
                        name: DB.text(s, o + 6), ref: DB.text(s, o + 7), ignored: DB.int(s, o + 8) != 0)
    }

    /// A person's exchanges (their handles' and those made by hand), newest first; corrected ones included (`ignored`).
    public func exchanges(of personID: Int64) -> [Exchange] {
        do {
            return try store.db.query("""
                SELECT \(Self.exchangeColumns) FROM circle_exchanges e
                WHERE (e.handle_kind, e.handle) IN (SELECT kind, value FROM person_handles WHERE person_id=?)
                   OR (e.handle_kind='person' AND e.handle=?)
                ORDER BY e.at DESC, e.id DESC
                """, [personID, String(personID)]) { Self.readExchange($0, 0) }.compactMap { $0 }
        } catch {
            store.activity("circle", .error, "Could not read a person's exchanges", detail: "\(error)")
            return []
        }
    }

    /// Everyone's exchanges in one read (the list and the due list).
    public func allExchanges() -> [Int64: [Exchange]] {
        var out: [Int64: [Exchange]] = [:]
        do {
            let rows = try store.db.query("""
                SELECT h.person_id, \(Self.exchangeColumns) FROM circle_exchanges e JOIN person_handles h ON h.kind=e.handle_kind AND h.value=e.handle
                UNION ALL
                SELECT CAST(e.handle AS INTEGER), \(Self.exchangeColumns) FROM circle_exchanges e WHERE e.handle_kind='person'
                """) { s in (DB.int(s, 0), Self.readExchange(s, 1)) }
            for (pid, e) in rows { if let e { out[pid, default: []].append(e) } }
        } catch { store.activity("circle", .error, "Could not read exchanges", detail: "\(error)") }
        return out
    }

    /// Corrects a meeting that didn't happen (or puts it back).
    public func setIgnored(_ exchangeID: Int64, _ ignored: Bool) {
        store.perform { try store.db.run("UPDATE circle_exchanges SET ignored=? WHERE id=?", [ignored ? 1 : 0, exchangeID]) }
    }

    /// "I contacted them": outreach by hand (calls, in person, a channel FloatBoard can't see outgoing on).
    public func contacted(_ personID: Int64, at: Date = Date()) { manual(personID, .outgoing, at) }

    /// "We talked": a call or a meeting in person, counted as a conversation.
    public func talked(_ personID: Int64, at: Date = Date()) { manual(personID, .met, at) }

    private func manual(_ personID: Int64, _ dir: Direction, _ at: Date) {
        store.perform {
            try insertExchange(channel: .manual, direction: dir, at: at, handleKind: "person", handle: String(personID), name: "",
                               key: "manual:\(personID):\(Due.dayString(at)):\(dir.rawValue)", ref: "", now: at)
        }
    }

    /// Snooze or ✗: pushed back one interval from now.
    public func snooze(_ personID: Int64, now: Date = Date()) {
        guard let p = people.person(personID) else { return }
        var d = details(personID)
        let interval = CircleClock.interval(tier: p.tier, tags: store.itemTags(p.shortID).all, intervalDays: d.intervalDays)
        d.snoozedUntil = CircleClock.add(interval, to: now)
        store.perform { try writeDetailsRow(personID, d) }
    }

    public func clocks(_ p: Person, now: Date = Date()) -> Clocks {
        let d = details(p.id)
        return CircleClock.clocks(exchanges: exchanges(of: p.id), added: p.added, tier: p.tier, tags: store.itemTags(p.shortID).all,
                                  intervalDays: d.intervalDays, snoozedUntil: d.snoozedUntil, now: now)
    }

    /// Everyone's clocks in a few reads.
    public func allClocks(now: Date = Date()) -> [Int64: Clocks] {
        let ex = allExchanges(), det = allDetails()
        var out: [Int64: Clocks] = [:]
        for p in people.people() {
            let d = det[p.id] ?? CircleDetails()
            out[p.id] = CircleClock.clocks(exchanges: ex[p.id] ?? [], added: p.added, tier: p.tier, tags: store.itemTags(p.shortID).all,
                                           intervalDays: d.intervalDays, snoozedUntil: d.snoozedUntil, now: now)
        }
        return out
    }

    // MARK: Bulk changes (P1)

    /// Sets the tier of several people. Problems (worded per person) are returned; those people are left as they were.
    @discardableResult
    public func setTier(_ ids: [Int64], _ tier: PersonTier) -> [String] {
        var problems: [String] = []
        for id in ids {
            guard var p = people.person(id) else { continue }
            if let why = TagRules.problems(tags: store.itemTags(p.shortID).all, tier: tier).first { problems.append("\(p.name): \(why)"); continue }
            p.tier = tier
            people.update(p)
        }
        return problems
    }

    @discardableResult
    public func addTags(_ ids: [Int64], _ names: [String]) -> [String] { changeTags(ids) { $0 + names } }

    @discardableResult
    public func removeTags(_ ids: [Int64], _ names: [String]) -> [String] {
        let drop = Set(names.map { $0.lowercased() })
        return changeTags(ids) { $0.filter { !drop.contains($0.lowercased()) } }
    }

    private func changeTags(_ ids: [Int64], _ f: ([String]) -> [String]) -> [String] {
        var problems: [String] = []
        for id in ids {
            guard let p = people.person(id) else { continue }
            let now = store.itemTags(p.shortID)
            var next: [String] = []
            for t in f(now.all) where !next.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { next.append(t) }
            let primary = next.first { $0.caseInsensitiveCompare(now.primary ?? "") == .orderedSame } ?? next.first
            if let why = store.setTags(p.shortID, primary: primary, others: next.filter { $0 != primary }, tier: p.tier) {
                problems.append("\(p.name): \(why)")
            }
        }
        return problems
    }

    // MARK: Suggestions (P3, P4)

    /// Handles nobody in Circle has, with messages both ways (1:1 chats and emails), newest first; dismissed ones left out.
    public func conversationSuggestions() -> [HandleSuggestion] {
        do {
            let dismissed = Set(try store.db.query("SELECT key FROM circle_dismissed") { DB.text($0, 0) })
            let rows = try store.db.query("""
                SELECT e.handle_kind, e.handle, group_concat(DISTINCT e.channel), count(*), max(e.at),
                       (SELECT x.name FROM circle_exchanges x WHERE x.handle_kind=e.handle_kind AND x.handle=e.handle AND x.name<>'' ORDER BY x.at DESC LIMIT 1)
                FROM circle_exchanges e
                WHERE e.handle_kind<>'person' AND e.ignored=0 AND e.direction IN ('in','out')
                  AND NOT EXISTS (SELECT 1 FROM person_handles h JOIN people p ON p.id=h.person_id WHERE h.kind=e.handle_kind AND h.value=e.handle AND p.deleted=0)
                GROUP BY e.handle_kind, e.handle
                HAVING sum(e.direction='in')>0 AND sum(e.direction='out')>0
                ORDER BY max(e.at) DESC LIMIT 100
                """) { s -> HandleSuggestion? in
                guard let k = HandleKind(rawValue: DB.text(s, 0)) else { return nil }
                let chans = DB.text(s, 2).split(separator: ",").compactMap { Channel(rawValue: String($0)) }
                return HandleSuggestion(handle: Handle(kind: k, value: DB.text(s, 1)), name: DB.text(s, 5), channels: chans.sorted { $0.rawValue < $1.rawValue },
                                        exchanges: Int(DB.int(s, 3)), last: DB.date(s, 4) ?? .distantPast)
            }
            return rows.compactMap { $0 }.filter { !dismissed.contains($0.key) }
        } catch {
            store.activity("circle", .error, "Could not work out suggested people", detail: "\(error)")
            return []
        }
    }

    /// Two live people with the same name (case and accents ignored), or one whose name is the other's alias.
    public func mergeSuggestions() -> [MergeSuggestion] {
        let dismissed = Set(((try? store.db.query("SELECT key FROM circle_dismissed") { DB.text($0, 0) }) ?? [])) // try?-ok: unreadable = none dismissed; shown again
        let all = people.people()
        var out: [MergeSuggestion] = []
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                let reason: String?
                if PeopleStore.key(a.name) == PeopleStore.key(b.name) { reason = "Same name" }
                else if a.aliases.contains(where: { PeopleStore.key($0) == PeopleStore.key(b.name) })
                            || b.aliases.contains(where: { PeopleStore.key($0) == PeopleStore.key(a.name) }) { reason = "Also known as" }
                else { reason = nil }
                if let reason {
                    let s = MergeSuggestion(a: min(a.id, b.id), b: max(a.id, b.id), reason: reason)
                    if !dismissed.contains(s.key) { out.append(s) }
                }
            }
        }
        return out
    }

    /// Says no to a suggestion (a merge pair, a handle, a candidate) for good.
    public func dismiss(_ key: String, now: Date = Date()) {
        store.perform { try store.db.run("INSERT OR REPLACE INTO circle_dismissed(key, at) VALUES(?,?)", [key, now]) }
    }

    // MARK: Readers' state

    public struct ChannelStatus: Equatable {
        public let channel: String
        public let asOf: Date?
        public let completeFrom: Date?
        public let cursor: String
        public let note: String
    }

    public func channels() -> [ChannelStatus] {
        do {
            return try store.db.query("SELECT channel, as_of, complete_from, cursor, note FROM circle_channels ORDER BY channel") { s in
                ChannelStatus(channel: DB.text(s, 0), asOf: DB.date(s, 1), completeFrom: DB.date(s, 2), cursor: DB.text(s, 3), note: DB.text(s, 4))
            }
        } catch {
            store.activity("circle", .error, "Could not read the readers' state", detail: "\(error)")
            return []
        }
    }

    public func channel(_ name: String) -> ChannelStatus? { channels().first { $0.channel == name } }

    public func setChannel(_ name: String, asOf: Date?, completeFrom: Date?, cursor: String, note: String = "") {
        store.perform {
            try store.db.run("INSERT OR REPLACE INTO circle_channels(channel, as_of, complete_from, cursor, note) VALUES(?,?,?,?,?)",
                             [name, asOf, completeFrom, cursor, note])
        }
    }

    /// How far back the readers go the first time (Settings; default 12 months).
    public var backfillMonths: Int {
        let v = (try? store.db.query("SELECT value FROM meta WHERE key='circle_backfill_months'") { DB.text($0, 0) })?.first // try?-ok: unreadable = default
        return v.flatMap(Int.init).map { max(1, min(60, $0)) } ?? 12
    }

    public func setBackfillMonths(_ m: Int) {
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('circle_backfill_months', ?)", [String(max(1, min(60, m)))]) }
    }

    func meta(_ key: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) })?.first // try?-ok: unreadable = unset
    }

    func setMeta(_ key: String, _ value: String?) {
        store.perform {
            if let value { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [key, value]) }
            else { try store.db.run("DELETE FROM meta WHERE key=?", [key]) }
        }
    }
}
