import FloatBoardCore
import SwiftUI

/// In a task's editor: the notes of the meetings the task is linked to (J9), read-only and selectable (right-click a
/// selection: Make task, Make decision, Copy id link). Separate from the task's own notes (§9).
struct TaskMeetingNotes: View {
    let taskID: Int64
    var maxHeight: CGFloat = 120
    @EnvironmentObject var store: Store

    var body: some View {
        let notes = store.isOn(.jots) ? JotStore(store: store).meetingNotes(forTask: taskID) : []
        ForEach(notes) { j in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Meeting notes").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(j.shortID.text).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Button("Open") { OpenJot.go(j.id) }.buttonStyle(.link).font(.system(size: 10))
                }
                ScrollView { SelectableText(j.text, source: j.shortID) }
                    .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// Opens a jot in the Jots tab from anywhere (the board window opens on that tab).
@MainActor enum OpenJot {
    static weak var ui: UIState?
    static func go(_ id: Int64) {
        ui?.mode = .expanded
        ui?.tab = .jots
        DispatchQueue.main.async { NotificationCenter.default.post(name: .floatBoardOpenJot, object: id) }
    }
}
