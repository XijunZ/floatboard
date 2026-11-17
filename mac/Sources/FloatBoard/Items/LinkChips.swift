import FloatBoardCore
import SwiftUI

/// Every link of an item as a chip row: the other item's id, what the link means and its title, with ✕ to unlink (Undo
/// follows). `except` leaves out kinds of item the view already lists (a task's editor lists its meetings itself).
struct LinkChips: View {
    let item: ShortID
    var except: Set<ItemKind> = []
    @EnvironmentObject var store: Store

    var body: some View {
        let links = store.itemLinks(of: item).filter { !except.contains($0.other.kind) }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Linked").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                ForEach(links, id: \.other) { l in
                    LinkedRow(remove: { store.unlinkWithUndo(item, l.other) }) {
                        let summary = store.item(l.other)
                        (Text("\(l.other.text) · ").foregroundStyle(.secondary).monospacedDigit()
                         + Text(l.kind == .related ? "" : l.kind.label(isSubject: l.isSubject) + " ").foregroundStyle(.secondary)
                         + Text(summary?.title ?? "(not found)").foregroundStyle(summary?.deleted == true ? .secondary : .primary))
                            .lineLimit(1)
                            .help(l.madeBy == .manual ? "Linked by you" : l.madeBy == .auto ? "Linked by FloatBoard" : "Suggested, accepted by you")
                    }
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// "Link removed · Undo" after a ✕ on a link chip.
struct UndoUnlinkBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let u = store.lastUnlinked {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Unlinked \(u.a.text) and \(u.b.text)").lineLimit(1)
                Button("Undo") { store.undoUnlink() }.buttonStyle(.borderedProminent).controlSize(.small)
                Button { store.clearUnlinkUndo() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .task(id: "\(u.a.text)-\(u.b.text)") {
                try? await Task.sleep(for: .seconds(Store.undoBarSeconds)) // try?-ok: cancelled when another unlink replaces this bar
                if !Task.isCancelled { store.clearUnlinkUndo() }
            }
        }
    }
}
