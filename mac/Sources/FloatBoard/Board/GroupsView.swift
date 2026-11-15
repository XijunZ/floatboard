import FloatBoardCore
import SwiftUI

/// "Groups" tab on the full board: add, rename, recolour, reorder and delete groups.
struct GroupsView: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename, recolour, reorder or delete groups. Changes apply to every task in the group. The order here is the order ↑↓ cycles through when adding a task.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.areas) { GroupRow(area: $0, message: $message) }
                }
            }
            HStack(spacing: 8) {
                TextField("New group name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(add)
                Button("Add group", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                if let message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
            }
        }
    }

    private func add() {
        message = store.addArea(newName)
        if message == nil { newName = "" }
    }
}

struct GroupRow: View {
    @EnvironmentObject var store: Store
    let area: FloatBoardCore.Category
    @Binding var message: String?

    @State private var name = ""
    @State private var deleting = false
    @State private var target = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let count = store.taskCount(area.name)
        let index = store.areas.firstIndex(of: area) ?? 0
        HStack(spacing: 10) {
            Circle().fill(area.color).frame(width: 12, height: 12)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($nameFocused)
                .onSubmit(rename)
                .onChange(of: nameFocused) { _, focused in if !focused { rename() } }
            HStack(spacing: 5) {
                ForEach(Palette.colors, id: \.hex) { c in
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: area.colorHex == c.hex ? 2 : 0))
                        .contentShape(Circle())
                        .onTapGesture { store.setColor(area, c.hex) }
                        .help(c.name)
                }
            }
            Text("\(count) task\(count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            BarButton("arrow.up", "Move up") { store.moveArea(area, by: -1) }
                .disabled(index == 0)
            BarButton("arrow.down", "Move down") { store.moveArea(area, by: 1) }
                .disabled(index == store.areas.count - 1)
            if deleting {
                if count > 0 {
                    Text("Move its \(count) task\(count == 1 ? "" : "s") to").font(.system(size: 11))
                    Dropdown(options: store.areas.filter { $0.id != area.id }.map(\.name), selection: $target,
                             dot: store.color)
                }
                Button("Delete \(area.name)") {
                    store.deleteArea(area, moveTasksTo: target)
                    deleting = false
                }
                Button("Cancel") { deleting = false }
            } else {
                BarButton("trash", store.areas.count > 1 ? "Delete group" : "You need at least one group") {
                    target = store.areas.first { $0.id != area.id }?.name ?? ""
                    deleting = true
                }
                .disabled(store.areas.count <= 1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .onAppear { name = area.name }
        .onChange(of: area.name) { _, n in name = n }
    }

    private func rename() {
        message = store.renameArea(area, to: name)
        if message != nil { name = area.name }
    }
}
