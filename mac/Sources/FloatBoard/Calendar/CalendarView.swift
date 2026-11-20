import FloatBoardCore
import SwiftUI

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while a dev snapshot is drawn: buttons, pickers and drop targets are AppKit views that a snapshot cannot draw, so
    /// they are left out or drawn plain.
    var calendarSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// A task's checkbox: ticking it marks the task done (or open again).
struct TaskCheck: View {
    let task: Card
    var size: CGFloat = 12
    @EnvironmentObject var store: Store
    @Environment(\.calendarSnapshot) private var snapshot
    var body: some View {
        let done = task.status == .done
        let image = Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: size))
        if snapshot { image } else {
            Button { store.move(task, to: done ? .todo : .done) } label: { image }
                .buttonStyle(.borderless).help(done ? "Mark as not done" : "Mark as done")
        }
    }
}

/// A new event being typed (opened by clicking empty time in the grid).
struct NewEventDraft: Identifiable {
    let id = UUID()
    var start: Date
}

/// What the Calendar tab changes. Every change to an event is queued in the calendar outbox (it reaches Google a moment later,
/// and works offline); an event made from a task goes through the task, so the task and event stay in step. While a change
/// waits, the screen shows it as if sent (`overrides`, `deleted`) and the event carries a "waiting to send" mark.
@MainActor final class CalendarEdits: ObservableObject {
    struct Override { var start: Date; var end: Date; var title: String }
    @Published var overrides: [Int64: Override] = [:]
    @Published var deleted: Set<Int64> = []
    @Published var newEvent: NewEventDraft?
    var store: Store?

    private var cache: CalendarCache? { store.map { CalendarCache(store: $0) } }
    private var outbox: CalendarOutbox? { store.map { CalendarOutbox(store: $0) } }

    /// The event as it should look now: with a change that is still waiting to be sent applied.
    func shown(_ e: CalEvent) -> CalEvent {
        guard let o = overrides[e.shortID] else { return e }
        var e = e; e.start = o.start; e.end = o.end; e.title = o.title
        return e
    }

    /// The event as saved now (a sync may have changed it since `e` was read), with a change still waiting applied.
    func current(_ e: CalEvent) -> CalEvent { shown(cache?.event(shortID: e.shortID) ?? e) }

    /// The task an event was made from, if any.
    func linkedTask(_ e: CalEvent) -> Card? { store?.linkedTask(of: e) }

    func move(_ e: CalEvent, start: Date, end: Date) {
        guard let store, store.moveCalendarEvent(e, start: start, end: end) else { return }
        // A linked task shows its own new time; a plain event is shown where it was put until Google has it.
        if store.linkedTask(of: e) == nil || start == e.start {
            overrides[e.shortID] = Override(start: start, end: end, title: overrides[e.shortID]?.title ?? e.title)
        }
        nudge()
    }

    func rename(_ e: CalEvent, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let store, !t.isEmpty, t != e.title else { return }
        if var task = linkedTask(e) {
            task.title = t
            store.update(task)
        } else if outboxPatch(e, title: t, start: nil, end: nil) {
            let cur = overrides[e.shortID]
            overrides[e.shortID] = Override(start: cur?.start ?? e.start, end: cur?.end ?? e.end, title: t)
        } else { return }
        nudge()
    }

    func delete(_ e: CalEvent) {
        guard let outbox, !outbox.enqueue(.delete(eventID: e.eventID), account: e.account, calendarID: e.calendarID).isEmpty else { return }
        deleted.insert(e.shortID)
        nudge()
    }

    func create(title: String, start: Date, end: Date, calendar: CalCalendar) {
        guard let outbox else { return }
        let f = CalEventFields(start: start, end: end, title: title.trimmingCharacters(in: .whitespaces), googleUpdated: Date())
        guard !outbox.enqueue(.create(f, cardID: nil, addMeet: false), account: calendar.account, calendarID: calendar.calendarID).isEmpty else { return }
        nudge()
    }

    /// A task dragged onto a time (from the grid or the Due soon list): its due becomes that time and its event follows (C1).
    func place(taskID: Int64, at start: Date) {
        guard let store else { return }
        store.placeOnCalendar(cardID: taskID, start: start, account: nil)
        nudge()
    }

    /// Forget what is no longer waiting (it was sent, so the cache now has it).
    func prune() {
        guard let outbox else { return }
        overrides = overrides.filter { outbox.pending(eventShortID: $0.key) }
        deleted = deleted.filter { outbox.pending(eventShortID: $0) }
    }

    private func outboxPatch(_ e: CalEvent, title: String?, start: Date?, end: Date?) -> Bool {
        guard let outbox else { return false }
        return !outbox.enqueue(.patch(eventID: e.eventID, title: title, start: start, end: end, allDayStart: nil),
                               account: e.account, calendarID: e.calendarID).isEmpty
    }

    private func nudge() { NotificationCenter.default.post(name: .floatBoardCalendarNow, object: nil) }

    /// The calendar a new event goes to among `options` (calendars the user owns and shows): the same rule as for tasks
    /// (`Store.newEventCalendar`), so a removed account is never chosen.
    func defaultCalendar(in options: [CalCalendar]) -> CalCalendar? {
        guard let pick = store?.newEventCalendar(among: options) else { return options.first }
        return options.first { $0.account == pick.account && $0.calendarID == pick.calendarID } ?? options.first
    }
}

/// The Calendar tab: a day or a week of your Google events and your tasks, with the tasks that are due soon beside it.
struct CalendarView: View {
    enum Span: String, CaseIterable { case day = "Day", week = "Week" }

    @EnvironmentObject var store: Store
    @EnvironmentObject var ui: UIState
    @StateObject private var edits = CalendarEdits()
    @State private var span: Span
    @State private var anchor: Date
    @State private var tick = 0
    /// Snapshots only: draw just these hours, without scrolling (a scroll view does not render there).
    var snapshotHours: ClosedRange<Int>?

    init(span: Span = .week, anchor: Date = Date(), snapshotHours: ClosedRange<Int>? = nil) {
        _span = State(initialValue: span); _anchor = State(initialValue: anchor); self.snapshotHours = snapshotHours
    }

    private var days: [Date] {
        span == .day ? [AppTime.calendar.startOfDay(for: anchor)] : CalendarLayout.days(ofWeekContaining: anchor)
    }

    private var title: String {
        let f = DateFormatter(); f.timeZone = AppTime.zone; f.locale = Locale(identifier: "en_GB")
        guard let first = days.first, let last = days.last else { return "" }
        if span == .day { f.dateFormat = "EEEE d MMMM yyyy"; return f.string(from: first) }
        let sameMonth = AppTime.calendar.component(.month, from: first) == AppTime.calendar.component(.month, from: last)
        f.dateFormat = sameMonth ? "d" : "d MMMM"
        let a = f.string(from: first)
        f.dateFormat = "d MMMM yyyy"
        return "\(a) – \(f.string(from: last))"
    }

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 10) {
            header
            MainOnlyBanner(tick: tick)
            HStack(alignment: .top, spacing: 12) {
                if span == .day { DayView(day: anchor, snapshotHours: snapshotHours) }
                else { WeekView(anchor: anchor, snapshotHours: snapshotHours) }
                DueSoonList()
                    .frame(width: 200)
            }
            AccountLegend(tick: tick)
        }
        .environmentObject(edits)
        .environment(\.calendarSnapshot, snapshotHours != nil)
        .onAppear { edits.store = store; showFocusedDay() }
        .onChange(of: ui.calendarFocus) { _, _ in showFocusedDay() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            edits.prune()
            tick += 1
        }
        .sheet(item: $edits.newEvent) { draft in NewEventSheet(start: draft.start).environmentObject(edits).environmentObject(store) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            if snapshotHours != nil {
                Text("‹  \(todayLabel)  ›     Day | Week").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.help("Earlier")
                Button(todayLabel) { anchor = Date() }
                Button { step(1) } label: { Image(systemName: "chevron.right") }.help("Later")
            }
            .controlSize(.small)
            Picker("Span", selection: $span) {
                ForEach(Span.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
            }
        }
    }

    /// The button that jumps back to now: "Today" in Day view, "This week" in Week view.
    private var todayLabel: String { span == .day ? "Today" : "This week" }

    /// A click on the bar's meeting asks for its day.
    private func showFocusedDay() {
        guard let d = ui.calendarFocus else { return }
        anchor = d; span = .day
        ui.calendarFocus = nil
    }

    private func step(_ by: Int) {
        anchor = AppTime.calendar.date(byAdding: .day, value: span == .day ? by : 7 * by, to: anchor) ?? anchor
    }
}

/// Bottom left of the Calendar page: a colour dot and the email of each connected account (its events' colour). Clicking
/// one hides that account's events on this page, or shows them again.
struct AccountLegend: View {
    @EnvironmentObject var store: Store
    @Environment(\.calendarSnapshot) private var snapshot
    var tick = 0
    @State private var changed = 0

    var body: some View {
        let _ = (tick, changed)
        let accounts = CalendarCache(store: store).connectedAccountList()
        let colours = store.accountColors(for: accounts)
        let hidden = store.hiddenCalendarAccounts()
        if !accounts.isEmpty {
            HStack(spacing: 14) {
                ForEach(accounts, id: \.self) { a in
                    let off = hidden.contains(a)
                    let label = HStack(spacing: 5) {
                        Circle().fill(off ? Color.clear : Color(hex: colours[a] ?? AccountColors.fallback))
                            .overlay(Circle().strokeBorder(Color(hex: colours[a] ?? AccountColors.fallback), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                        Text(Self.short(a)).font(.system(size: 11)).lineLimit(1).fixedSize()
                            .foregroundStyle(off ? .tertiary : .secondary)
                    }
                    if snapshot { label } else {
                        Button {
                            store.setCalendarAccountHidden(a, !off)
                            changed += 1
                            NotificationCenter.default.post(name: .floatBoardCalendarNow, object: nil)
                        } label: { label }
                        .buttonStyle(.plain)
                        .help(off ? "Show \(a)'s events" : "Hide \(a)'s events")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A long email cut in the middle ("sam.longer…@example.org"), so the legend stays one line.
    static func short(_ email: String, limit: Int = 30) -> String {
        guard email.count > limit else { return email }
        let keep = limit - 1, head = keep / 2
        return String(email.prefix(head)) + "…" + String(email.suffix(keep - head))
    }
}

/// Under the Calendar header, one line per account shown with its main calendar only (its sign-in cannot list calendars):
/// "Showing main calendars only for <email>. Show all calendars…" runs that account's sign-in again, which grants the list;
/// × closes the line for that account (Settings › Outputs › Calendar still offers the sign-in).
struct MainOnlyBanner: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var google: Google
    @Environment(\.calendarSnapshot) private var snapshot
    var tick = 0
    @State private var closed = 0

    var body: some View {
        let _ = (tick, closed)
        let cache = CalendarCache(store: store)
        let accounts = CalendarSettings.mainOnlyBanner(connected: cache.connectedAccountList(), calendars: cache.calendars(),
                                                      outcome: { CalendarListAttempts.outcome($0) }, dismissed: store.dismissedCalendarBanners())
        let colours = store.accountColors(for: cache.connectedAccountList())
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(accounts, id: \.self) { a in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: colours[a] ?? AccountColors.fallback)).frame(width: 8, height: 8)
                        Text("Showing main calendars only for \(AccountLegend.short(a, limit: 40)).").font(.system(size: 12)).lineLimit(1)
                        if snapshot {
                            Text("Show all calendars…").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        } else {
                            Button("Show all calendars…") { google.connect(loginHint: a) }
                                .buttonStyle(.link).font(.system(size: 12))
                                .disabled(!google.isConfigured || google.busy)
                        }
                        Spacer(minLength: 0)
                        Button { store.dismissCalendarBanner(a); closed += 1 } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.borderless).help("Hide this line (Settings › Outputs › Calendar still offers it)")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
                }
            }
        }
    }
}
