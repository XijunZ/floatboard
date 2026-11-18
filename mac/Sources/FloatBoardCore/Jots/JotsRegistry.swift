import Foundation

/// What the Jots area registers with the foundation at launch: its kind in "Search everything" (skipped while Jots is off).
@MainActor public enum JotsArea {
    public static func register() {
        GlobalSearch.register(.jot, module: .jots) { store, q in
            JotStore(store: store).list(JotQuery(text: q, limit: 50)).map { r in
                SearchHit(id: r.jot.shortID, title: ItemCatalog.firstLine(r.jot.text),
                          detail: ([r.jot.kind.title] + (r.untagged ? ["untagged"] : r.tags.all)).joined(separator: " · "), date: r.jot.added)
            }
        }
    }
}

/// A hand-off the Decisions area fills in: the phone's "Make decision" on a jot's text (§10) reaches the Mac as an action,
/// and the Mac passes it here. Nil until Decisions registers it; the action then waits on the engine.
@MainActor public enum JotActions {
    /// The legacy phone Make decision. `marker` must run inside the transaction that records the decision (apply-once).
    public static var makeDecision: ((Store, _ text: String, _ source: ShortID, _ marker: @escaping (ShortID) throws -> Void) -> Bool)?
}
