import Foundation

/// "Not a decision" teaches the Decisions rulebook (features §7 mitigation, §9): the dismissed quote is added as an example
/// line to the owner's copy of the rulebook (`rulebook_decisions`, the same versioned, restorable copy as the email and chat
/// rulebooks). No AI call. An empty copy means "the built-in one": it is started from the built-in text RulebookSync noted.
@MainActor public enum DecisionRulebook {
    public static let settingsKey = "rulebook_decisions"
    public nonisolated static let heading = "## Examples you marked"
    static let maxQuote = 200

    /// `- Not a decision: "<quote>" (marked <type>)`, the quote cut to 200 characters on one line.
    public static func exampleLine(_ d: Decision) -> String {
        var q = (d.quote.isEmpty ? d.text : d.quote).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        if q.count > maxQuote { q = String(q.prefix(maxQuote - 1)) + "…" }
        return "- Not a decision: \"\(q)\" (was marked \(d.type.rawValue))"
    }

    /// The copy with the examples added under the heading (each once). nil when there is nothing to start from yet (no copy and
    /// the built-in text not known): the examples wait.
    public nonisolated static func withExamples(current: String, builtIn: String?, examples: [String]) -> String? {
        let mine = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var text = mine.isEmpty ? builtIn?.trimmingCharacters(in: .whitespacesAndNewlines) : mine, !text.isEmpty else { return nil }
        let lines = Set(text.components(separatedBy: "\n"))
        let new = examples.filter { !lines.contains($0) }
        guard !new.isEmpty else { return text }
        if !text.contains(heading) {
            text += "\n\n\(heading)\nThe owner said these are not decisions. Do not record anything like them.\n"
        } else if !text.hasSuffix("\n") { text += "\n" }
        return text + new.joined(separator: "\n")
    }

    /// The built-in text the connector's copy is based on, as RulebookSync noted it.
    static func builtIn(_ store: Store, connector: String) -> String? {
        (try? store.db.query("SELECT value FROM meta WHERE key=?", ["rulebook.base.\(connector).\(settingsKey)"]) { DB.text($0, 0) })?.first // try?-ok: not known yet = the examples wait
    }

    /// Examples not yet written into the rulebook.
    public static func pending(store: Store) -> [String] {
        (try? store.db.query("SELECT text FROM decision_examples WHERE applied IS NULL ORDER BY id") { DB.text($0, 0) }) ?? [] // try?-ok: unreadable = none waiting this time; they stay queued
    }

    /// Writes waiting examples into the connector's copy (a new version you can restore). Returns how many were written.
    @discardableResult
    public static func applyPending(store: Store, connector id: String, builtIn given: String? = nil, now: Date = Date()) -> Int {
        let waiting = pending(store: store)
        guard !waiting.isEmpty, let info = store.connectors.first(where: { $0.id == id }) else { return 0 }
        let current = info.settings[settingsKey] as? String ?? ""
        guard let text = withExamples(current: current, builtIn: given ?? builtIn(store, connector: id), examples: waiting) else { return 0 }
        do {
            if text != current.trimmingCharacters(in: .whitespacesAndNewlines) {
                try store.saveConnectorSettings(connector: id, values: [settingsKey: text], now: now, source: .you,
                                                note: "\(waiting.count) \"Not a decision\" example\(waiting.count == 1 ? "" : "s") added")
            }
            try store.db.run("UPDATE decision_examples SET applied=?, connector=? WHERE applied IS NULL", [now, id])
            store.reload()
            return waiting.count
        } catch {
            store.activity("decisions", .warning, "Could not add \"Not a decision\" examples to the Decisions rulebook; will try again", detail: "\(error)")
            return 0
        }
    }
}
