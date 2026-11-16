import FloatBoardCore
import SwiftUI

/// One day, drawn by the same grid as the week view.
struct DayView: View {
    let day: Date
    var snapshotHours: ClosedRange<Int>?
    var body: some View {
        TimeGrid(days: [AppTime.calendar.startOfDay(for: day)], snapshotHours: snapshotHours)
    }
}

private let gutter: CGFloat = 44
private let hourHeight: CGFloat = 46

/// Hours down the side and one column per day. Events are coloured by their Google calendar; tasks have a checkbox and their
/// group colour. All-day events and date-only tasks sit in a strip above the hours.
struct TimeGrid: View {
    let days: [Date]
    var snapshotHours: ClosedRange<Int>?

    @EnvironmentObject var store: Store
    @EnvironmentObject var edits: CalendarEdits

    private var hours: [Int] { Array(snapshotHours ?? 0...23) }
    private var cal: Calendar { AppTime.calendar }

    var body: some View {
        let cache = CalendarCache(store: store)
        let outbox = CalendarOutbox(store: store)
        let from = days.first.map { cal.startOfDay(for: $0) } ?? Date()
        let to = cal.date(byAdding: .day, value: days.count, to: from) ?? from
        let calendars = Dictionary(cache.calendars().map { (TaskEventRules.key($0.account, $0.calendarID), $0) }, uniquingKeysWith: { a, _ in a })
        let waitingNew = outbox.pendingNewEvents(from: from, to: to)
        let events = cache.events(from: from, to: to).filter { !edits.deleted.contains($0.shortID) }.map(edits.shown) + waitingNew
        let pending = Set(waitingNew.map(\.shortID)).union(events.filter { outbox.pending(eventShortID: $0.shortID) }.map(\.shortID))
        let tasks = store.cards.filter { !$0.withdrawn }
        let placed = days.map { CalendarLayout.columns(for: events, tasks: tasks, day: $0) }

        VStack(spacing: 0) {
            // Day names.
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in DayHeading(day: d, single: days.count == 1) }
            }
            .padding(.bottom, 4)
            // All-day events and date-only tasks.
            if placed.contains(where: { $0.contains { $0.inStrip } }) {
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(width: gutter, alignment: .trailing).padding(.trailing, 6).padding(.top, 2)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, _ in
                        VStack(spacing: 2) {
                            ForEach(placed[i].filter(\.inStrip)) { StripChip(item: $0, calendars: calendars, compact: days.count > 1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 1)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
            if snapshotHours != nil {
                grid(placed: placed, calendars: calendars, pending: pending)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(placed: placed, calendars: calendars, pending: pending)
                    }
                    .onAppear { proxy.scrollTo(7, anchor: .top) }
                }
            }
        }
    }

    private func grid(placed: [[PlacedItem]], calendars: [String: CalCalendar], pending: Set<Int64>) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { h in
                    HStack(alignment: .top, spacing: 0) {
                        Text(String(format: "%02d:00", h)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: gutter, alignment: .trailing).padding(.trailing, 6).offset(y: -6)
                        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
                    }
                    .frame(height: hourHeight, alignment: .top)
                    .id(h)
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    DayColumn(day: d, items: placed[i].filter { !$0.inStrip }, hours: hours, calendars: calendars, pending: pending)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 4)
    }
}

/// "Wed 18", with today's number in the accent colour.
private struct DayHeading: View {
    let day: Date
    let single: Bool
    var body: some View {
        let f = DateFormatter()
        let _ = { f.timeZone = AppTime.zone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE" }()
        let today = AppTime.calendar.isDateInToday(day)
        HStack(spacing: 5) {
            Text(f.string(from: day)).foregroundStyle(today ? Color.accentColor : .secondary)
            Text("\(AppTime.calendar.component(.day, from: day))")
                .fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(today ? Color.white : .primary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(today ? Color.accentColor : Color.clear))
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: single ? .leading : .center)
        .padding(.leading, single ? 4 : 0)
    }
}

/// One day's column of the grid: a click on empty time starts a new event, a task dropped here goes to that time.
private struct DayColumn: View {
    let day: Date
    let items: [PlacedItem]
    let hours: [Int]
    let calendars: [String: CalCalendar]
    let pending: Set<Int64>

    @EnvironmentObject var edits: CalendarEdits
    @EnvironmentObject var store: Store
    @Environment(\.calendarSnapshot) private var snapshot

    private var cal: Calendar { AppTime.calendar }
    private var firstHour: Int { hours.first ?? 0 }

    /// The time at height `y` in the column, in 15-minute steps.
    private func time(atY y: CGFloat) -> Date {
        let minutes = max(0, min(1439, Int(((y / hourHeight) + CGFloat(firstHour)) * 60)))
        let start = cal.startOfDay(for: day)
        let t = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) ?? start
        return CalendarLayout.snapDown(t)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(cal.isDateInToday(day) ? Color.accentColor.opacity(0.05) : Color.clear)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5) }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { edits.newEvent = NewEventDraft(start: time(atY: $0.location.y)) })
                ForEach(items) { item in
                    let slot = geo.size.width / CGFloat(item.columns)
                    let top = y(item.start)
                    let height = max(y(item.end) - top, hourHeight / 4)
                    Block(item: item, height: height, calendars: calendars, pending: pending, columnWidth: geo.size.width)
                        .frame(width: slot - 2, height: height, alignment: .topLeading)
                        .offset(x: slot * CGFloat(item.column) + 1, y: top)
                }
                if cal.isDateInToday(day) { NowLine(y: y(Date())) }
            }
            .modifier(TaskDrop(enabled: !snapshot) { id, y in edits.place(taskID: id, at: time(atY: y)) })
        }
        .frame(height: hourHeight * CGFloat(hours.count))
    }

    private func y(_ d: Date) -> CGFloat {
        let start = cal.startOfDay(for: day)
        guard d < (cal.date(byAdding: .day, value: 1, to: start) ?? d) else { return CGFloat(24 - firstHour) * hourHeight }
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        let hoursIn = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        return CGFloat(hoursIn - Double(firstHour)) * hourHeight
    }
}

/// Accepts a task dragged onto the column (from the Due soon list or another time).
private struct TaskDrop: ViewModifier {
    let enabled: Bool
    let drop: (Int64, CGFloat) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { dropped, location in
                guard let id = dropped.first.flatMap({ ShortID.parse($0) }), id.kind == .task else { return false }
                drop(id.number, location.y)
                return true
            }
        } else { content }
    }
}

private struct NowLine: View {
    let y: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -3)
            Rectangle().fill(Color.red).frame(height: 1)
        }
        .offset(y: y - 3.5).allowsHitTesting(false)
    }
}

/// An event block or a task block, with dragging.
private struct Block: View {
    let item: PlacedItem
    let height: CGFloat
    let calendars: [String: CalCalendar]
    let pending: Set<Int64>
    let columnWidth: CGFloat

    var body: some View {
        switch item.content {
        case .event(let e): EventBlock(event: e, item: item, calendar: calendars[TaskEventRules.key(e.account, e.calendarID)],
                                       waiting: pending.contains(e.shortID), height: height, columnWidth: columnWidth)
        case .task(let t): TaskBlock(task: t, item: item, height: height, columnWidth: columnWidth)
        }
    }
}

/// Moves `start` by a drag: up and down changes the time (15-minute steps), left and right the day.
@MainActor private func dragged(_ start: Date, by t: CGSize, columnWidth: CGFloat) -> Date {
    let cal = AppTime.calendar
    let days = columnWidth > 0 ? Int((t.width / columnWidth).rounded()) : 0
    let moved = CalendarLayout.snap(start.addingTimeInterval(Double(t.height / hourHeight) * 3600))
    return cal.date(byAdding: .day, value: days, to: moved) ?? moved
}

private struct EventBlock: View {
    let event: CalEvent
    let item: PlacedItem
    let calendar: CalCalendar?
    let waiting: Bool
    let height: CGFloat
    let columnWidth: CGFloat

    @EnvironmentObject var edits: CalendarEdits
    @State private var open = false
    @State private var drag: CGSize = .zero
    @State private var grow: CGFloat = 0

    private var colour: Color { calendar.map { Color(hex: $0.color) } ?? .gray }
    /// A new event that Google has not confirmed yet (no E-n): shown, but not editable until it arrives.
    private var placeholder: Bool { event.shortID < 0 }
    private var editable: Bool { !placeholder && (calendar?.owned ?? false) }

    var body: some View {
        let narrow = columnWidth / CGFloat(item.columns) < 110
        let h = max(height + grow, hourHeight / 4)
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                Rectangle().fill(colour).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(event.title.isEmpty ? "(no title)" : event.title).font(.system(size: 11, weight: .semibold)).lineLimit(h < 40 || narrow ? 1 : 2)
                        if waiting {
                            Image(systemName: "arrow.up.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                                .help("Waiting to send to Google")
                        }
                    }
                    if h >= 30 { Text("\(Fmt.clock(event.start))–\(Fmt.clock(event.end))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    if !narrow && h >= 44 && !placeholder { IDChip(id: event.id).font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: h, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 5).fill(colour.opacity(0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { if !placeholder { open = true } }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { if editable { drag = $0.translation } }
                .onEnded { v in
                    drag = .zero
                    guard editable else { return }
                    let s = dragged(event.start, by: v.translation, columnWidth: columnWidth)
                    if s != event.start { edits.move(event, start: s, end: s.addingTimeInterval(event.end.timeIntervalSince(event.start))) }
                })
            if editable {
                // Drag the bottom edge to change the end.
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { grow = $0.translation.height }
                        .onEnded { v in
                            grow = 0
                            let end = CalendarLayout.snap(event.end.addingTimeInterval(Double(v.translation.height / hourHeight) * 3600))
                            let floor = event.start.addingTimeInterval(Double(CalendarLayout.stepMinutes * 60))
                            if end != event.end { edits.move(event, start: event.start, end: max(end, floor)) }
                        })
            }
        }
        .frame(height: h, alignment: .top)
        .offset(drag)
        .opacity(drag == .zero ? 1 : 0.8)
        .popover(isPresented: $open, arrowEdge: .trailing) { EventPanel(event: event, calendar: calendar, waiting: waiting) }
    }
}

private struct TaskBlock: View {
    let task: Card
    let item: PlacedItem
    let height: CGFloat
    let columnWidth: CGFloat

    @EnvironmentObject var edits: CalendarEdits
    @EnvironmentObject var store: Store
    @State private var drag: CGSize = .zero

    var body: some View {
        let done = task.status == .done
        let narrow = columnWidth / CGFloat(item.columns) < 110
        HStack(alignment: .top, spacing: 4) {
            TaskCheck(task: task)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    .strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                if height >= 30 { Text(Fmt.clock(item.start)).font(.system(size: 10)).foregroundStyle(.secondary) }
                if !narrow && height >= 44 { IDChip(id: ShortID(kind: .task, number: task.id)).font(.system(size: 9)).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(store.color(task.area), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .offset(drag)
        .opacity(drag == .zero ? 1 : 0.8)
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                drag = .zero
                guard let due = task.due else { return }
                let s = dragged(due, by: v.translation, columnWidth: columnWidth)
                if s != due { edits.place(taskID: task.id, at: s) }
            })
        .help("Task: drag to another time")
    }
}

/// An all-day event or a date-only task in the strip above the hours.
private struct StripChip: View {
    let item: PlacedItem
    let calendars: [String: CalCalendar]
    let compact: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        switch item.content {
        case .event(let e):
            let colour = calendars[TaskEventRules.key(e.account, e.calendarID)].map { Color(hex: $0.color) } ?? .gray
            HStack(spacing: 4) {
                Rectangle().fill(colour).frame(width: 3)
                Text(e.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(colour.opacity(0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        case .task(let t):
            let done = t.status == .done
            HStack(spacing: 4) {
                TaskCheck(task: t, size: 11)
                Text(t.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                Spacer(minLength: 0)
                if !compact { IDChip(id: ShortID(kind: .task, number: t.id)).font(.system(size: 9)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(store.color(t.area), lineWidth: 1.5))
        }
    }
}
