import FloatBoardCore
import SwiftUI

/// "New event": title, start, end and which calendar. Opens on the time that was clicked.
struct NewEventSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var edits: CalendarEdits
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var day: Date
    @State private var start: Date
    @State private var end: Date
    @State private var chosen: CalCalendar?
    @FocusState private var titleFocused: Bool

    init(start: Date) {
        _day = State(initialValue: start); _start = State(initialValue: start)
        _end = State(initialValue: start.addingTimeInterval(3600))
    }

    /// Calendars the user owns and shows: the only ones a new event can go to.
    private var options: [CalCalendar] { CalendarCache(store: store).connectedCalendars().filter { $0.owned && $0.shown } }
    private var calendar: CalCalendar? { chosen ?? edits.defaultCalendar(in: options) }

    private func add() {
        guard let calendar, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let span = EventPanelEdit.span(day: day, start: start, end: end)   // an end before the start is the next day
        edits.create(title: title, start: span.start, end: span.end, calendar: calendar)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New event").font(.system(size: 15, weight: .semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(add)
            HStack(spacing: 6) {
                DateInput(date: $day)
                TimeInput(time: $start)
                Text("to").foregroundStyle(.secondary)
                TimeInput(time: $end)
            }
            if options.isEmpty {
                Text("Connect a Google account in Settings to add events.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Calendar").foregroundStyle(.secondary)
                    Dropdown(options: options.map { $0.account + "|" + $0.calendarID },
                             selection: Binding(get: { calendar.map { $0.account + "|" + $0.calendarID } ?? "" },
                                                set: { key in chosen = options.first { $0.account + "|" + $0.calendarID == key } }),
                             title: { key in options.first { $0.account + "|" + $0.calendarID == key }.map { "\($0.name) (\($0.account))" } ?? "" },
                             dot: { key in options.first { $0.account + "|" + $0.calendarID == key }.map { Color(hex: $0.color) } ?? .gray })
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
                    .disabled(calendar == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 380)
        .onAppear { titleFocused = true }
    }
}
