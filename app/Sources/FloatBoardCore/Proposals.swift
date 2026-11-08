import Foundation

public enum ProposalKind: String, Codable {
    case task, summary, learned, withdraw
    /// The user flagged a missed email: `source_key` + `summary` (excerpt/detail) + verdict in `why`. Never makes a card.
    case correction
    /// Answer to a reply draft request: `source_key`, `task_ref` = the request id, `link` when ready, the reason in `why`
    /// when it failed. Never makes a card.
    case draft
}

public struct Provenance: Codable, Equatable {
    public var model: String
    public var skillVersion: String
    public var created: String
    public init(model: String, skillVersion: String, created: String) {
        self.model = model; self.skillVersion = skillVersion; self.created = created
    }
    enum CodingKeys: String, CodingKey { case model, skillVersion = "skill_version", created }
}

/// What the online engine suggests. Decodes the engine's snake_case JSON exactly.
public struct Proposal: Codable, Equatable {
    public var id: String
    public var kind: ProposalKind
    public var sourceKey: SourceKey?
    public var title: String
    public var why: String
    /// "YYYY-MM-DD" (date only) or "YYYY-MM-DDTHH:mm" (wall-clock time in the device's time zone).
    public var due: String?
    public var hasTime: Bool
    public var group: String?
    public var importance: Int
    public var sourceLabel: String
    public var link: String
    public var summary: String?
    public var taskRef: String?
    public var learned: String?
    public var provenance: Provenance

    public init(id: String, kind: ProposalKind, sourceKey: SourceKey?, title: String, why: String, due: String?,
                hasTime: Bool, group: String?, importance: Int, sourceLabel: String, link: String, summary: String?,
                taskRef: String?, learned: String?, provenance: Provenance) {
        self.id = id; self.kind = kind; self.sourceKey = sourceKey; self.title = title; self.why = why; self.due = due
        self.hasTime = hasTime; self.group = group; self.importance = importance; self.sourceLabel = sourceLabel
        self.link = link; self.summary = summary; self.taskRef = taskRef; self.learned = learned
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, sourceKey = "source_key", title, why, due, hasTime = "has_time", group, importance
        case sourceLabel = "source_label", link, summary, taskRef = "task_ref", learned, provenance
    }

    /// id, kind, provenance (model, skill_version, created) are required, and source_key for task / withdraw /
    /// correction / draft. Everything else may be left out and defaults to empty.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ProposalKind.self, forKey: .kind)
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        sourceKey = try c.decodeIfPresent(SourceKey.self, forKey: .sourceKey)
        if sourceKey == nil, [.task, .withdraw, .correction, .draft].contains(kind) {
            throw DecodingError.keyNotFound(CodingKeys.sourceKey, .init(codingPath: c.codingPath,
                debugDescription: "source_key is required for \(kind.rawValue)"))
        }
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
        hasTime = try c.decodeIfPresent(Bool.self, forKey: .hasTime) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group)
        importance = try c.decodeIfPresent(Int.self, forKey: .importance) ?? 1
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        taskRef = try c.decodeIfPresent(String.self, forKey: .taskRef)
        learned = try c.decodeIfPresent(String.self, forKey: .learned)
    }

    /// "provenance.skill_version" / "source_key" etc.: which field made decoding fail.
    static func describe(_ e: Error) -> String {
        guard let de = e as? DecodingError else { return "\(e)" }
        switch de {
        case .keyNotFound(let k, let ctx):
            return "missing " + (ctx.codingPath.map(\.stringValue) + [k.stringValue]).joined(separator: ".")
        case .valueNotFound(_, let ctx), .typeMismatch(_, let ctx), .dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return (path.isEmpty ? "" : path + ": ") + ctx.debugDescription
        @unknown default: return "\(de)"
        }
    }
}

/// One element of a batch: decoding errors are kept per proposal instead of failing the whole array.
struct LossyProposal: Decodable {
    let result: Result<Proposal, Error>
    let id: String?
    private enum IDKey: String, CodingKey { case id }
    init(from d: Decoder) throws {
        do { result = .success(try Proposal(from: d)) } catch { result = .failure(error) }
        // try?-ok: the id is only used to label the warning; a missing one just means no trace id
        id = (try? d.container(keyedBy: IDKey.self).decodeIfPresent(String.self, forKey: .id)) ?? nil // try?-ok: optional parsing of untrusted data, only labels a warning
    }
}

public struct ReconcileSummary: Equatable {
    public var added = 0, refreshed = 0, withdrawn = 0, keptTouched = 0, skippedExisting = 0
    public var summaries = 0, learnedUpdates = 0, corrections = 0
    /// Reply draft results applied to a card (ready or failed).
    public var drafts = 0
    /// Undated proposals (engine items from before send dates were recorded) with no card: never added.
    public var undatedSkipped = 0
    public init(added: Int = 0, refreshed: Int = 0, withdrawn: Int = 0, keptTouched: Int = 0, skippedExisting: Int = 0,
                summaries: Int = 0, learnedUpdates: Int = 0, corrections: Int = 0) {
        self.added = added; self.refreshed = refreshed; self.withdrawn = withdrawn; self.keptTouched = keptTouched
        self.skippedExisting = skippedExisting; self.summaries = summaries; self.learnedUpdates = learnedUpdates
        self.corrections = corrections
    }
}
