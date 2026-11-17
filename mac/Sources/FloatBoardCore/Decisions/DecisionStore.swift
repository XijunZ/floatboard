import Foundation

/// What kind of decision it is (features §4 D3); sets when it is reviewed (D6).
public enum DecisionType: String, CaseIterable, Codable {
    case operational, strategic, investment
    public var title: String { rawValue.capitalized }
    /// Days after the recorded date when it is reviewed (once).
    public var reviewDays: Int { switch self { case .operational: 30; case .strategic: 90; case .investment: 180 } }
}

/// A decision's status (D5). `maybe` is the screening's unsure list (D1), not a status the owner sets.
public enum DecisionStatus: String, CaseIterable, Codable {
    case decided, tentative, reversed, superseded, maybe
    public var title: String { self == .maybe ? "Maybe" : rawValue.capitalized }
    /// The statuses the owner picks on a card.
    public static let owned: [DecisionStatus] = [.decided, .tentative, .reversed, .superseded]
}

public enum Confidence: String, CaseIterable, Codable {
    case low, medium, high
    public var title: String { rawValue.capitalized }
}

/// Whether the decision's review is still to come, turned off for this decision, or answered.
public enum DecisionReviewState: String, CaseIterable { case scheduled, off, done }

/// One recorded decision (`D-n`).
public struct Decision: Identifiable, Equatable {
    public let id: Int64
    public var text: String
    /// The exact words from the source, kept even when the source is edited or deleted.
    public var quote: String
    public var sourceItem: ShortID?
    /// The jot's kind when it was recorded (nil when the source is not a jot): "meeting notes" labels Fathom's.
    public var sourceKind: JotKind?
    /// When the source was written. Reviews count from here.
    public var recorded: Date
    /// "YYYY-MM-DD" only when the text says when it was decided; "" = unknown.
    public var decided: String
    /// "" = not recorded.
    public var why: String
    public var expected: String
    /// Set when the expected outcome was added after the decision was recorded ("added later").
    public var expectedAdded: Date?
    public var confidence: Confidence?
    public var confidenceAdded: Date?
    public var alternatives: String
    public var type: DecisionType
    public var status: DecisionStatus
    /// True when Claude's weekly screening found it.
    public var foundByClaude: Bool
    public var source: ItemSource
    public var reviewState: DecisionReviewState
    public var reviewDue: Date?
    public var reviewAskAfter: Date?
    public var reviewed: Date?
    public var notDecision: Bool
    public var added: Date
    public var updated: Date
    public var deleted: Bool
    public var shortID: ShortID { ShortID(kind: .decision, number: id) }
    /// A screened decision still waiting for the owner's expected outcome and confidence (the weekly review asks once).
    public var needsPrediction: Bool { foundByClaude && (expected.isEmpty || confidence == nil) }
    /// "J-7", or "meeting notes J-7" for Fathom's notes.
    public var sourceLabel: String {
        guard let s = sourceItem else { return "no source" }
        return sourceKind == .meetingNotes ? "meeting notes \(s.text)" : s.text
    }
}

/// What a new decision is made from (the Make decision form, or a screening answer).
public struct DecisionDraft: Equatable {
    public var text: String
    public var quote: String
    public var why: String
    public var expected: String
    public var confidence: Confidence?
    public var alternatives: String
    public var type: DecisionType
    public var status: DecisionStatus
    public var foundByClaude: Bool
    public var source: ItemSource
    public var sourceItem: ShortID?
    /// "YYYY-MM-DD" only when the text says so.
    public var decided: String
    public init(text: String, quote: String = "", why: String = "", expected: String = "", confidence: Confidence? = nil, alternatives: String = "",
                type: DecisionType = .operational, status: DecisionStatus = .decided, foundByClaude: Bool = false, source: ItemSource = .typed,
                sourceItem: ShortID? = nil, decided: String = "") {
        self.text = text; self.quote = quote; self.why = why; self.expected = expected; self.confidence = confidence
        self.alternatives = alternatives; self.type = type; self.status = status; self.foundByClaude = foundByClaude; self.source = source
        self.sourceItem = sourceItem; self.decided = decided
    }
    /// What the why field holds when the text gives no reason.
    public static let notRecorded = "not recorded"
}

/// How the Decisions list is sorted (ground rules: date added, date updated or tag).
public enum DecisionSort: String, CaseIterable { case recorded, updated, tag
    public var title: String { switch self { case .recorded: "Date recorded"; case .updated: "Date updated"; case .tag: "Tag" } }
}

/// The Decisions tab's filters (D8): words, tag, type, status, person. Maybe items show only when asked for.
public struct DecisionFilter: Equatable {
    public var query = ""
    public var tags: Set<String> = []
    public var type: DecisionType?
    public var status: DecisionStatus?
    public var person: ShortID?
    public var sort: DecisionSort = .recorded
    public init(query: String = "", tags: Set<String> = [], type: DecisionType? = nil, status: DecisionStatus? = nil, person: ShortID? = nil,
                sort: DecisionSort = .recorded) {
        self.query = query; self.tags = tags; self.type = type; self.status = status; self.person = person; self.sort = sort
    }
}

/// The decisions table. Every change is one transaction; a failure goes to Activity and changes nothing.
@MainActor public struct DecisionStore {
    let store: Store
    public init(store: Store) { self.store = store }
    static let columns = """
        id, text, quote, source_item, source_kind, recorded, decided, why, expected, expected_added, confidence, confidence_added, alternatives, \
        type, status, found_by, source, review_state, review_due, review_ask_after, reviewed, not_decision, added, updated, deleted
        """

    // MARK: Recording

    /// Records a decision. Its recorded date is the source's date added (now when there is none); it is linked to its source
    /// (auto when Claude found it, else made by you), takes the source's tags, is linked to the people it names, and its review
    /// is scheduled. Empty text records nothing (nil).
    @discardableResult
    public func record(_ d: DecisionDraft, now: Date = Date()) -> Decision? {
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let src = d.sourceItem.flatMap { store.item($0) }
        let recorded = src?.added ?? now
        let kind: JotKind? = d.sourceItem?.kind == .jot ? JotStore(store: store).jot(d.sourceItem!.number)?.kind : nil
        let why = d.why.trimmingCharacters(in: .whitespacesAndNewlines)
        var id: Int64?
        store.perform {
            let n = try store.db.run("""
                INSERT INTO decisions(text, quote, source_item, source_kind, recorded, decided, why, expected, confidence, alternatives, type, status,
                                      found_by, source, review_state, review_due, added, updated)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [text, d.quote, d.sourceItem?.text ?? "", kind?.rawValue ?? "", recorded, Self.validDay(d.decided, notAfter: recorded),
                      why.caseInsensitiveCompare(DecisionDraft.notRecorded) == .orderedSame ? "" : why,
                      d.expected.trimmingCharacters(in: .whitespacesAndNewlines), d.confidence?.rawValue ?? "",
                      d.alternatives.trimmingCharacters(in: .whitespacesAndNewlines), d.type.rawValue, d.status.rawValue,
                      d.foundByClaude ? "claude" : "you", d.source.rawValue, DecisionReviewState.scheduled.rawValue,
                      Self.reviewDate(recorded: recorded, type: d.type), now, now])
            let me = ShortID(kind: .decision, number: n)
            if let s = d.sourceItem, src != nil {
                try store.linkRow(me, s, kind: .source, madeBy: d.foundByClaude ? .auto : .manual, actor: d.foundByClaude ? .connector("decisions") : .user, now: now)
                let tags = store.itemTags(s)
                if let p = tags.all.first {
                    try store.setTagsRow(me, primary: p, others: Array(tags.all.dropFirst()), now: now)
                }
            }
            try linkPeopleRow(me, text: [text, d.quote, why].joined(separator: "\n"), now: now)
            try linkMentionsRow(me, text: Self.typedText(text: text, why: why, expected: d.expected, alternatives: d.alternatives), previous: "",
                                source: d.sourceItem, now: now)
            id = n
        }
        return id.flatMap { decision($0) }
    }

    /// The review date: `type.reviewDays` days after the recorded date (app zone).
    public static func reviewDate(recorded: Date, type: DecisionType) -> Date {
        AppTime.calendar.date(byAdding: .day, value: type.reviewDays, to: recorded) ?? recorded.addingTimeInterval(Double(type.reviewDays) * 86400)
    }

    /// "YYYY-MM-DD" kept only when it is a real day not after `notAfter` (the text can't say it was decided after it was written).
    static func validDay(_ s: String, notAfter: Date) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 10, let d = Due.startOfDay(t), Due.dayString(d) == t else { return "" }
        return d <= AppTime.calendar.startOfDay(for: notAfter) ? t : ""
    }

    /// The owner's own fields of a decision, where a typed id (`R-3`, `P-2`, `J-7`) links it (the quote is the source's text).
    static func typedText(text: String, why: String, expected: String, alternatives: String) -> String {
        [text, why, expected, alternatives].joined(separator: "\n")
    }

    /// Ids typed into the decision's fields link it (the foundation's `linkMentions`: new ids only, related or the area's own
    /// kind, made by you). Its source is left out: that link is already there with its own kind and maker.
    func linkMentionsRow(_ me: ShortID, text: String, previous: String, source: ShortID?, now: Date) throws {
        try store.linkMentionsRow(in: text, previous: previous + (source.map { " " + $0.text } ?? ""), from: me, now: now)
    }

    /// Links people named in the text (code, D7).
    func linkPeopleRow(_ me: ShortID, text: String, now: Date) throws {
        for p in DecisionPeople.named(in: text, people: PeopleStore(store: store).people()) {
            try store.linkRow(me, p.shortID, kind: .related, madeBy: .auto, actor: .connector("decisions"), now: now)
        }
    }

    // MARK: Reading

    public func decision(_ id: Int64) -> Decision? { read("WHERE id=?", [id]).first }

    /// Every decision, newest recorded first. Dismissed ("Not a decision") and deleted ones only with `includeDeleted`.
    public func all(includeDeleted: Bool = false) -> [Decision] {
        read((includeDeleted ? "" : "WHERE deleted=0 ") + "ORDER BY recorded DESC, id DESC", [])
    }

    /// The Decisions tab's list (D8). Maybe items show only when the status filter is Maybe.
    public func list(_ f: DecisionFilter) -> [Decision] {
        var out = all().filter { f.status == nil ? $0.status != .maybe : $0.status == f.status }
        if let t = f.type { out = out.filter { $0.type == t } }
        if !f.tags.isEmpty { out = out.filter { TagFilter.matches(store.itemTags($0.shortID), any: f.tags) } }
        if let p = f.person { out = out.filter { store.links(of: $0.shortID).contains(p) } }
        let q = f.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            if let id = ShortID.parse(q), id.kind == .decision { out = out.filter { $0.id == id.number } }
            else { out = out.filter { GlobalSearch.matches(Self.searchText($0), q) } }
        }
        switch f.sort {
        case .recorded: break
        case .updated: out.sort { ($0.updated, $0.id) > ($1.updated, $1.id) }
        case .tag:
            let tag = { (d: Decision) in store.itemTags(d.shortID).primary?.lowercased() ?? "\u{10FFFF}" }
            out.sort { (tag($0), -$0.recorded.timeIntervalSince1970) < (tag($1), -$1.recorded.timeIntervalSince1970) }
        }
        return out
    }

    static func searchText(_ d: Decision) -> String { [d.text, d.quote, d.why, d.expected, d.alternatives].joined(separator: " ") }

    /// People linked to the decision (D7), by name.
    public func people(of id: Int64) -> [Person] {
        let ps = PeopleStore(store: store)
        return store.links(of: ShortID(kind: .decision, number: id)).filter { $0.kind == .person }.compactMap { ps.person($0.number) }
            .filter { !$0.deleted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The review jots of a decision (links review-of), oldest first.
    public func reviews(of id: Int64) -> [Jot] {
        let js = JotStore(store: store)
        return store.itemLinks(of: ShortID(kind: .decision, number: id)).filter { $0.kind == .reviewOf && !$0.isSubject && $0.other.kind == .jot }
            .compactMap { js.jot($0.other.number) }.filter { !$0.deleted }
    }

    /// Whether the source still says what was quoted: nil when it does (or there is no source), else "source edited" / "source deleted".
    public func sourceNote(_ d: Decision) -> String? {
        guard let s = d.sourceItem, !d.quote.isEmpty else { return nil }
        guard let item = store.item(s) else { return "source deleted" }
        if item.deleted { return "source deleted" }
        guard s.kind == .jot, let j = JotStore(store: store).jot(s.number) else { return nil }
        return DecisionScreening.contains(j.text, d.quote) ? nil : "source edited"
    }

    // MARK: Changing

    /// Saves the owner's edits (text, quote stays, why, expected outcome, confidence, alternatives, type, status, decided). An
    /// expected outcome or confidence added to a decision that was recorded without one is marked "added later". A type change
    /// moves a review that is still to come to the new type's date. Returns false when nothing changed.
    @discardableResult
    public func update(_ d: Decision, now: Date = Date()) -> Bool {
        guard let old = decision(d.id), !old.deleted else { return false }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let expected = d.expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = d.why.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = old.text != text || old.why != why || old.expected != expected || old.confidence != d.confidence
            || old.alternatives != d.alternatives || old.type != d.type || old.status != d.status || old.decided != d.decided
        guard changed else { return false }
        let expectedAdded = old.expectedAdded ?? (old.expected.isEmpty && !expected.isEmpty ? now : nil)
        let confidenceAdded = old.confidenceAdded ?? (old.confidence == nil && d.confidence != nil ? now : nil)
        var due = old.reviewDue
        if old.type != d.type, old.reviewState == .scheduled, old.reviewDue == Self.reviewDate(recorded: old.recorded, type: old.type) {
            due = Self.reviewDate(recorded: old.recorded, type: d.type)
        }
        store.perform {
            try store.db.run("""
                UPDATE decisions SET text=?, why=?, expected=?, expected_added=?, confidence=?, confidence_added=?, alternatives=?, type=?, status=?,
                decided=?, review_due=?, updated=? WHERE id=?
                """, [text, why.caseInsensitiveCompare(DecisionDraft.notRecorded) == .orderedSame ? "" : why, expected, expectedAdded,
                      d.confidence?.rawValue ?? "", confidenceAdded, d.alternatives.trimmingCharacters(in: .whitespacesAndNewlines), d.type.rawValue,
                      d.status.rawValue, Self.validDay(d.decided, notAfter: old.recorded), due, now, d.id])
            if old.text != text { try linkPeopleRow(d.shortID, text: [text, old.quote, why].joined(separator: "\n"), now: now) }
            try linkMentionsRow(d.shortID, text: Self.typedText(text: text, why: why, expected: expected, alternatives: d.alternatives),
                                previous: Self.typedText(text: old.text, why: old.why, expected: old.expected, alternatives: old.alternatives),
                                source: old.sourceItem, now: now)
        }
        return true
    }

    public func setStatus(_ id: Int64, _ s: DecisionStatus, now: Date = Date()) {
        guard var d = decision(id) else { return }
        d.status = s
        update(d, now: now)
    }

    /// "Not a decision" (weekly review, card, phone): the decision is dismissed (its links hidden) and its quote is queued as an
    /// example for the Decisions rulebook (no AI call). Undo (`undoNotADecision`) takes both back while the example is unsent.
    public func notADecision(_ id: Int64, now: Date = Date()) {
        guard let d = decision(id), !d.deleted else { return }
        let example = DecisionRulebook.exampleLine(d)
        store.perform {
            try store.db.run("UPDATE decisions SET not_decision=1, deleted=1, updated=? WHERE id=?", [now, id])
            try store.hideLinks(of: d.shortID)
            try store.db.run("INSERT INTO decision_examples(decision_id, text, created) VALUES(?,?,?)", [id, example, now])
        }
        store.activity("decisions", .info, "\(d.shortID.text) marked not a decision", detail: "Added to the Decisions rulebook's examples at the next sync.")
    }

    public func undoNotADecision(_ id: Int64, now: Date = Date()) {
        guard let d = decision(id), d.notDecision else { return }
        store.perform {
            try store.db.run("UPDATE decisions SET not_decision=0, deleted=0, updated=? WHERE id=?", [now, id])
            try store.unhideLinks(of: d.shortID)
            try store.db.run("DELETE FROM decision_examples WHERE decision_id=? AND applied IS NULL", [id])
        }
    }

    /// Soft delete: the row stays; links are hidden until `undoDelete`.
    public func delete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM decisions WHERE id=?", [id], { DB.int($0, 0) }).first == 0 else { return }
            try store.db.run("UPDATE decisions SET deleted=1, updated=? WHERE id=?", [now, id])
            try store.hideLinks(of: ShortID(kind: .decision, number: id))
        }
    }

    public func undoDelete(_ id: Int64, now: Date = Date()) {
        store.perform {
            guard try store.db.query("SELECT deleted FROM decisions WHERE id=? AND not_decision=0", [id], { DB.int($0, 0) }).first == 1 else { return }
            try store.db.run("UPDATE decisions SET deleted=0, updated=? WHERE id=?", [now, id])
            try store.unhideLinks(of: ShortID(kind: .decision, number: id))
        }
    }

    /// Accepting "replaces D-m" (D5): the link is made (suggested) and the older decision becomes superseded.
    public func acceptSupersedes(_ newer: Int64, replaces older: Int64, now: Date = Date()) {
        let a = ShortID(kind: .decision, number: newer), b = ShortID(kind: .decision, number: older)
        store.link(a, b, kind: .supersedes, madeBy: .suggested, actor: .user, now: now)
        setStatus(older, .superseded, now: now)
        setSuggestion(newer, kind: .supersedes, target: b, state: "accepted")
    }

    // MARK: Suggestions (supersedes, tell / ask)

    public enum SuggestionKind: String, CaseIterable { case supersedes, tell, ask }
    public struct Suggestion: Identifiable, Equatable {
        public let id: Int64; public let decision: Int64; public let kind: SuggestionKind; public let target: ShortID; public let text: String
    }

    /// Adds a suggestion unless the same one was made before (open, accepted or dismissed).
    public func suggest(_ decision: Int64, kind: SuggestionKind, target: ShortID, text: String = "", now: Date = Date()) {
        store.perform {
            try store.db.run("INSERT OR IGNORE INTO decision_suggestions(decision_id, kind, target, text, created) VALUES(?,?,?,?,?)",
                             [decision, kind.rawValue, target.text, text, now])
        }
    }

    public func suggestions(_ decision: Int64) -> [Suggestion] {
        do {
            return try store.db.query("SELECT id, decision_id, kind, target, text FROM decision_suggestions WHERE decision_id=? AND state='open' ORDER BY id",
                                      [decision]) { s -> Suggestion? in
                guard let k = SuggestionKind(rawValue: DB.text(s, 2)), let t = ShortID.parse(DB.text(s, 3)) else { return nil }
                return Suggestion(id: DB.int(s, 0), decision: DB.int(s, 1), kind: k, target: t, text: DB.text(s, 4))
            }.compactMap { $0 }.filter { store.itemExists($0.target) }
        } catch {
            store.activity("decisions", .error, "Could not read a decision's suggestions", detail: "\(error)")
            return []
        }
    }

    public func setSuggestion(_ decision: Int64, kind: SuggestionKind, target: ShortID, state: String) {
        store.perform {
            try store.db.run("UPDATE decision_suggestions SET state=? WHERE decision_id=? AND kind=? AND target=?", [state, decision, kind.rawValue, target.text])
        }
    }

    /// ✓ on a tell / ask suggestion: makes the task (typed, in the decision's primary tag), linked to the decision and the person.
    @discardableResult
    public func acceptTask(_ s: Suggestion, now: Date = Date()) -> Int64? {
        guard s.kind != .supersedes else { return nil }
        let d = ShortID(kind: .decision, number: s.decision)
        let tags = store.itemTags(d)
        let draft = TaskDraft(title: s.text, notes: "", primaryTag: tags.all.first(where: { t in store.areas.contains { $0.name == t } }), others: [])
        let id = store.makeTask(draft, due: nil, dueHasTime: false, from: d, now: now)
        if let id { store.link(ShortID(kind: .task, number: id), s.target, kind: .related, madeBy: .suggested, actor: .user, now: now) }
        setSuggestion(s.decision, kind: s.kind, target: s.target, state: "accepted")
        return id
    }

    // MARK: Rows

    func read(_ tail: String, _ args: [Any?]) -> [Decision] {
        do {
            return try store.db.query("SELECT \(Self.columns) FROM decisions \(tail)", args) { s in
                Decision(id: DB.int(s, 0), text: DB.text(s, 1), quote: DB.text(s, 2), sourceItem: ShortID.parse(DB.text(s, 3)),
                         sourceKind: JotKind(rawValue: DB.text(s, 4)), recorded: DB.date(s, 5) ?? Date(), decided: DB.text(s, 6), why: DB.text(s, 7),
                         expected: DB.text(s, 8), expectedAdded: DB.date(s, 9), confidence: Confidence(rawValue: DB.text(s, 10)),
                         confidenceAdded: DB.date(s, 11), alternatives: DB.text(s, 12), type: DecisionType(rawValue: DB.text(s, 13)) ?? .operational,
                         status: DecisionStatus(rawValue: DB.text(s, 14)) ?? .decided, foundByClaude: DB.text(s, 15) == "claude",
                         source: ItemSource(rawValue: DB.text(s, 16)) ?? .typed, reviewState: DecisionReviewState(rawValue: DB.text(s, 17)) ?? .scheduled,
                         reviewDue: DB.date(s, 18), reviewAskAfter: DB.date(s, 19), reviewed: DB.date(s, 20), notDecision: DB.int(s, 21) != 0,
                         added: DB.date(s, 22) ?? Date(), updated: DB.date(s, 23) ?? Date(), deleted: DB.int(s, 24) != 0)
            }
        } catch {
            store.activity("decisions", .error, "Could not read decisions", detail: "\(error)")
            return []
        }
    }
}
