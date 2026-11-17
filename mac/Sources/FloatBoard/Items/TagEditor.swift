import FloatBoardCore
import SwiftUI

/// A task's tags: its group (the primary tag: colour and board column) and any other tags. "Make primary" on another tag
/// swaps them.
struct TagEditor: View {
    @Binding var primary: String
    @Binding var others: [String]
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Group").foregroundStyle(.secondary)
            Dropdown(options: store.areas.map(\.name), selection: Binding(get: { primary }, set: { new in
                others.removeAll { $0.caseInsensitiveCompare(new) == .orderedSame }
                primary = new
            }), dot: store.color)
            Text("Tags").foregroundStyle(.secondary).padding(.leading, 8)
            ForEach(others, id: \.self) { t in
                HStack(spacing: 3) {
                    Circle().fill(store.color(t)).frame(width: 7, height: 7)
                    Text(t).lineLimit(1)
                    Button { others.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless).help("Remove this tag")
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contextMenu {
                    if store.areas.contains(where: { $0.name == t }) {
                        Button("Make primary (\(t) becomes the group)") {
                            let old = primary
                            primary = t
                            others = others.map { $0 == t ? old : $0 }
                        }
                    }
                }
            }
            Menu {
                ForEach(store.tags.map(\.name).filter { n in n != primary && !others.contains(n) }, id: \.self) { n in
                    Button(n) { others.append(n) }
                }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().help("Add a tag")
        }
        .font(.system(size: 12))
    }
}
