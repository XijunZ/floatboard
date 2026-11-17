import FloatBoardCore
import SwiftUI

/// Search everything (toolbar): every kind of item by words or an id. A task opens on the board (found and outlined), an
/// event on its day in the Calendar; other kinds open where their area says (until then their id is copied).
struct GlobalSearchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    var initialQuery = ""
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let results = GlobalSearch.run(query, store: store)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search everything: words, or an id such as T-12", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty {
                Text("Nothing found.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results, id: \.0) { kind, hits in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.noun.capitalized + "s").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            ForEach(hits) { h in
                                Button { open(h) } label: {
                                    HStack(spacing: 6) {
                                        Text(h.id.text).monospacedDigit().foregroundStyle(.secondary)
                                        Text(h.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(h.detail).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(12)
        .frame(width: 440)
        .onAppear { if query.isEmpty { query = initialQuery }; focused = true }
    }

    /// Opens a result where it lives.
    private func open(_ h: SearchHit) {
        ui.showGlobalSearch = false
        switch h.id.kind {
        case .task:
            ui.tab = .board
            ui.search = h.id.text
        case .event:
            ui.calendarFocus = h.date
            ui.tab = .calendar
        default:
            if let handler = GlobalSearchOpen.handlers[h.id.kind] { handler(h.id) } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(h.id.text, forType: .string)
            }
        }
    }
}

/// How each area opens one of its items from search (registered by the area: its tab, scrolled to the item).
@MainActor enum GlobalSearchOpen {
    static var handlers: [ItemKind: (ShortID) -> Void] = [:]
}
