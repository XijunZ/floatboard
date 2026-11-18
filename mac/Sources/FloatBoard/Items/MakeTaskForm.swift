import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// The task form opened by "Make task" on a selection: filled in from it (title, notes, the source's tags); Save makes the
/// task and links it back to where the text came from.
struct MakeTaskForm: View {
    let request: MakeTaskRequest
    var close: () -> Void
    @State private var saveProblem: String?
    @EnvironmentObject var store: Store
    @State private var draft = TaskDraft(title: "", notes: "", primaryTag: nil, others: [])
    @State private var hasDue = false
    @State private var day = Date()
    @State private var hasTime = false
    @State private var time = Due.nextHour
    /// What the form opened with (code), so Claude's fill never replaces what the owner already changed.
    @State private var opened: (title: String, hasDue: Bool, day: Date, hasTime: Bool)?
    @State private var claudeNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make task").font(.system(size: 13, weight: .semibold))
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            TagEditor(primary: Binding(get: { draft.primaryTag ?? store.resolve("") }, set: { draft.primaryTag = $0 }), others: $draft.others)
            HStack { DueFields(hasDue: $hasDue, day: $day, hasTime: $hasTime, time: $time) }
            if let n = claudeNote { Label(n, systemImage: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let s = request.source, let item = store.item(s) {
                Text("Links back to \(s.text) · \(item.title)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let saveProblem { Text(saveProblem).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Make task") {
                    // Closes only once the task is saved; a failed write (in Activity) keeps the form and its fields.
                    if store.makeTask(draft, due: hasDue ? Due.combine(day: day, time: hasTime ? time : nil) : nil, dueHasTime: hasDue && hasTime,
                                      from: request.source) != nil { close() }
                    else { saveProblem = "Couldn't make the task (see Activity). Your fields are still here; try again." }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear {
            draft = MakeTask.draft(selection: request.selection, sourceTags: request.source.map(store.itemTags), groups: store.areas.map(\.name))
            // The due date the selection mentions (code), then Claude's shorter title and due date (Jots J7, fill_form).
            if let due = MakeTask.dueMentioned(in: request.selection) {
                hasDue = true; day = due.date; hasTime = due.hasTime
                if due.hasTime { time = due.date }
            }
            opened = (draft.title, hasDue, day, hasTime)
        }
        .task { await claudeFill() }
    }

    /// Claude fills the title and due date while Jots is on and an engine with a Claude key is connected; a field the owner
    /// has already changed is left as it is.
    private func claudeFill() async {
        guard store.isOn(.jots), let client = JotsAI.client(store: store) else { return }
        let context = request.source.flatMap { $0.kind == .jot ? JotStore(store: store).jot($0.number)?.text : nil } ?? ""
        guard let f = try? await client.fillForm(selection: request.selection, context: context) else { return } // try?-ok: without Claude the form keeps what code filled in
        guard let o = opened else { return }
        var changed = false
        let title = f.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, draft.title == o.title, title != draft.title { draft.title = title; changed = true }
        if let due = f.due, hasDue == o.hasDue, day == o.day, hasTime == o.hasTime {
            hasDue = true; day = due; hasTime = f.hasTime
            if f.hasTime { time = due }
            changed = true
        }
        if changed { claudeNote = "Filled in by Claude; check before saving." }
    }
}
