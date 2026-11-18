import FloatBoardCore
import SwiftUI

/// An item's tags (the first is its primary) as chips, with ✕ and a + menu when `editable` (round 13, B4). One view for
/// jots, goals and decisions; names match case-insensitively, as in the people tag menu. `set` saves a new list and returns
/// a problem to show, or nil (default: Store.setTags).
struct ItemTagRow: View {
    let id: ShortID
    var editable = true
    var emptyText: String? = "untagged"
    var set: ((Store, [String]) -> String?)? = nil
    @EnvironmentObject var store: Store
    @Binding var problem: String?

    init(id: ShortID, editable: Bool = true, emptyText: String? = "untagged", problem: Binding<String?> = .constant(nil),
         set: ((Store, [String]) -> String?)? = nil) {
        self.id = id; self.editable = editable; self.emptyText = emptyText; self._problem = problem; self.set = set
    }

    var body: some View {
        let tags = store.itemTags(id).all
        HStack(spacing: 6) {
            Text("Tags").foregroundStyle(.secondary)
            if tags.isEmpty, let emptyText { Text(emptyText).italic().foregroundStyle(.tertiary) }
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    Circle().fill(store.color(t)).frame(width: 7, height: 7)
                    Text(t).lineLimit(1)
                    if editable {
                        Button { save(tags.filter { $0.caseInsensitiveCompare(t) != .orderedSame }) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.borderless).help("Remove this tag")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if editable {
                Menu {
                    ForEach(store.tags.map(\.name).filter { n in !tags.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }, id: \.self) { n in
                        Button(n) { save(tags + [n]) }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Add a tag")
            }
        }
    }

    private func save(_ all: [String]) {
        problem = set.map { $0(store, all) } ?? store.setTags(id, primary: all.first, others: Array(all.dropFirst()))
        store.objectWillChange.send()
    }
}
