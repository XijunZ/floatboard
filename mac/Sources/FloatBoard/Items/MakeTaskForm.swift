import FloatBoardCore
import SwiftUI

/// The task form opened by "Make task" on a selection: filled in from it (title, notes, the source's tags); Save makes the
/// task and links it back to where the text came from.
struct MakeTaskForm: View {
    let request: MakeTaskRequest
    var close: () -> Void
    @EnvironmentObject var store: Store
    @State private var draft = TaskDraft(title: "", notes: "", primaryTag: nil, others: [])
    @State private var hasDue = false
    @State private var day = Date()
    @State private var hasTime = false
    @State private var time = Due.nextHour

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make task").font(.system(size: 13, weight: .semibold))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            TagEditor(primary: Binding(get: { draft.primaryTag ?? store.resolve("") }, set: { draft.primaryTag = $0 }), others: $draft.others)
            HStack { DueFields(hasDue: $hasDue, day: $day, hasTime: $hasTime, time: $time) }
            if let s = request.source, let item = store.item(s) {
                Text("Links back to \(s.text) · \(item.title)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Make task") {
                    store.makeTask(draft, due: hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil, dueHasTime: hasDue && hasTime,
                                   from: request.source)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear {
            draft = MakeTask.draft(selection: request.selection, sourceTags: request.source.map(store.itemTags), groups: store.areas.map(\.name))
        }
    }
}
