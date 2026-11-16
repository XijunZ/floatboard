import Foundation

/// The instructions FloatBoard follows, as versions with a log (docs/architecture.md, Edition 2, C8).
/// Three parts are versioned: your own rules (`my_rules`), your WhatsApp rules (`chat_rules`) and what FloatBoard has
/// learned (`learned`). Every change is a new row in `instructions`; nothing is overwritten. The current text stays
/// in the connector's settings, as before, so the engine gets it the same way.
public enum Instructions {
    public static let parts = ["my_rules", "chat_rules", "learned", "rulebook_email", "rulebook_chat"]

    /// `builtin`: a new built-in rulebook merged into your copy (your edits kept).
    public enum Source: String, Sendable { case start, you, learning, restore, builtin }

    public struct Version: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let part: String
        public let text: String
        public let source: Source
        public let note: String
        public let at: Date
    }

    /// One line per rule: trimmed, blank lines dropped, a leading "- " ignored when comparing.
    public static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func key(_ line: String) -> String {
        (line.hasPrefix("- ") ? String(line.dropFirst(2)) : line).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// What changed from `old` to `new`, per line: added lines and removed lines.
    public static func diff(_ old: String, _ new: String) -> (added: [String], removed: [String]) {
        let o = lines(old), n = lines(new)
        let ok = Set(o.map(key)), nk = Set(n.map(key))
        return (n.filter { !ok.contains(key($0)) }, o.filter { !nk.contains(key($0)) })
    }

    /// A learning run's text merged with your edits (design C8 / review 5): `base` is the last text learning produced,
    /// `current` is what is stored now, `incoming` is the new learning text. If you haven't edited since `base`, the
    /// new text is taken as it is. Otherwise your edit wins: lines you removed stay removed and lines you added stay,
    /// and learning's own changes apply to everything else.
    public static func mergeLearned(base: String, current: String, incoming: String) -> String {
        let mine = diff(base, current)
        guard !mine.added.isEmpty || !mine.removed.isEmpty else { return incoming }
        let removed = Set(mine.removed.map(key))
        var out = lines(incoming).filter { !removed.contains(key($0)) }
        let have = Set(out.map(key))
        out += mine.added.filter { !have.contains(key($0)) }
        return out.joined(separator: "\n")
    }

    /// "+ survey requests aren't tasks; − newsletters from X are tasks" (or "wording changed").
    public static func summary(_ old: String, _ new: String) -> String {
        let d = diff(old, new)
        func plain(_ l: String) -> String { l.hasPrefix("- ") ? String(l.dropFirst(2)) : l }
        let parts = d.added.map { "+ " + plain($0) } + d.removed.map { "− " + plain($0) }
        return parts.isEmpty ? "wording changed" : parts.joined(separator: "; ")
    }
}

extension Store {
    /// Records a change to one part: the first change of a part also records what it was before ("start"), so the
    /// history always begins with the text you had. Nothing is recorded when the text is unchanged. Call inside a
    /// transaction.
    func recordInstructions(connector: String, part: String, old: String, new: String,
                            source: Instructions.Source, note: String = "", at: Date) throws {
        guard Instructions.parts.contains(part), old != new else { return }
        let count = try db.query("SELECT count(*) FROM instructions WHERE connector=? AND part=?", [connector, part]) { DB.int($0, 0) }.first ?? 0
        if count == 0, !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try db.run("INSERT INTO instructions(connector,part,text,source,note,at) VALUES(?,?,?,?,?,?)",
                       [connector, part, old, Instructions.Source.start.rawValue, "what you had before versions were kept", at.addingTimeInterval(-1)])
        }
        try db.run("INSERT INTO instructions(connector,part,text,source,note,at) VALUES(?,?,?,?,?,?)",
                   [connector, part, new, source.rawValue, note, at])
    }

    /// Every version of `part`, newest first.
    public func instructionVersions(connector: String, part: String) -> [Instructions.Version] {
        do {
            return try db.query("SELECT id,text,source,note,at FROM instructions WHERE connector=? AND part=? ORDER BY at DESC, id DESC",
                                [connector, part]) {
                Instructions.Version(id: DB.int($0, 0), part: part, text: DB.text($0, 1),
                                     source: Instructions.Source(rawValue: DB.text($0, 2)) ?? .you, note: DB.text($0, 3),
                                     at: DB.date($0, 4) ?? Date())
            }
        } catch {
            activity("instructions", .warning, "Could not read the history of your instructions", detail: "\(error)")
            return []
        }
    }

    /// The text learning last produced (the base for merging your edits), or nil when learning hasn't produced any.
    func lastLearnedBase(connector: String) throws -> String? {
        try db.query("SELECT text FROM instructions WHERE connector=? AND part='learned' AND source IN ('learning','start') ORDER BY at DESC, id DESC LIMIT 1",
                     [connector]) { DB.text($0, 0) }.first
    }

    /// Puts an earlier version back as the current text (a new version; nothing is deleted).
    public func restoreInstructions(connector: String, version: Instructions.Version) throws {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM HH:mm"
        try saveConnectorSettings(connector: connector, values: [version.part: version.text],
                                  source: .restore, note: "restored the version from \(f.string(from: version.at))")
    }
}
