import Foundation

/// What's new for a person (P11): LinkedIn changes, Companies House, news (person and firm kept apart), blog posts.
public enum UpdateKind: String, CaseIterable, Codable {
    case linkedin, directorship, appointment, resignation, newsPerson = "news_person", newsFirm = "news_firm", post
    public var title: String {
        switch self {
        case .linkedin: "LinkedIn"; case .directorship: "Director"; case .appointment: "New appointment"; case .resignation: "Resigned"
        case .newsPerson: "News about them"; case .newsFirm: "News about their firm"; case .post: "Post"
        }
    }
    public var isNews: Bool { self == .newsPerson || self == .newsFirm }
}

/// The owner's mark on a news item. News stays "possible" (`none`) until marked; opening it doesn't count (§9).
public enum Verdict: String, Codable { case none = "", right, wrong }

public struct CircleUpdate: Identifiable, Equatable {
    public let id: Int64
    public let personID: Int64
    public let kind: UpdateKind
    public let title: String
    public let detail: String
    public let url: String
    public let at: Date?
    public let found: Date
    /// "possible" (shown) or "unlikely" (set aside by Claude: shown on request).
    public let match: String
    public let verdict: Verdict
}

/// One result from the engine (`GET /v2/circle/updates`). `officer_candidate` rows carry `officer` and `born`.
public struct EngineUpdate: Codable, Equatable {
    public let seq: Int64
    public let person: String
    public let kind: String
    public let key: String
    public let title: String
    public let detail: String
    public let url: String
    public let at: String?
    public let match: String
    public let born: String?
    public let officer: String?
    public init(seq: Int64, person: String, kind: String, key: String, title: String, detail: String, url: String, at: String?, match: String,
                born: String?, officer: String?) {
        self.seq = seq; self.person = person; self.kind = kind; self.key = key; self.title = title; self.detail = detail; self.url = url
        self.at = at; self.match = match; self.born = born; self.officer = officer
    }
}

/// A Companies House officer who might be the person; never linked until the owner confirms (§9).
public struct OfficerCandidate: Equatable, Identifiable {
    public let officerID: String
    public let name: String
    public let born: String
    public let detail: String
    /// The officer's birth month and year match the person's birthday (shown first; still only a candidate).
    public let bornMatches: Bool
    public var id: String { officerID }
}

extension CircleStore {
    /// Shown updates, newest first. Leaves out news marked wrong, news while muted, and Claude's set-aside items unless asked.
    public func updates(_ personID: Int64, includeSetAside: Bool = false, includeWrong: Bool = false) -> [CircleUpdate] {
        let muted = details(personID).newsMuted
        do {
            return try store.db.query("""
                SELECT id, person_id, kind, title, detail, url, at, found, match, verdict FROM circle_updates WHERE person_id=?
                ORDER BY COALESCE(at, found) DESC, id DESC
                """, [personID]) { s -> CircleUpdate? in
                guard let k = UpdateKind(rawValue: DB.text(s, 2)) else { return nil }
                return CircleUpdate(id: DB.int(s, 0), personID: DB.int(s, 1), kind: k, title: DB.text(s, 3), detail: DB.text(s, 4), url: DB.text(s, 5),
                                    at: DB.date(s, 6), found: DB.date(s, 7) ?? Date(), match: DB.text(s, 8), verdict: Verdict(rawValue: DB.text(s, 9)) ?? .none)
            }.compactMap { $0 }.filter { u in
                guard u.kind.isNews else { return true }
                if muted { return false }
                if u.verdict == .wrong && !includeWrong { return false }
                if u.match == "unlikely" && u.verdict == .none && !includeSetAside { return false }
                return true
            }
        } catch {
            store.activity("circle", .error, "Could not read What's new", detail: "\(error)")
            return []
        }
    }

    /// How many news items Claude set aside for this person (for the "n set aside · Show" line).
    public func setAsideCount(_ personID: Int64) -> Int {
        Int(((try? store.db.query("SELECT count(*) FROM circle_updates WHERE person_id=? AND match='unlikely' AND verdict=''", [personID]) { DB.int($0, 0) }) ?? []).first ?? 0) // try?-ok: unreadable = none shown
    }

    public func setVerdict(_ updateID: Int64, _ v: Verdict) {
        store.perform { try store.db.run("UPDATE circle_updates SET verdict=? WHERE id=?", [v.rawValue, updateID]) }
    }

    public func setNewsMuted(_ personID: Int64, _ muted: Bool) {
        var d = details(personID); d.newsMuted = muted
        store.perform { try writeDetailsRow(personID, d) }
    }

    /// The live person an id names, following merges (an update for a merged person goes to whom they were merged into).
    func livePerson(_ text: String) -> Int64? {
        guard let id = ShortID.parse(text), id.kind == .person else { return nil }
        var n = id.number
        for _ in 0..<5 {
            if let p = people.person(n), !p.deleted { return n }
            guard let kept = ((try? store.db.query("SELECT kept FROM circle_merges WHERE merged=? AND split IS NULL ORDER BY id DESC LIMIT 1", [n]) { DB.int($0, 0) }) ?? []).first // try?-ok: unreadable = unknown person; the update is skipped
            else { return nil }
            n = kept
        }
        return nil
    }

    /// Stores the engine's results once each (by key). Returns how many were new.
    @discardableResult
    public func applyEngineUpdates(_ items: [EngineUpdate], now: Date = Date()) -> Int {
        var added = 0
        store.perform { added = try applyEngineUpdateRows(items, now: now) }
        return added
    }

    /// One page of What's new and its cursor, written together: when the write fails nothing is kept (the old cursor stays,
    /// so the page comes again) and the error is thrown. Returns how many were new.
    @discardableResult
    public func importUpdatePage(_ items: [EngineUpdate], cursorKey: String, cursor: String, now: Date = Date()) throws -> Int {
        try store.performThrowing {
            let n = try applyEngineUpdateRows(items, now: now)
            try store.db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [cursorKey, cursor])
            return n
        }
    }

    /// The body of `applyEngineUpdates`, for callers inside a transaction.
    func applyEngineUpdateRows(_ items: [EngineUpdate], now: Date) throws -> Int {
        var added = 0
        let iso = ISO8601DateFormatter()
        do {
            for u in items {
                guard let pid = livePerson(u.person) else { continue }
                if u.kind == "officer_candidate" {
                    guard let off = u.officer, !off.isEmpty, details(pid).officerID.isEmpty else { continue }
                    let before = try store.db.query("SELECT count(*) FROM officer_candidates WHERE person_id=? AND officer_id=?", [pid, off]) { DB.int($0, 0) }.first ?? 0
                    guard before == 0 else { continue }
                    try store.db.run("INSERT INTO officer_candidates(person_id, officer_id, name, born, detail, found) VALUES(?,?,?,?,?,?)",
                                     [pid, off, String(u.title.prefix(200)), u.born ?? "", String(u.detail.prefix(300)), now])
                    added += 1
                    continue
                }
                guard UpdateKind(rawValue: u.kind) != nil else { continue }
                let at = u.at.flatMap { iso.date(from: $0) }
                let match = u.match == "unlikely" ? "unlikely" : "possible"
                let url = u.url.hasPrefix("https://") || u.url.hasPrefix("http://") ? u.url : ""
                let before = try store.db.query("SELECT count(*) FROM circle_updates WHERE key=?", [u.key]) { DB.int($0, 0) }.first ?? 0
                guard before == 0 else { continue }
                try store.db.run("""
                    INSERT INTO circle_updates(person_id, kind, key, title, detail, url, at, found, match) VALUES(?,?,?,?,?,?,?,?,?)
                    """, [pid, u.kind, u.key, String(u.title.prefix(300)), String(u.detail.prefix(300)), url, at, now, match])
                added += 1
            }
        }
        return added
    }

    /// Officer candidates; those born in the person's birth month and year first.
    public func officerCandidates(_ personID: Int64) -> [OfficerCandidate] {
        let birth = String(details(personID).birthday.prefix(7))
        do {
            return try store.db.query("SELECT officer_id, name, born, detail FROM officer_candidates WHERE person_id=? ORDER BY found, officer_id", [personID]) { s in
                OfficerCandidate(officerID: DB.text(s, 0), name: DB.text(s, 1), born: DB.text(s, 2), detail: DB.text(s, 3),
                                 bornMatches: birth.count == 7 && DB.text(s, 2) == birth)
            }.sorted { ($0.bornMatches ? 0 : 1, $0.officerID) < ($1.bornMatches ? 0 : 1, $1.officerID) }
        } catch {
            store.activity("circle", .error, "Could not read Companies House candidates", detail: "\(error)")
            return []
        }
    }

    /// Binds the person to this officer (the owner confirmed it); other candidates go.
    public func confirmOfficer(_ personID: Int64, _ c: OfficerCandidate, now: Date = Date()) {
        var d = details(personID)
        d.officerID = c.officerID; d.officerName = c.name; d.officerConfirmed = now
        store.perform {
            try writeDetailsRow(personID, d)
            try store.db.run("DELETE FROM officer_candidates WHERE person_id=?", [personID])
        }
    }

    /// Unbinds the officer (wrong person): their Companies House updates go too; a new search finds candidates again.
    public func unlinkOfficer(_ personID: Int64) {
        var d = details(personID)
        d.officerID = ""; d.officerName = ""; d.officerConfirmed = nil
        store.perform {
            try writeDetailsRow(personID, d)
            try store.db.run("DELETE FROM circle_updates WHERE person_id=? AND kind IN ('directorship','appointment','resignation')", [personID])
        }
    }

    /// Updates (P11) are for Investor- and Prospect-tagged people, except Family; others only when turned on by request.
    public func wantsUpdates(_ p: Person, _ d: CircleDetails) -> Bool {
        if d.updatesOn { return true }
        guard p.tier != .family else { return false }
        let tags = store.itemTags(p.shortID).all
        return tags.contains { t in TagRules.fixed.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
    }

    /// Chinese contacts (P13): language Chinese, a WeChat handle, or a name in Chinese characters.
    public func isChineseContact(_ p: Person, _ d: CircleDetails, handles hs: [Handle]) -> Bool {
        let lang = d.language.lowercased()
        return lang.contains("chinese") || lang.contains("mandarin") || lang.contains("cantonese") || lang.hasPrefix("zh") || d.language.contains("中文")
            || hs.contains { $0.kind == .wechat } || p.name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// "Checked today" on a Chinese contact's card.
    public func markChecked(_ personID: Int64, now: Date = Date()) {
        var d = details(personID); d.manualChecked = now
        store.perform { try writeDetailsRow(personID, d) }
    }
}
