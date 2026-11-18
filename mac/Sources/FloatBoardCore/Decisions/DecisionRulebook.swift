import Foundation

/// "Not a decision" teaches the Decisions rulebook (features §7 mitigation, §9): the dismissed quote is added as an example
/// line to the owner's copy of the rulebook (`rulebook_decisions`, the same versioned, restorable copy as the email and chat
/// rulebooks). No AI call. An empty copy means "the built-in one": it is started from the built-in text RulebookSync noted.
@MainActor public enum DecisionRulebook {
    public static let settingsKey = "rulebook_decisions"
    public nonisolated static let heading = "## Examples you marked"
    static let maxQuote = 200
    /// The engine refuses a rulebook longer than this (UTF-16 units, as JavaScript counts), and with it the whole settings push.
    public nonisolated static let engineLimit = 20_000
    /// At most this many examples are kept (the newest); older ones drop out first.
    public nonisolated static let maxExamples = 60

    /// `- Not a decision: "<quote>" (marked <type>)`, the quote cut to 200 characters on one line.
    public static func exampleLine(_ d: Decision) -> String {
        var q = (d.quote.isEmpty ? d.text : d.quote).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        if q.count > maxQuote { q = String(q.prefix(maxQuote - 1)) + "…" }
        return "- Not a decision: \"\(q)\" (was marked \(d.type.rawValue))"
    }

    static let intro = "The owner said these are not decisions. Do not record anything like them."
    static let examplePrefix = "- Not a decision:"

    /// The copy with the examples added under the heading (each once), keeping only the newest `maxExamples` and never
    /// longer than the engine accepts (oldest examples drop out first). nil when there is nothing to start from yet (no copy
    /// and the built-in text not known), or when the copy is too long to take any example: the examples then wait.
    public nonisolated static func withExamples(current: String, builtIn: String?, examples: [String]) -> String? {
        let mine = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = mine.isEmpty ? builtIn?.trimmingCharacters(in: .whitespacesAndNewlines) : mine, !text.isEmpty else { return nil }
        guard text.utf16.count <= engineLimit else { return nil }
        var head = text, section: [String] = []
        if let r = text.range(of: heading) {
            head = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            section = text[r.upperBound...].components(separatedBy: "\n")
        }
        let old = section.filter { $0.hasPrefix(examplePrefix) }
        let other = section.filter { !$0.hasPrefix(examplePrefix) && !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != intro }
        let new = examples.filter { !old.contains($0) }
        guard !new.isEmpty else { return text }
        var all: [String] = []
        for e in old + new where !all.contains(e) { all.append(e) }
        all = Array(all.suffix(maxExamples))
        func build(_ list: [String]) -> String { ([head, "", heading, intro] + other + list).joined(separator: "\n") }
        while !all.isEmpty && build(all).utf16.count > engineLimit { all.removeFirst() }
        guard !all.isEmpty, all.contains(where: { new.contains($0) }) else { return nil }
        return build(all)
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
        guard let text = withExamples(current: current, builtIn: given ?? builtIn(store, connector: id), examples: waiting) else {
            if current.utf16.count > engineLimit - 300 {
                store.activity("decisions", .warning, "The Decisions rulebook is too long to take \"Not a decision\" examples",
                               detail: "Shorten it in Settings › Rules & learning; the examples wait until then.")
            }
            return 0
        }
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
