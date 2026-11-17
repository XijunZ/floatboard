import Foundation

/// One person on "Due this week" (P6): their clocks, context lines (P7) and whether a reminder task is open.
public struct DueEntry: Identifiable, Equatable {
    public let person: Person
    public let clocks: Clocks
    public let context: [String]
    /// Past the due date now (else due later this week).
    public let overdue: Bool
    public let hasTask: Bool
    /// A meeting with them in the next 7 days (then no reminder is sent).
    public let meetingSoon: Bool
    public var id: Int64 { person.id }
}

/// The due list, reminders inside the shared budget, reminder tasks, and Circle's registrations (weekly review, search).
@MainActor public enum CircleDue {
    /// One budget reminder per person per week while they stay due.
    public static let remindEvery: TimeInterval = 7 * 86400

    /// People due by the end of this week (Monday to Sunday, app zone): not snoozed, no outreach in the last 7 days.
    /// Most overdue first.
    public static func entries(store: Store, now: Date = Date()) -> [DueEntry] {
        let c = CircleStore(store: store)
        let weekEnd = WeeklyReview.week(containing: now).end
        let details = c.allDetails(), handles = c.allHandles(), clocks = c.allClocks(now: now)
        let upcoming = CalendarCache(store: store).events(from: now, to: now.addingTimeInterval(7 * 86400)).filter { !$0.cancelled }
        var out: [DueEntry] = []
        for p in PeopleStore(store: store).people() {
            guard let k = clocks[p.id], k.snoozedUntil == nil, k.dueDate < weekEnd else { continue }
            if let o = k.lastOutreach, now.timeIntervalSince(o) < CircleClock.outreachQuiet { continue }
            let d = details[p.id] ?? CircleDetails()
            let emails = Set((handles[p.id] ?? []).filter { $0.kind == .email }.map(\.value))
            var context: [String] = []
            if let b = birthdayContext(d.birthday, now: now) { context.append(b) }
            let meeting = upcoming.first { e in e.guests.contains { emails.contains($0.email.lowercased()) } }
            if let m = meeting { context.append("You meet \(Fmt.meeting(m.start, now: now)) (\(m.id.text))") }
            out.append(DueEntry(person: p, clocks: k, context: context, overdue: k.due, hasTask: openTask(store, d) != nil, meetingSoon: meeting != nil))
        }
        return out.sorted { ($0.clocks.dueDate, $0.person.name) < ($1.clocks.dueDate, $1.person.name) }
    }

    /// "Birthday Wed 21 Nov" when it falls in the next 7 days ("YYYY-MM-DD" or "MM-DD").
    public static func birthdayContext(_ raw: String, now: Date) -> String? {
        guard let next = nextBirthday(raw, after: now) else { return nil }
        guard next.timeIntervalSince(AppTime.calendar.startOfDay(for: now)) < 7 * 86400 else { return nil }
        return AppTime.calendar.isDate(next, inSameDayAs: now) ? "Birthday today" : "Birthday \(CircleFmt.f("EEE d MMM", next))"
    }

    /// The next birthday on or after today's start.
    public static func nextBirthday(_ raw: String, after now: Date) -> Date? {
        let p = raw.split(separator: "-").compactMap { Int($0) }
        let (m, d): (Int, Int)
        switch p.count { case 3: (m, d) = (p[1], p[2]); case 2: (m, d) = (p[0], p[1]); default: return nil }
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let cal = AppTime.calendar
        let today = cal.startOfDay(for: now)
        let year = cal.component(.year, from: now)
        for y in [year, year + 1] {
            if let date = cal.date(from: DateComponents(year: y, month: m, day: d)), date >= today { return date }
        }
        return nil
    }

    static func openTask(_ store: Store, _ d: CircleDetails) -> Int64? {
        guard let t = d.reminderTask, let c = store.card(t), c.status != .done else { return nil }
        return t
    }

    /// Asks the shared budget for reminders: due people (most overdue first, once a week each, none while a reminder
    /// task is open or a meeting is within 7 days) and birthdays on the day. Nothing while Circle is off.
    @discardableResult
    public static func requestReminders(store: Store, now: Date = Date()) -> [ReminderGrant] {
        guard store.isOn(.circle) else { return [] }
        let budget = ReminderBudget(store: store)
        let c = CircleStore(store: store)
        var grants: [ReminderGrant] = []
        for e in entries(store: store, now: now) where e.overdue && !e.hasTask && !e.meetingSoon {
            var d = c.details(e.person.id)
            if let r = d.remindedAt, now.timeIntervalSince(r) < remindEvery, !AppTime.calendar.isDate(r, inSameDayAs: now) { continue }
            let since = e.clocks.lastConversation.map { "last talked \(CircleFmt.f("d MMM", $0))" } ?? "no conversation seen yet"
            let g = budget.request(kind: .circleDue, itemID: e.person.shortID, text: "Time to get in touch with \(e.person.name) (\(since))", now: now)
            grants.append(g)
            if case .granted = g { d.remindedAt = now; store.perform { try c.writeDetailsRow(e.person.id, d) } }
        }
        let details = c.allDetails()
        for p in PeopleStore(store: store).people() {
            guard let raw = details[p.id]?.birthday, let next = nextBirthday(raw, after: now), AppTime.calendar.isDate(next, inSameDayAs: now) else { continue }
            grants.append(budget.request(kind: .circleDue, itemID: p.shortID, text: "It's \(p.name)'s birthday today", now: now))
        }
        return grants
    }

    /// "Message <name>": one reminder task per person (the open one is returned again), with their tags' first board group,
    /// linked to them (related, by code). `slot`: also put it on the calendar then (a 30-minute event).
    @discardableResult
    public static func makeTask(store: Store, personID: Int64, slot: Date? = nil, now: Date = Date()) -> Int64? {
        let c = CircleStore(store: store)
        guard let p = PeopleStore(store: store).person(personID), !p.deleted else { return nil }
        var d = c.details(personID)
        if let open = openTask(store, d) { return open }
        let group = store.itemTags(p.shortID).all.first { t in store.areas.contains { $0.name.caseInsensitiveCompare(t) == .orderedSame } }
        guard let id = store.makeTask(TaskDraft(title: "Message \(p.name)", notes: "", primaryTag: group, others: []), due: nil, dueHasTime: false,
                                      from: nil, now: now) else { return nil }
        store.link(ShortID(kind: .task, number: id), p.shortID, kind: .related, madeBy: .auto, actor: .user, now: now)
        d.reminderTask = id
        store.perform { try c.writeDetailsRow(personID, d) }
        if let slot { store.placeOnCalendar(cardID: id, start: slot, account: nil, now: now) }
        return id
    }

    /// A reminder task whose person was reached since it was made (an outgoing message, a meeting, "I contacted them") is
    /// moved to Done, so the next due period can remind again. Returns the tasks closed.
    @discardableResult
    public static func settleTasks(store: Store, now: Date = Date()) -> [Int64] {
        let c = CircleStore(store: store)
        var closed: [Int64] = []
        for (pid, d) in c.allDetails() {
            guard let t = openTask(store, d), let card = store.card(t), let p = PeopleStore(store: store).person(pid) else { continue }
            let k = c.clocks(p, now: now)
            let reached = [k.lastOutreach, k.lastConversation].compactMap { $0 }.contains { $0 > card.created }
            if reached { store.move(card, to: .done); closed.append(t) }
        }
        return closed
    }

    /// Registers Circle with the weekly review (its due list) and search (people). Safe to call more than once.
    public static func register() {
        WeeklyReview.register(ReviewSection(id: "circle.due", title: "Due to get in touch", module: .circle, order: 40) { store, week in
            let now = Date()
            let at = week.contains(now) ? now : week.end.addingTimeInterval(-1)
            return entries(store: store, now: at).map { e in
                let since = e.clocks.lastConversation.map { "last talked \(CircleFmt.f("d MMM", $0))" } ?? "no conversation seen"
                return ReviewItem(id: e.person.shortID.text, item: e.person.shortID, title: e.person.name,
                                  detail: ([e.person.tier.title, since] + e.context).joined(separator: " · "))
            }
        })
        GlobalSearch.register(.person, module: .circle) { store, q in
            let c = CircleStore(store: store)
            let details = c.allDetails(), handles = c.allHandles()
            return PeopleStore(store: store).people().compactMap { p in
                let d = details[p.id] ?? CircleDetails()
                let text = ([p.name] + p.aliases + [d.company, d.role, d.firm, d.howKnown] + (handles[p.id] ?? []).map(\.value)).joined(separator: " ")
                guard GlobalSearch.matches(text, q) else { return nil }
                return SearchHit(id: p.shortID, title: p.name, detail: [p.tier.title, d.company].filter { !$0.isEmpty }.joined(separator: " · "), date: p.added)
            }
        }
    }
}
