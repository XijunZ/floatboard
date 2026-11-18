import Foundation

/// One decision as the phone shows it (More › Decisions, features §10): read-only, plus what it needs for its two actions.
public struct PhoneDecision: Codable, Equatable {
    public let id: String
    public let text: String
    public let quote: String
    public let source: String
    public let recorded: String
    public let decided: String
    public let type: String
    public let status: String
    public let foundBy: String
    public let why: String
    public let expected: String
    public let expectedLater: Bool
    public let confidence: String
    public let confidenceLater: Bool
    public let tags: [String]
    public let people: [String]
    public let reviewDue: String?
    /// due / scheduled / off / done
    public let review: String
    /// Recorded into FloatBoard this week (the phone offers "Not a decision" on these and on Maybe ones).
    public let thisWeek: Bool
    enum CodingKeys: String, CodingKey {
        case id, text, quote, source, recorded, decided, type, status, why, expected, confidence, tags, people, review
        case foundBy = "found_by", expectedLater = "expected_later", confidenceLater = "confidence_later", reviewDue = "review_due", thisWeek = "this_week"
    }
}

/// An action the phone queued: answer a review, "Not a decision", or "make" (a new decision from the phone's Make decision
/// form on a jot: its four fields, type, the selected words and the jot, by `J-n` or the jot's key).
public struct PhoneDecisionAction: Codable, Equatable {
    public let id: String
    public let decision: String
    public let action: String
    public let happened: String?
    public let sound: String?
    public let madeAt: String?
    public var text: String? = nil
    public var why: String? = nil
    public var expected: String? = nil
    public var confidence: String? = nil
    public var type: String? = nil
    public var quote: String? = nil
    public var source: String? = nil
    enum CodingKeys: String, CodingKey { case id, decision, action, happened, sound, madeAt = "made_at", text, why, expected, confidence, type, quote, source }
    public init(id: String, decision: String, action: String, happened: String? = nil, sound: String? = nil, madeAt: String? = nil) {
        self.id = id; self.decision = decision; self.action = action; self.happened = happened; self.sound = sound; self.madeAt = madeAt
    }
}

/// The phone's copy of Decisions and how its actions are applied (the Mac stays the record).
@MainActor public enum DecisionPhone {
    public static let maxDecisions = 300
    static let windowDays = 180.0

    /// Live decisions (and Maybe ones) recorded in the last 180 days, plus every one whose review is due within a week; newest
    /// first, at most 300. Empty while Decisions is off.
    public static func copy(store: Store, now: Date = Date()) -> [PhoneDecision] {
        guard store.isOn(.decisions) else { return [] }
        let ds = DecisionStore(store: store)
        let week = WeeklyReview.week(containing: now)
        let soon = now.addingTimeInterval(7 * 86400)
        let dueIDs = Set(DecisionReviews.due(store: store, by: now).map(\.id))
        let list = ds.all().filter { d in
            d.recorded >= now.addingTimeInterval(-windowDays * 86400) || d.added >= now.addingTimeInterval(-windowDays * 86400)
                || (d.reviewState == .scheduled && (d.reviewDue ?? .distantFuture) <= soon)
        }.prefix(maxDecisions)
        return list.map { d in
            PhoneDecision(id: d.shortID.text, text: d.text, quote: d.quote, source: d.sourceLabel, recorded: Due.dayString(d.recorded),
                          decided: d.decided, type: d.type.rawValue, status: d.status.rawValue, foundBy: d.foundByClaude ? "claude" : "you",
                          why: d.why, expected: d.expected, expectedLater: d.expectedAdded != nil, confidence: d.confidence?.rawValue ?? "",
                          confidenceLater: d.confidenceAdded != nil, tags: store.itemTags(d.shortID).all, people: ds.people(of: d.id).map(\.name),
                          reviewDue: d.reviewDue.map(Due.dayString),
                          review: dueIDs.contains(d.id) ? "due" : d.reviewState.rawValue, thisWeek: week.contains(d.added))
        }
    }

    /// How long a phone decision waits for its jot to reach this Mac before it is recorded without the link.
    public static let sourceWait: TimeInterval = 86400

    /// Applies the phone's actions. Returns the ids applied, those skipped (with why) and those left waiting (not acked: a
    /// phone decision whose jot has not reached this Mac yet, for at most `sourceWait`). A review answer becomes a jot made on
    /// the phone; a review already answered, or a decision gone, is skipped. Repeats are harmless.
    public static func apply(_ actions: [PhoneDecisionAction], store: Store, now: Date = Date())
        -> (applied: [String], skipped: [(String, String)], waiting: [String]) {
        var applied: [String] = [], skipped: [(String, String)] = [], waiting: [String] = []
        let ds = DecisionStore(store: store)
        for a in actions {
            if a.action == "make" {
                switch make(a, store: store, now: now) {
                case .recorded: applied.append(a.id)
                case .invalid(let why): skipped.append((a.id, why))   // acknowledged and dropped: it can never be recorded
                case .later: waiting.append(a.id)                     // not acknowledged: the engine keeps it for the next sync
                }
                continue
            }
            // Acknowledged only once what it asks for is kept: a read or write that fails leaves it on the engine (waiting).
            guard let id = ShortID.parse(a.decision), id.kind == .decision else { skipped.append((a.id, "decision not found")); continue }
            do {
                guard try ds.decisionOrThrow(id.number) != nil else { skipped.append((a.id, "decision not found")); continue }
                switch a.action {
                case "review":
                    switch try DecisionReviews.answerOrThrow(id.number, happened: a.happened ?? "", sound: a.sound ?? "", source: .phone, store: store, now: now, keepLater: true) {
                    case .saved, .alreadyAnswered: applied.append(a.id)      // a repeat is acknowledged too
                    case .invalid(let why): skipped.append((a.id, why))
                    }
                case "not_decision":
                    try ds.notADecisionOrThrow(id.number, now: now)
                    applied.append(a.id)
                default:
                    skipped.append((a.id, "unknown action"))
                }
            } catch {
                store.activity("decisions", .error, "Could not take in a change from the phone; it stays on the engine and is tried again",
                               detail: "\(a.decision): \(error)")
                waiting.append(a.id)
            }
        }
        return (applied, skipped, waiting)
    }

    /// What became of a phone decision: recorded (or already recorded: a repeat), invalid (can never be recorded: acknowledge
    /// and drop), or later (its jot is on its way, or this Mac could not write it: leave it on the engine, not acknowledged).
    enum MakeOutcome: Equatable { case recorded, invalid(String), later }

    /// Records a decision from the phone's Make decision form: made by you on the phone, linked to its jot (`J-n` or the jot's
    /// key) with the jot's tags. While Decisions is off it is kept as a Maybe draft (nothing is dropped, nothing waits on the
    /// switch). The decision and its repeat marker are written in one transaction, so it is acknowledged only once both are kept.
    static func make(_ a: PhoneDecisionAction, store: Store, now: Date) -> MakeOutcome {
        let doneKey = "decisions.phone_made:\(a.id)"
        let seen: String?
        do { seen = try store.db.query("SELECT value FROM meta WHERE key=?", [doneKey]) { DB.text($0, 0) }.first } catch {
            store.activity("decisions", .error, "Could not check a decision from the phone; it waits for the next sync", detail: "\(error)")
            return .later
        }
        if seen != nil { return .recorded }
        let text = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid("empty decision") }
        let made = a.madeAt.flatMap { ISO8601DateFormatter().date(from: $0) ?? fractionalISO.date(from: $0) } ?? now
        var source: ShortID?
        if let ref = a.source?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            if let id = ShortID.parse(ref), id.kind == .jot, JotStore(store: store).jot(id.number) != nil { source = id }
            else if let j = JotStore(store: store).jot(origin: ref) { source = j.shortID }
            else if now.timeIntervalSince(made) < sourceWait { return .later }   // its jot is on its way: try at the next sync
            else { store.activity("decisions", .warning, "A decision from the phone was recorded without its jot (the jot never reached this Mac)", detail: a.id) }
        }
        let on = store.isOn(.decisions)
        var draft = DecisionDraft(text: text, quote: a.quote ?? "", why: a.why ?? "", expected: a.expected ?? "",
                                  confidence: a.confidence.flatMap(Confidence.init(rawValue:)), type: a.type.flatMap(DecisionType.init(rawValue:)) ?? .operational,
                                  status: on ? .decided : .maybe, foundByClaude: false, source: .phone, sourceItem: source)
        if draft.quote.count > 4000 { draft.quote = String(draft.quote.prefix(4000)) }
        let recorded = DecisionStore(store: store).record(draft, now: now) { me in
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [doneKey, me.text])
        }
        // A failed write was rolled back and is in Activity (Store.perform): nothing kept, so it stays on the engine.
        guard let d = recorded else { return .later }
        store.activity("decisions", .info, on ? "Recorded a decision made on the phone" : "Kept a decision from the phone as a Maybe draft (Decisions is off)",
                       detail: d.shortID.text)
        return .recorded
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The hash of the copy an engine last accepted (so an unchanged copy is not sent again).
    public static func sentHash(store: Store, connector: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", ["decisions.phone_hash.\(connector)"]) { DB.text($0, 0) })?.first // try?-ok: unknown = send again
    }

    public static func setSentHash(_ hash: String, store: Store, connector: String) {
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", ["decisions.phone_hash.\(connector)", hash]) }
    }
}

/// What this Mac remembers having sent through a connector (round 13, J4): forgotten when the connector is added again or
/// moved to another engine, so the new engine gets everything.
@MainActor public enum ConnectorMemory {
    public static func forget(connector id: String, store: Store) {
        store.perform {
            try store.db.run("DELETE FROM meta WHERE key=?", ["decisions.phone_hash.\(id)"])
            try store.db.run("DELETE FROM meta WHERE key=?", [JotsSyncCore.engineKey])
        }
    }
}
