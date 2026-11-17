import CryptoKit
import Foundation

/// An earlier decision a jot refers to (a review, or a jot naming `D-n`): sent as a reference, never as a new decision.
public struct ScreenRef: Codable, Equatable {
    public let id: String; public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// One jot version sent for screening. `ref` = "J-7@<version>".
public struct ScreenJot: Codable, Equatable {
    public let ref: String
    public let kind: String
    public let added: String
    public let text: String
    public let references: [ScreenRef]
    public init(ref: String, kind: String, added: String, text: String, references: [ScreenRef]) {
        self.ref = ref; self.kind = kind; self.added = added; self.text = text; self.references = references
    }
}

/// A decision Claude found in a jot. `sure` false = Maybe.
public struct ScreenFound: Codable, Equatable {
    public let quote: String
    public let decision: String
    public let type: String
    public let why: String?
    public let decidedOn: String?
    public let sure: Bool
    enum CodingKeys: String, CodingKey { case quote, decision, type, why, decidedOn = "decided_on", sure }
    public init(quote: String, decision: String, type: String, why: String? = nil, decidedOn: String? = nil, sure: Bool = true) {
        self.quote = quote; self.decision = decision; self.type = type; self.why = why; self.decidedOn = decidedOn; self.sure = sure
    }
}

/// The answer for one jot. `ok` false: Claude's answer could not be read (the version stays unscreened, tried next week).
public struct ScreenResult: Codable, Equatable {
    public let ref: String
    public let ok: Bool
    public let decisions: [ScreenFound]
    public init(ref: String, ok: Bool, decisions: [ScreenFound]) { self.ref = ref; self.ok = ok; self.decisions = decisions }
}

/// What applying a batch did.
public struct ScreenOutcome: Equatable {
    public var recorded: [Int64] = []
    public var maybe: [Int64] = []
    public var references = 0
    public var unreadable = 0
    public var screened = 0
    public init() {}
}

/// D1, the weekly screening (features §4, §7 ⚑, §9): which jot versions are due, how they are batched, and what an answer
/// records. Weekly batch only; each jot version once; jots quoting older decisions are references. The engine call itself is
/// in the Connectors target (`DecisionsEngine`).
@MainActor public enum DecisionScreening {
    /// Due from Sunday 17:00 (app zone), an hour before the weekly review nudge, so the page is ready.
    public static let dueHour = 17
    public nonisolated static let maxJotsPerBatch = 10
    public nonisolated static let maxCharsPerBatch = 40_000
    /// A longer jot is sent cut to this length (meeting notes can be long).
    public static let maxCharsPerJot = 20_000
    static let lastRunKey = "decisions.screened_at"
    static let sinceKey = "decisions.screen_since"

    /// The most recent Sunday 17:00 at or before `now` (app zone).
    public static func lastDueTime(now: Date) -> Date {
        let cal = AppTime.calendar
        let day = cal.startOfDay(for: now)
        let back = (cal.component(.weekday, from: day) + 6) % 7      // days since Sunday
        let sunday = cal.date(byAdding: .day, value: -back, to: day) ?? day
        let at = cal.date(bySettingHour: dueHour, minute: 0, second: 0, of: sunday) ?? sunday
        return at <= now ? at : (cal.date(byAdding: .day, value: -7, to: at) ?? at)
    }

    /// True once a week: from Sunday 17:00 until a run has finished after it.
    public static func isDue(now: Date, lastRun: Date?) -> Bool {
        guard let lastRun else { return true }
        return lastRun < lastDueTime(now: now)
    }

    public static func lastRun(store: Store) -> Date? { metaDate(store, lastRunKey) }

    /// The jot's version: the first 16 hex characters of the SHA-256 of its text.
    public nonisolated static func version(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Live jots added or edited since the last screening (the first time: the last 7 days) whose current version has not been
    /// screened, oldest first, each with the earlier decisions it refers to.
    public static func pending(store: Store, now: Date) -> [ScreenJot] {
        let since = readFrom(store: store, now: now)
        let rows: [(Int64, String, String, Date)]
        do {
            rows = try store.db.query("""
                SELECT id, text, kind, added FROM jots WHERE deleted=0 AND updated>=? AND updated<=? ORDER BY updated, id
                """, [since, now]) { (DB.int($0, 0), DB.text($0, 1), DB.text($0, 2), DB.date($0, 3) ?? now) }
        } catch {
            store.activity("decisions", .error, "Could not read the week's jots for screening", detail: "\(error)")
            return []
        }
        return rows.compactMap { id, text, kind, added in
            let v = version(text)
            guard !isScreened(store, jot: id, version: v), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let refs = references(store, jot: ShortID(kind: .jot, number: id), text: text)
            return ScreenJot(ref: "J-\(id)@\(v)", kind: kind, added: iso(added), text: String(text.prefix(maxCharsPerJot)), references: refs)
        }
    }

    /// Earlier decisions the jot refers to: those it reviews (review-of) and those it names by id.
    static func references(_ store: Store, jot: ShortID, text: String) -> [ScreenRef] {
        let reviewed = store.itemLinks(of: jot).filter { $0.kind == .reviewOf && $0.isSubject && $0.other.kind == .decision }.map(\.other)
        let named = ShortID.mentions(in: text).filter { $0.kind == .decision }
        let ds = DecisionStore(store: store)
        var seen = Set<ShortID>()
        return (reviewed + named).filter { seen.insert($0).inserted }.compactMap { id in
            ds.decision(id.number).map { ScreenRef(id: id.text, text: $0.quote.isEmpty ? $0.text : $0.text + " — \"" + $0.quote + "\"") }
        }
    }

    /// At most `maxJotsPerBatch` jots and `maxCharsPerBatch` characters per request (one Haiku call each).
    public nonisolated static func batches(_ jots: [ScreenJot]) -> [[ScreenJot]] {
        var out: [[ScreenJot]] = [], cur: [ScreenJot] = [], chars = 0
        for j in jots {
            if !cur.isEmpty && (cur.count >= maxJotsPerBatch || chars + j.text.count > maxCharsPerBatch) { out.append(cur); cur = []; chars = 0 }
            cur.append(j); chars += j.text.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Records what one batch's answer found. Sure decisions whose quote is in the jot word for word are recorded as found by
    /// Claude (no confirm step); unsure ones, or ones whose quote can't be found in the jot, go to Maybe. A found decision that
    /// repeats an existing one (a reference: a review quoting it, or an earlier version of the same jot) is not recorded again.
    /// Each readable jot version is marked screened; an unreadable one is left for next week.
    @discardableResult
    public static func apply(_ results: [ScreenResult], sent: [ScreenJot], store: Store, now: Date) -> ScreenOutcome {
        var out = ScreenOutcome()
        let ds = DecisionStore(store: store)
        let js = JotStore(store: store)
        for r in results {
            guard let job = sent.first(where: { $0.ref == r.ref }), let (jotID, v) = parseRef(r.ref) else { continue }
            guard r.ok else { out.unreadable += 1; continue }
            guard let jot = js.jot(jotID), !jot.deleted else { continue }
            var known = ds.all(includeDeleted: true).filter { d in
                d.sourceItem == jot.shortID || job.references.contains { $0.id == d.shortID.text }
            }.flatMap { [$0.quote, $0.text] }
            known += job.references.map(\.text)
            var found = 0
            for f in r.decisions {
                let text = f.decision.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if known.contains(where: { sameDecision($0, f.quote) || sameDecision($0, text) }) { out.references += 1; continue }
                let verified = contains(jot.text, f.quote)
                let draft = DecisionDraft(text: text, quote: verified ? f.quote.trimmingCharacters(in: .whitespacesAndNewlines) : f.quote,
                                          why: f.why ?? "", type: DecisionType(rawValue: f.type.lowercased()) ?? .operational,
                                          status: f.sure && verified ? .decided : .maybe, foundByClaude: true, source: .claude,
                                          sourceItem: jot.shortID, decided: f.decidedOn ?? "")
                guard let d = ds.record(draft, now: now) else { continue }
                if d.status == .maybe { out.maybe.append(d.id) } else { out.recorded.append(d.id) }
                known += [f.quote, text]
                found += 1
            }
            store.perform {
                try store.db.run("INSERT OR IGNORE INTO decision_screened(jot_id, version, screened, found) VALUES(?,?,?,?)", [jotID, v, now, found])
            }
            out.screened += 1
        }
        return out
    }

    /// Where this run reads from: the start of the last complete run (the first time: 7 days ago).
    public static func readFrom(store: Store, now: Date) -> Date { metaDate(store, sinceKey) ?? now.addingTimeInterval(-7 * 86400) }

    /// Notes a finished run: the next one reads jots changed from `started`, or, when some answers were unreadable, from
    /// `readFrom` again so those jots are read next time (versions already screened are skipped).
    public static func finishRun(store: Store, started: Date, readFrom: Date, complete: Bool, now: Date) {
        store.perform {
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [lastRunKey, String(now.timeIntervalSince1970)])
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)",
                             [sinceKey, String((complete ? started : readFrom).timeIntervalSince1970)])
        }
    }

    // MARK: Helpers

    static func parseRef(_ ref: String) -> (Int64, String)? {
        let parts = ref.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = ShortID.parse(parts[0]), id.kind == .jot else { return nil }
        return (id.number, parts[1])
    }

    static func isScreened(_ store: Store, jot: Int64, version: String) -> Bool {
        ((try? store.db.query("SELECT 1 FROM decision_screened WHERE jot_id=? AND version=?", [jot, version]) { DB.int($0, 0) }) ?? []).isEmpty == false // try?-ok: unreadable = not screened; screening is safe to repeat
    }

    /// Lower case, accents gone, only letters and digits separated by single spaces.
    nonisolated static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The quote appears in the text, ignoring spacing, case and punctuation.
    public nonisolated static func contains(_ text: String, _ quote: String) -> Bool {
        let q = normalized(quote)
        return !q.isEmpty && normalized(text).contains(q)
    }

    /// Two texts state the same decision: equal once normalised, or one holds the other (both at least 20 characters).
    nonisolated static func sameDecision(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        return min(x.count, y.count) >= 20 && (x.contains(y) || y.contains(x))
    }

    nonisolated static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func metaDate(_ store: Store, _ key: String) -> Date? {
        let v = (try? store.db.query("SELECT value FROM meta WHERE key=?", [key]) { DB.text($0, 0) })?.first // try?-ok: unknown = never run
        return v.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }
}
