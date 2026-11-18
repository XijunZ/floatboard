import Foundation

/// The Decisions area's registrations with the foundation (item lookup, search, weekly review). Called once at launch and by
/// the checks; registering again replaces.
@MainActor public enum DecisionsArea {
    public static func registerCore() {
        ItemCatalog.register(.decision) { store, n in
            DecisionStore(store: store).decision(n).map {
                ItemSummary(id: $0.shortID, title: $0.text, added: $0.added, updated: $0.updated, source: $0.source, deleted: $0.deleted)
            }
        }
        GlobalSearch.register(.decision, module: .decisions) { store, q in
            DecisionStore(store: store).all().filter { GlobalSearch.matches(DecisionStore.searchText($0), q) }.map {
                SearchHit(id: $0.shortID, title: $0.text, detail: "\($0.status.title) · \($0.type.title) · from \($0.sourceLabel)", date: $0.recorded)
            }
        }
        DecisionReviews.registerSections()
        // A Make decision queued by an older phone script (a jot action, before the phone had its own form) never opens a
        // form on the Mac and never waits: it is kept as a Maybe draft linked to the jot, to finish on the Decisions tab.
        JotActions.makeDecision = { store, text, source in
            let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            guard !line.isEmpty else { return true }
            let d = DecisionStore(store: store).record(DecisionDraft(text: String(line.prefix(300)), quote: String(text.prefix(4000)), status: .maybe,
                                                                     source: .phone, sourceItem: source))
            guard let d else { return false }   // not written (the error is in Activity): not acknowledged, it comes again
            store.activity("decisions", .info, "Kept a Make decision from the phone as a Maybe draft", detail: d.shortID.text)
            return true
        }
    }
}
