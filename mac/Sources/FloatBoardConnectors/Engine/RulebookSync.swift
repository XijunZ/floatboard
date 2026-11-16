import FloatBoardCore
import Foundation

/// Your copies of the rulebooks (Settings › Rules & learning). Empty means "the built-in one". Once you edit a copy, a
/// newer built-in rulebook (a FloatBoard update) is merged into it the same way learning is: lines you changed stay as
/// you wrote them; only lines you never touched take the new wording. Each merge is a version you can restore.
public enum RulebookSync {
    /// Engine rulebook key → settings key.
    public static let keys = ["email": "rulebook_email", "chat": "rulebook_chat"]

    static func baseKey(_ connector: String, _ key: String) -> String { "rulebook.base.\(connector).\(key)" }

    /// The built-in text your copy was last based on.
    @MainActor public static func base(_ connector: String, _ key: String, store: Store) -> String? {
        try? store.db.query("SELECT value FROM meta WHERE key=?", [baseKey(connector, key)]) { DB.text($0, 0) }.first // try?-ok: no base yet
    }

    @MainActor public static func setBase(_ text: String, _ connector: String, _ key: String, store: Store) {
        do { try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [baseKey(connector, key), text]) } catch {
            store.activity("instructions", .warning, "Could not note which built-in rulebook your copy is based on", detail: "\(error)")
        }
    }

    /// Merges a newer built-in rulebook into your copies. Called after syncs; cheap (one small request).
    @MainActor public static func refresh(connector id: String, store: Store, books: [Rulebook]) {
        guard let info = store.connectors.first(where: { $0.id == id }) else { return }
        for b in books {
            guard let key = keys[b.key] else { continue }
            let mine = (info.settings[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let old = base(id, key, store: store)
            defer { setBase(b.text, id, key, store: store) }
            guard !mine.isEmpty, let old, old != b.text else { continue } // following the built-in, or nothing new
            let merged = Instructions.mergeLearned(base: old, current: mine, incoming: b.text)
            guard merged != mine else { continue }
            do {
                try store.saveConnectorSettings(connector: id, values: [key: merged], source: .builtin, note: "built-in rulebook updated; your edits kept")
            } catch {
                store.activity("instructions", .warning, "Couldn't bring the updated built-in rulebook into your copy", detail: "\(error)")
            }
        }
    }
}
