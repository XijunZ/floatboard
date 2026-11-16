import FloatBoardCore
import SwiftUI

/// The small panel for one event: title and time you can change, its calendar, Join, notes, Delete and Open in Google Calendar.
struct EventPanel: View {
    let event: CalEvent
    let calendar: CalCalendar?
    let waiting: Bool

    @EnvironmentObject var edits: CalendarEdits
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var day: Date
    @State private var start: Date
    @State private var end: Date
    @State private var confirmDelete = false

    init(event: CalEvent, calendar: CalCalendar?, waiting: Bool) {
        self.event = event; self.calendar = calendar; self.waiting = waiting
        _title = State(initialValue: event.title); _day = State(initialValue: event.start)
        _start = State(initialValue: event.start); _end = State(initialValue: event.end)
    }

    private var editable: Bool { calendar?.owned ?? false }

    /// The time fields as dates: the chosen day with each time of day.
    private func on(_ time: Date) -> Date {
        let c = AppTime.calendar
        let t = c.dateComponents([.hour, .minute], from: time)
        return c.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? time
    }

    private func save() {
        guard editable else { return }
        edits.rename(event, to: title)
        guard !event.allDay else { return }
        let s = on(start), e = max(on(end), s.addingTimeInterval(Double(CalendarLayout.stepMinutes * 60)))
        if s != event.start || e != event.end { edits.move(event, start: s, end: e) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                    .disabled(!editable)
                    .onSubmit { save(); dismiss() }
                IDChip(id: event.id).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if event.allDay {
                Text("All day · \(Fmt.short(event.start))").foregroundStyle(.secondary)
            } else if editable {
                HStack(spacing: 6) {
                    DateInput(date: $day)
                    TimeInput(time: $start)
                    Text("to").foregroundStyle(.secondary)
                    TimeInput(time: $end)
                }
            } else {
                Text("\(Fmt.short(event.start)) \(Fmt.clock(event.start))–\(Fmt.clock(event.end))").foregroundStyle(.secondary)
            }
            if let calendar {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: calendar.color)).frame(width: 8, height: 8)
                    Text(calendar.name)
                    Text(calendar.account).foregroundStyle(.secondary)
                }
            }
            if !event.videoLink.isEmpty, let url = URL(string: event.videoLink) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Join", systemImage: "video.fill") }
                    .controlSize(.small)
            }
            if !event.description.isEmpty {
                Text(event.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(6)
            }
            LinkedTasksSlot(event: event)
            if waiting {
                Label("Waiting to send to Google", systemImage: "arrow.up.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !editable {
                Text("This calendar is read-only for you.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if editable {
                    if confirmDelete {
                        Button("Delete this event?", role: .destructive) { edits.delete(event); dismiss() }
                        Button("Keep") { confirmDelete = false }
                    } else {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
                Spacer()
                if let url = URL(string: event.htmlLink), !event.htmlLink.isEmpty {
                    Button("Open in Google Calendar") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                }
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 340)
        .onDisappear(perform: save)
    }
}

/// Where the event's "Linked tasks" go (built in Task 9). Nothing is drawn yet.
struct LinkedTasksSlot: View {
    let event: CalEvent
    var body: some View { EmptyView() }
}
