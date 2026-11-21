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

private struct EventColoursKey: EnvironmentKey { static let defaultValue: [String: AccountColors.EventColors] = [:] }
extension EnvironmentValues {
    /// Per calendar (`TaskEventRules.key`): the colours its events are drawn with (the account's colour; the calendar's own
    /// as a small mark when the account shows several). Set by the grid.
    var eventColours: [String: AccountColors.EventColors] {
        get { self[EventColoursKey.self] }
        set { self[EventColoursKey.self] = newValue }
    }
}
private let hourHeight: CGFloat = 46

/// Hours down the side and one column per day. Events are coloured by their Google account (which email they come from;
/// the calendar's own colour is a small mark when an account shows several calendars); tasks have a checkbox and their
/// group colour. All-day events and date-only tasks sit in a strip above the hours.
struct TimeGrid: View {
    let days: [Date]
    var snapshotHours: ClosedRange<Int>?

    @EnvironmentObject var store: Store
    @EnvironmentObject var edits: CalendarEdits
    @EnvironmentObject var ui: UIState

    private var hours: [Int] { Array(snapshotHours ?? 0...23) }

    private var cal: Calendar { AppTime.calendar }

    var body: some View {
        let cache = CalendarCache(store: store)
        let outbox = CalendarOutbox(store: store)
        let from = days.first.map { cal.startOfDay(for: $0) } ?? Date()
        let to = cal.date(byAdding: .day, value: days.count, to: from) ?? from
        let calendars = Dictionary(cache.calendars().map { (TaskEventRules.key($0.account, $0.calendarID), $0) }, uniquingKeysWith: { a, _ in a })
        let waitingNew = outbox.pendingNewEvents(from: from, to: to)
        // Accounts hidden with the legend are left out here (the bar and the phone still show them), except events still
        // waiting to send or refused, so their state and Discard stay in reach.
        let hidden = store.hiddenCalendarAccounts()
        let refusedIDs = Set(outbox.failedNewEvents().keys)
        let events = (cache.events(from: from, to: to).filter { !edits.deleted.contains($0.shortID) }.map(edits.shown) + waitingNew)
            .filter { e in
                CalendarSettings.showsOnPage(account: e.account, hidden: hidden,
                                             waiting: e.shortID < 0 || refusedIDs.contains(e.eventID) || (hidden.contains(e.account) && outbox.pending(eventShortID: e.shortID)))
            }
        let accountColours = store.accountColors(for: cache.connectedAccountList())
        let shownPerAccount = Dictionary(grouping: calendars.values.filter(\.shown), by: \.account).mapValues(\.count)
        let tints = calendars.mapValues { c in
            AccountColors.eventColors(accountColor: accountColours[c.account] ?? AccountColors.fallback, calendar: c,
                                      shownCalendarsOfAccount: shownPerAccount[c.account] ?? 1)
        }
        let pending = Set(waitingNew.map(\.shortID)).union(events.filter { outbox.pending(eventShortID: $0.shortID) }.map(\.shortID))
        let refused = outbox.failedNewEvents()
        let tasks = store.cards.filter { !$0.withdrawn }
        let placed = days.map { CalendarLayout.columns(for: events, tasks: tasks, day: $0) }

        VStack(spacing: 0) {
            // Day names. The gutter's spacer has no height of its own: a bare Color.clear takes any height it is offered, so
            // the stack gave this row part of the window's spare height and the names sat far below the title.
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 0)
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in DayHeading(day: d, single: days.count == 1) }
            }
            .padding(.bottom, 4)
            // All-day events and date-only tasks.
            if placed.contains(where: { $0.contains { $0.inStrip } }) {
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(width: gutter, alignment: .trailing).padding(.trailing, 6).padding(.top, 2)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, _ in
                        // Up to three items stacked; with more, two and "+N more", which lists them all.
                        let strip = placed[i].filter(\.inStrip)
                        let split = CalendarLayout.stripSplit(count: strip.count)
                        VStack(spacing: 2) {
                            ForEach(strip.prefix(split.shown)) { StripChip(item: $0, calendars: calendars, compact: days.count > 1) }
                            if split.more > 0 { StripMore(items: strip, more: split.more, calendars: calendars) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 1)
                    }
                }
                .padding(.bottom, 4)
            }
            Divider()
            if snapshotHours != nil {
                grid(placed: placed, calendars: calendars, pending: pending, refused: refused)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(placed: placed, calendars: calendars, pending: pending, refused: refused)
                    }
                    // 07:00, or an hour before an event search asked to show. Only a new request moves the grid: the
                    // request being acknowledged (nil) leaves it where it is (round 24).
                    .onAppear { proxy.scrollTo(CalendarReveal.scrollHour(for: ui.revealEvent, in: events) ?? 7, anchor: .top) }
                    .onChange(of: ui.revealEvent) { _, new in
                        if let h = CalendarReveal.scrollHour(for: new, in: events) { proxy.scrollTo(h, anchor: .top) }
                    }
                }
            }
        }
        .environment(\.eventColours, tints)
    }

    private func grid(placed: [[PlacedItem]], calendars: [String: CalCalendar], pending: Set<Int64>,
                      refused: [String: (uuid: String, error: String)]) -> some View {
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
                    DayColumn(day: d, items: placed[i].filter { !$0.inStrip }, hours: hours, calendars: calendars, pending: pending, refused: refused)
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
    let refused: [String: (uuid: String, error: String)]

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
                    Block(item: item, height: height, calendars: calendars, pending: pending, refused: refused, columnWidth: geo.size.width)
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
    let refused: [String: (uuid: String, error: String)]
    let columnWidth: CGFloat

    var body: some View {
        switch item.content {
        case .event(let e): EventBlock(event: e, item: item, calendar: calendars[TaskEventRules.key(e.account, e.calendarID)],
                                       waiting: pending.contains(e.shortID), refused: e.shortID < 0 ? refused[e.eventID] : nil,
                                       height: height, columnWidth: columnWidth)
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
    /// A new event Google refused for good: its outbox row and Google's answer (the block offers Discard).
    let refused: (uuid: String, error: String)?
    let height: CGFloat
    let columnWidth: CGFloat

    @EnvironmentObject var edits: CalendarEdits
    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @Environment(\.eventColours) private var tints
    @State private var open = false
    @State private var reveal = DelayedReveal()   // the pending panel open for an event picked in search
    @State private var showRefusal = false
    @State private var drag: CGSize = .zero
    @State private var grow: CGFloat = 0

    private var tint: AccountColors.EventColors? { tints[TaskEventRules.key(event.account, event.calendarID)] }
    /// The account's colour (which email it comes from).
    private var colour: Color { tint.map { Color(hex: $0.stripe) } ?? calendar.map { Color(hex: $0.color) } ?? .gray }
    /// A new event that Google has not confirmed yet (no E-n): shown, but not editable until it arrives.
    private var placeholder: Bool { event.shortID < 0 }
    private var editable: Bool { !placeholder && (calendar?.owned ?? false) }

    /// The panel opens from the request it saw, after the grid has scrolled to it, and only while that request is still
    /// the current one; the request is acknowledged only then. A newer pick (for another event) or leaving the page in
    /// the meantime cancels it (round 25).
    private func revealIfAsked() {
        // A preview from the search list's highlight (round 37) scrolls to it but never opens the panel.
        guard !placeholder, let r = ui.revealEvent, r.id == event.shortID, ui.reveals.opens else { reveal.cancel(); return }
        reveal.schedule(r, delay: 0.35, current: { ui.revealEvent }, open: { open = true }, acknowledge: { ui.revealEvent = nil })
    }

    var body: some View {
        let narrow = columnWidth / CGFloat(item.columns) < 110
        let h = max(height + grow, hourHeight / 4)
        // Titles wrap onto as many lines as the block's height allows; the time line goes first when space is short.
        let text = CalendarLayout.blockText(height: h)
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                Rectangle().fill(colour).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(event.title.isEmpty ? "(no title)" : event.title).font(.system(size: 11, weight: .semibold)).lineLimit(text.titleLines)
                        if let mark = tint?.mark {
                            Circle().fill(Color(hex: mark)).frame(width: 6, height: 6).help(calendar?.name ?? "Calendar")
                        }
                        if refused != nil {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.red)
                                .help("Google refused this event; click for details")
                        } else if waiting {
                            Image(systemName: "arrow.up.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                                .help("Waiting to send to Google")
                        }
                    }
                    if text.showTime { Text("\(Fmt.clock(event.start))–\(Fmt.clock(event.end))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    if !narrow && text.showID && !placeholder { IDChip(id: event.id).font(.system(size: 9)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: h, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 5).fill(colour.opacity(0.16)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { if refused != nil { showRefusal = true } else if !placeholder { open = true } }
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
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(ui.revealEvent?.id == event.shortID && !ui.reveals.opens ? 1 : 0))   // previewed from search
        .offset(drag)
        .opacity(drag == .zero ? 1 : 0.8)
        .modifier(HoverDetail(suppressed: open || showRefusal || drag != .zero || grow != 0) { CalendarItemDetail(content: .event(event), calendar: calendar) })
        .popover(isPresented: $open, arrowEdge: .trailing) { EventPanel(event: event, calendar: calendar, waiting: waiting) }
        // An event picked in search: its panel opens once its block is on screen (after the grid has scrolled to it).
        .onAppear { revealIfAsked() }
        .onChange(of: ui.revealEvent) { _, new in if new != nil { revealIfAsked() } }   // its own acknowledgement (nil) changes nothing
        .onDisappear { reveal.cancel() }
        .popover(isPresented: $showRefusal, arrowEdge: .trailing) {
            if let refused {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google refused to add this event").font(.system(size: 12, weight: .semibold))
                    Text(refused.error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Discard", role: .destructive) { CalendarOutbox(store: store).discard(uuid: refused.uuid); showRefusal = false }
                    }
                    .controlSize(.small)
                }
                .padding(12).frame(width: 300)
            }
        }
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
    @State private var editing = false

    var body: some View {
        let done = task.status == .done
        let narrow = columnWidth / CGFloat(item.columns) < 110
        let text = CalendarLayout.blockText(height: height)
        HStack(alignment: .top, spacing: 4) {
            TaskCheck(task: task)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(text.titleLines)
                    .strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                if text.showTime { Text(Fmt.clock(item.start)).font(.system(size: 10)).foregroundStyle(.secondary) }
                if !narrow && text.showID { IDChip(id: ShortID(kind: .task, number: task.id)).font(.system(size: 9)).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
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
        // A click opens the task exactly as on the board: the board's task editor.
        .onTapGesture { editing = true }
        .modifier(HoverDetail(suppressed: editing || drag != .zero) { CalendarItemDetail(content: .task(task), calendar: nil) })
        .popover(isPresented: $editing, arrowEdge: .trailing) { EditCardView(draft: store.card(task.id) ?? task) { editing = false } }
    }
}

/// An all-day event or a date-only task in the strip above the hours.
private struct StripChip: View {
    let item: PlacedItem
    let calendars: [String: CalCalendar]
    let compact: Bool
    @EnvironmentObject var store: Store
    @Environment(\.eventColours) private var tints
    @State private var editing = false

    var body: some View {
        chip
            .contentShape(Rectangle())
            .onTapGesture { if case .task = item.content { editing = true } }
            .modifier(HoverDetail(suppressed: editing) {
                CalendarItemDetail(content: item.content, calendar: {
                    if case .event(let e) = item.content { return calendars[TaskEventRules.key(e.account, e.calendarID)] }
                    return nil
                }())
            })
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                if case .task(let t) = item.content { EditCardView(draft: store.card(t.id) ?? t) { editing = false } }
            }
    }

    @ViewBuilder private var chip: some View {
        switch item.content {
        case .event(let e):
            let tint = tints[TaskEventRules.key(e.account, e.calendarID)]
            let colour = tint.map { Color(hex: $0.stripe) } ?? calendars[TaskEventRules.key(e.account, e.calendarID)].map { Color(hex: $0.color) } ?? .gray
            HStack(spacing: 4) {
                Rectangle().fill(colour).frame(width: 3)
                Text(e.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if let mark = tint?.mark { Circle().fill(Color(hex: mark)).frame(width: 6, height: 6) }
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

/// "+N more" in the all-day row: a click lists every item of that day.
private struct StripMore: View {
    let items: [PlacedItem]
    let more: Int
    let calendars: [String: CalCalendar]
    @State private var open = false
    var body: some View {
        Text("+\(more) more").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4).frame(height: 16)
            .contentShape(Rectangle())
            .onTapGesture { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 3) {
                    ForEach(items) { StripChip(item: $0, calendars: calendars, compact: false) }
                }
                .padding(10).frame(width: 260)
            }
    }
}

/// After the pointer rests on a calendar item for 0.4 s: a small popover with its full details (`CalendarItemDetail`).
/// It closes when the pointer leaves; a click still opens the item's panel or editor (then this stays closed).
struct HoverDetail<Detail: View>: ViewModifier {
    /// True while a click's panel or editor is open, or the item is being dragged or resized.
    var suppressed: Bool
    @ViewBuilder var detail: () -> Detail
    @State private var gate = HoverGate()
    @State private var wait: Task<Void, Never>?
    @Environment(\.calendarSnapshot) private var snapshot

    func body(content: Content) -> some View {
        if snapshot { content } else {
            content
                .onHover { inside in
                    wait?.cancel()
                    guard inside else { gate.leave(); return }
                    gate.enter(suppressed: suppressed)
                    wait = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000) // try?-ok: a cancelled wait just means the pointer left
                        if !Task.isCancelled { gate.waited(suppressed: suppressed) }
                    }
                }
                // A drag, resize or click closes them at once, and they stay closed until the pointer enters again.
                .onChange(of: suppressed) { _, s in if s { wait?.cancel(); gate.suppress() } }
                .popover(isPresented: Binding(get: { gate.shown }, set: { if !$0 { gate.closed() } }), arrowEdge: .top) { detail() }
        }
    }
}

/// The full details of a calendar item: its whole title, its time (or due), and for an event the account's colour and email
/// (and its calendar); for a task its group and step.
struct CalendarItemDetail: View {
    let content: PlacedItem.Content
    let calendar: CalCalendar?
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch content {
            case .event(let e):
                let colour = store.accountColors(for: CalendarCache(store: store).connectedAccountList())[e.account] ?? AccountColors.fallback
                Text(e.title.isEmpty ? "(no title)" : e.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(e.allDay ? "All day" : "\(Fmt.short(e.start)) \(Fmt.clock(e.start))–\(Fmt.clock(e.end))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: colour)).frame(width: 8, height: 8)
                    Text(e.account).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    if let calendar, calendar.calendarID != e.account, calendar.calendarID != CalendarCache.primaryAlias {
                        Text("· \(calendar.name)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            case .task(let t):
                let card = store.card(t.id) ?? t
                Text(card.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let due = card.due {
                    Text("Due " + (card.dueHasTime ? "\(Fmt.short(due)) \(Fmt.clock(due))" : Fmt.short(due)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(store.color(card.area)).frame(width: 8, height: 8)
                    Text(card.area).font(.system(size: 11)).lineLimit(1)
                    Text("· \(card.status.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
    }
}
