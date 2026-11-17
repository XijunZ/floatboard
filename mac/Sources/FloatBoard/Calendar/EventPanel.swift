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
    /// Set by Delete: the panel closing after it must not queue a change for an event that is going away.
    @State private var deleted = false
    /// The fields as they were when the panel opened: only what the user changed from these is sent. State, so a redraw
    /// with a newer copy of the event (Google changed it meanwhile) does not move the starting point.
    @State private var opened: EventPanelEdit.Fields

    init(event: CalEvent, calendar: CalCalendar?, waiting: Bool) {
        self.event = event; self.calendar = calendar; self.waiting = waiting
        _opened = State(initialValue: EventPanelEdit.Fields(event))
        _title = State(initialValue: event.title); _day = State(initialValue: event.start)
        _start = State(initialValue: event.start); _end = State(initialValue: event.end)
    }

    private var editable: Bool { calendar?.owned ?? false }

    /// Sends only the fields the user changed since the panel opened (an untouched panel sends nothing), on top of the event
    /// as it is now (Google may have changed it while the panel was open).
    private func save() {
        guard editable, !deleted else { return }
        let event = edits.current(self.event)
        let change = EventPanelEdit.changes(event: event, opened: opened, now: .init(title: title, day: day, start: start, end: end))
        if let t = change.title { edits.rename(event, to: t) }
        if let m = change.move { edits.move(event, start: m.start, end: m.end) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                    .disabled(!editable)
                    .onSubmit { dismiss() } // closing the panel saves, once
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
                        .help("The calendar can't be changed here. To move the event to another calendar, open it in Google Calendar.")
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
                        Button("Delete this event?", role: .destructive) { deleted = true; edits.delete(event); dismiss() }
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
