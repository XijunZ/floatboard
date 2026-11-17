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

/// An action the phone queued: answer a review, or "Not a decision".
public struct PhoneDecisionAction: Codable, Equatable {
    public let id: String
    public let decision: String
    public let action: String
    public let happened: String?
    public let sound: String?
    public let madeAt: String?
    enum CodingKeys: String, CodingKey { case id, decision, action, happened, sound, madeAt = "made_at" }
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

    /// Applies the phone's actions. Returns the ids applied and those skipped (with why). A review answer becomes a jot made on
    /// the phone; a review already answered, or a decision gone, is skipped. Repeats are harmless.
    public static func apply(_ actions: [PhoneDecisionAction], store: Store, now: Date = Date()) -> (applied: [String], skipped: [(String, String)]) {
        var applied: [String] = [], skipped: [(String, String)] = []
        let ds = DecisionStore(store: store)
        for a in actions {
            guard let id = ShortID.parse(a.decision), id.kind == .decision, let d = ds.decision(id.number) else {
                skipped.append((a.id, "decision not found")); continue
            }
            switch a.action {
            case "review":
                if d.reviewState == .done { applied.append(a.id); continue }    // already answered (a repeat)
                if d.deleted { skipped.append((a.id, "decision removed")); continue }
                if DecisionReviews.answer(d.id, happened: a.happened ?? "", sound: a.sound ?? "", source: .phone, store: store, now: now) != nil {
                    applied.append(a.id)
                } else { skipped.append((a.id, "empty answer")) }
            case "not_decision":
                if !d.deleted { ds.notADecision(d.id, now: now) }
                applied.append(a.id)
            default:
                skipped.append((a.id, "unknown action"))
            }
        }
        return (applied, skipped)
    }

    /// The hash of the copy an engine last accepted (so an unchanged copy is not sent again).
    public static func sentHash(store: Store, connector: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", ["decisions.phone_hash.\(connector)"]) { DB.text($0, 0) })?.first // try?-ok: unknown = send again
    }

    public static func setSentHash(_ hash: String, store: Store, connector: String) {
        store.perform { try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", ["decisions.phone_hash.\(connector)", hash]) }
    }
}
