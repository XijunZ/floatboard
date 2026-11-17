import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// The foundation's cores beyond links: tags, jots, people, modules, the reminder budget, the weekly review and search
/// registries, Make task from a selection, and the calendar's guests and kept records.
@MainActor func foundationCoreChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-foundation-core-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    tagChecks(root)
    jotPeopleChecks(root)
    moduleChecks(root)
    reminderBudgetChecks(root)
    weeklyReviewChecks(root)
    globalSearchChecks(root)
    makeTaskChecks(root)
    calendarFoundationChecks(root)
}

// MARK: 3. Tags

@MainActor private func tagChecks(_ root: URL) {
    guard let store = foundationStore(root, "tags.sqlite") else { return }
    store.add(title: "Tagged task", area: "Work", importance: .medium, due: nil)
    store.addArea("Health")
    guard let c = store.cards.first(where: { $0.title == "Tagged task" }) else { check(false, "tags setup"); return }
    let t = ShortID(kind: .task, number: c.id)
    check(store.itemTags(t) == ItemTags(primary: "Work", others: []), "task_group_is_its_primary_tag")
    check(store.setTags(t, primary: "Personal", others: ["Health", "Work", "Personal"]) == nil, "task_tags_saved")
    let tags = store.itemTags(t)
    check(tags.primary == "Personal" && Set(tags.others) == ["Health", "Work"] && store.card(c.id)?.area == "Personal"
          && tags.all.first == "Personal", "primary_tag_sets_the_board_group")
    check(store.setTags(t, primary: "Nope", others: []) != nil && store.setTags(t, primary: "Work", others: ["Missing"]) != nil
          && store.card(c.id)?.area == "Personal", "unknown_tags_refused")
    check(store.items(taggedAny: ["health"]) == [t] && store.items(taggedAny: ["Personal", "Health"]) == [t]
          && store.items(taggedAny: ["Investor"]).isEmpty, "items_tagged_any_counted_once")
    check(TagFilter.matches(tags, any: ["Health", "Garden"]) && !TagFilter.matches(tags, any: ["Garden"]) && TagFilter.matches(tags, any: [])
          && TagFilter.counts([tags, ItemTags(primary: "Work", others: ["Work"])]) == ["Personal": 1, "Health": 1, "Work": 2],
          "tag_filter_any_and_counts_once")
    // Fixed tags' rules.
    check(TagRules.problems(tags: ["Prospect"], tier: .family) == ["Prospect can't be used on Family."]
          && TagRules.problems(tags: ["Investor"], tier: .family).isEmpty && TagRules.problems(tags: ["prospect"], tier: .network).isEmpty
          && TagRules.intervalCapMonths(tags: ["Investor"]) == 3 && TagRules.intervalCapMonths(tags: ["Prospect"]) == nil, "fixed_tag_rules")
    guard let p = PeopleStore(store: store).create(name: "Sam Example", tier: .family) else { check(false, "tags person setup"); return }
    check(store.setTags(p.shortID, primary: "Prospect", others: [], tier: .family) == "Prospect can't be used on Family."
          && store.setTags(p.shortID, primary: "Investor", others: ["Health"], tier: .family) == nil
          && store.itemTags(p.shortID) == ItemTags(primary: "Investor", others: ["Health"]), "person_tags_checked_by_rules")
    // Deleting a group: tasks move as before; other items lose that tag and keep a primary.
    if let health = store.tags.first(where: { $0.name == "Health" }) {
        store.setTags(p.shortID, primary: "Health", others: ["Investor"], tier: .family)
        store.deleteArea(health, moveTasksTo: "Work")
        check(store.itemTags(p.shortID) == ItemTags(primary: "Investor", others: []) && store.itemTags(t).others == ["Work"],
              "deleted_group_leaves_items_with_a_primary")
    } else { check(false, "tags: Health missing") }
    // Board unchanged: fixed tags are not groups until a task uses one.
    check(!store.areas.contains { $0.name == "Investor" }, "fixed_tag_not_a_group")
    store.setTags(t, primary: "Investor", others: [])
    check(store.areas.contains { $0.name == "Investor" } && store.card(c.id)?.area == "Investor", "fixed_tag_used_by_task_shows_as_group")
    // Phone: the task carries its tags, primary first, and when they last changed here.
    store.setTags(t, primary: "Work", others: ["Personal"])
    let card = PhoneBoard.payload(store: store, now: Date()).first { $0.id == c.id }
    check(card?.tags == ["Work", "Personal"] && card?.tagsAt != nil, "phone_copy_carries_tags")
    // A phone tag edit: applied when newer than the Mac's; primary first.
    let later = Date().addingTimeInterval(5)
    var r = store.applyPhoneActions([PhoneAction(id: "tg1", clientID: "found-tags-1", cardID: c.id, action: "set_tags", madeAt: later,
                                                 tags: ["Personal", "Work"])], connector: "ph", now: later)
    check(r.applied == ["tg1"] && store.itemTags(t) == ItemTags(primary: "Personal", others: ["Work"]), "phone_set_tags_applied")
    r = store.applyPhoneActions([PhoneAction(id: "tg2", clientID: "found-tags-2", cardID: c.id, action: "set_tags", madeAt: later.addingTimeInterval(-60),
                                             tags: ["Work"])], connector: "ph", now: later)
    check(r.skipped.map(\.reason) == ["superseded"] && store.itemTags(t).primary == "Personal", "older_phone_tags_lose")
}

// MARK: 4. Jots and people

@MainActor private func jotPeopleChecks(_ root: URL) {
    guard let store = foundationStore(root, "jots.sqlite") else { return }
    let jots = JotStore(store: store)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check(jots.create(text: "   ") == nil, "empty_jot_not_saved")
    guard let a = jots.create(text: "First thought", now: t0), let b = jots.create(text: "Meeting recap", kind: .meetingNotes, source: .meeting, now: t0 + 60)
    else { check(false, "jots setup"); return }
    check(a.shortID.text == "J-\(a.id)" && a.kind == .jot && a.source == .typed && b.kind == .meetingNotes && b.source == .meeting
          && a.added == t0 && a.updated == t0, "jot_created_with_kind_source_dates")
    check(jots.update(a.id, text: "First thought, refined", now: t0 + 100) && !jots.update(a.id, text: "First thought, refined", now: t0 + 200)
          && jots.update(a.id, text: "Third", now: t0 + 300), "jot_update_only_when_changed")
    check(jots.history(a.id).map(\.text) == ["First thought", "First thought, refined"] && jots.jot(a.id)?.text == "Third"
          && jots.jot(a.id)?.updated == t0 + 300 && jots.jot(a.id)?.added == t0, "jot_history_keeps_every_previous_text")
    check(jots.jots(addedFrom: t0, to: t0 + 3600).map(\.id) == [b.id, a.id] && jots.jots(addedFrom: t0 + 30, to: t0 + 3600).map(\.id) == [b.id],
          "jots_by_date_range_newest_first")
    jots.delete(b.id)
    check(jots.jots(addedFrom: t0, to: t0 + 3600).map(\.id) == [a.id] && jots.jot(b.id)?.deleted == true
          && jots.jots(addedFrom: t0, to: t0 + 3600, includeDeleted: true).count == 2, "jot_soft_delete")
    jots.undoDelete(b.id)
    check(jots.jot(b.id)?.deleted == false, "jot_undo_delete")

    let people = PeopleStore(store: store)
    guard let p = people.create(name: " Ana María ", aliases: ["Ana", " ", "AM"], tier: .close) else { check(false, "people setup"); return }
    check(p.name == "Ana María" && p.aliases == ["Ana", "AM"] && p.tier == .close && p.shortID.text == "P-\(p.id)", "person_created")
    check(people.find(nameOrAlias: "ana maria").map(\.id) == [p.id] && people.find(nameOrAlias: "am").map(\.id) == [p.id]
          && people.find(nameOrAlias: "An").isEmpty, "find_by_name_or_alias_exact_case_and_accent_insensitive")
    var edited = p; edited.tier = .network; edited.aliases = ["Ana"]
    check(people.update(edited) && people.person(p.id)?.tier == .network && !people.update(edited), "person_update")
    people.delete(p.id)
    check(people.find(nameOrAlias: "Ana").isEmpty && people.people().isEmpty && people.people(includeDeleted: true).count == 1, "person_delete")
    people.undoDelete(p.id)
    check(people.people().map(\.id) == [p.id], "person_undo_delete")
}

// MARK: 5. Modules

@MainActor private func moduleChecks(_ root: URL) {
    guard let store = foundationStore(root, "modules.sqlite") else { return }
    var seen: [String] = []
    ModuleHooks.onChange(.circle) { seen.append("circle \($0)") }
    check(store.modules.isEmpty, "new_board_modules_off")
    check(store.setModule(.decisions, on: true) == "Decisions needs Jots: switch Jots on first." && !store.isOn(.decisions), "decisions_needs_jots")
    check(store.setModule(.jots, on: true) == nil && store.setModule(.decisions, on: true) == nil && store.isOn(.decisions), "decisions_on_after_jots")
    check(store.setModule(.jots, on: false) == "Decisions needs Jots: switch Decisions off first." && store.isOn(.jots), "jots_stays_on_while_decisions_on")
    store.setModule(.circle, on: true); store.setModule(.circle, on: false)
    check(seen == ["circle true", "circle false"], "module_hooks_run_on_switch")
    guard let again = foundationStore(root, "modules.sqlite") else { return }
    check(again.modules == [.jots, .decisions], "modules_persist")
}

// MARK: 8. Reminder budget

@MainActor private func reminderBudgetChecks(_ root: URL) {
    guard let store = foundationStore(root, "budget.sqlite") else { return }
    let budget = ReminderBudget(store: store)
    let cal = AppTime.calendar
    let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 10))!
    check(budget.settings == ReminderSettings(), "budget_defaults_3_a_day_quiet_22_to_8")
    func ask(_ n: Int64, at: Date, kind: ReminderKind = .circleDue) -> ReminderGrant {
        budget.request(kind: kind, itemID: ShortID(kind: .person, number: n), text: "Message P-\(n)", now: at)
    }
    let g1 = ask(1, at: day)
    guard case .granted(let id1, let fire1) = g1 else { check(false, "budget_first_granted"); return }
    check(fire1 == day && ask(1, at: day + 60) == .duplicate(id: id1), "budget_same_item_same_day_once")
    _ = ask(2, at: day); _ = ask(3, at: day, kind: .decisionReview)
    let over = ask(4, at: day)
    let nextMorning = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 8))!
    check(over == .deferred(until: nextMorning), "budget_limit_defers_to_next_allowed_minute")
    // Quiet hours: asked at 23:30 → fires at 08:00 next day and counts on that day.
    let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23, minute: 30))!
    guard case .granted(_, let fireLate) = ask(5, at: late) else { check(false, "budget_quiet_hours"); return }
    check(fireLate == cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 8)), "budget_quiet_hours_move_to_their_end")
    budget.save(ReminderSettings(dailyLimit: 1, quietStart: 21 * 60, quietEnd: 7 * 60))
    check(budget.settings.dailyLimit == 1 && ReminderBudget(store: store).settings.quietStart == 21 * 60, "budget_settings_saved")
    // Delivery: pending until shown once; the Mac shows it in the first 10 minutes, then the phone takes over.
    check(budget.pending().count == 4, "budget_pending_lists_granted")
    let r = budget.pending().first { $0.id == id1 }!
    check(ReminderBudget.macShows(r, now: day + 60) && !ReminderBudget.phoneTakesOver(r, now: day + 60)
          && !ReminderBudget.macShows(r, now: day + 601) && ReminderBudget.phoneTakesOver(r, now: day + 601), "budget_mac_then_phone")
    budget.markDelivered(id1, by: "mac", at: day + 5)
    check(!budget.pending().contains { $0.id == id1 } && ask(1, at: day + 120) == .duplicate(id: id1), "budget_delivered_once")
    check(PhoneBoard.reminders(store: store, now: day).map(\.id).sorted() == budget.pending().map(\.id).sorted(), "phone_copy_carries_pending_reminders")
}

// MARK: 9. Weekly review

@MainActor private func weeklyReviewChecks(_ root: URL) {
    guard let store = foundationStore(root, "review.sqlite") else { return }
    let cal = AppTime.calendar
    let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
    let week = WeeklyReview.week(containing: wed)
    check(week.start == cal.date(from: DateComponents(year: 2026, month: 11, day: 16)) && week.duration == 7 * 86400, "review_week_is_monday_to_monday")
    WeeklyReview.register(ReviewSection(id: "test.empty", title: "Empty", module: nil, order: 5) { _, _ in [] })
    WeeklyReview.register(ReviewSection(id: "test.full", title: "Full", module: nil, order: 1) { _, _ in
        [ReviewItem(id: "x", item: nil, title: "Something", detail: "")] })
    WeeklyReview.register(ReviewSection(id: "test.circle", title: "Due", module: .circle, order: 2) { _, _ in
        [ReviewItem(id: "y", item: nil, title: "Someone", detail: "")] })
    check(WeeklyReview.sections(store: store, now: wed).map(\.0.id).filter { $0.hasPrefix("test.") } == ["test.full"], "review_hides_empty_and_off_sections")
    store.setModule(.circle, on: true)
    check(WeeklyReview.sections(store: store, now: wed).map(\.0.id).filter { $0.hasPrefix("test.") } == ["test.full", "test.circle"], "review_sections_by_order")
    let sun18 = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 18))!
    check(!WeeklyReview.nudgeDue(now: wed, lastNudged: nil) && !WeeklyReview.nudgeDue(now: sun18 - 60, lastNudged: nil)
          && WeeklyReview.nudgeDue(now: sun18, lastNudged: nil) && !WeeklyReview.nudgeDue(now: sun18 + 3600, lastNudged: sun18)
          && WeeklyReview.nudgeDue(now: sun18 + 7 * 86400, lastNudged: sun18), "review_nudge_sunday_evening_once_a_week")
}

// MARK: 10. Search

@MainActor private func globalSearchChecks(_ root: URL) {
    guard let store = foundationStore(root, "search.sqlite") else { return }
    store.add(title: "Budget review", area: "Work", importance: .medium, due: nil)
    let start = Date().addingTimeInterval(86400)
    CalendarCache(store: store).upsertCalendars(account: "a@example.com", [
        CalCalendar(account: "a@example.com", calendarID: "a@example.com", name: "Work", color: "#4285f4", owned: true, shown: true, primary: true)])
    CalendarCache(store: store).apply(account: "a@example.com", calendarID: "a@example.com", changes: [
        GoogleEventChange(eventID: "s1", cancelled: false, fields: CalEventFields(start: start, end: start + 1800, title: "Budget meeting", googleUpdated: Date()))],
        nextToken: nil)
    let res = GlobalSearch.run("budget", store: store)
    check(res.map(\.0) == [.task, .event] && res[0].1.first?.title == "Budget review" && res[1].1.first?.title == "Budget meeting", "search_finds_tasks_and_events")
    guard let task = store.cards.first else { check(false, "search setup"); return }
    check(GlobalSearch.run("t-\(task.id)", store: store).flatMap(\.1).map(\.id) == [ShortID(kind: .task, number: task.id)], "search_typed_id_exact")
    GlobalSearch.register(.jot, module: .jots) { s, q in
        JotStore(store: s).jots(addedFrom: .distantPast, to: .distantFuture).filter { $0.text.localizedCaseInsensitiveContains(q) }
            .map { SearchHit(id: $0.shortID, title: $0.text, detail: "", date: $0.added) }
    }
    JotStore(store: store).create(text: "Budget idea")
    check(!GlobalSearch.run("budget", store: store).map(\.0).contains(.jot), "search_skips_modules_that_are_off")
    store.setModule(.jots, on: true)
    check(GlobalSearch.run("budget", store: store).map(\.0) == [.task, .event, .jot], "search_registry_adds_kinds_in_order")
}

// MARK: 7. Make task from a selection

@MainActor private func makeTaskChecks(_ root: URL) {
    guard let store = foundationStore(root, "make.sqlite") else { return }
    let d = MakeTask.draft(selection: "  Send the revised budget to the team\nwith the new numbers  ", sourceTags: ItemTags(primary: "Work", others: ["Personal"]),
                           groups: ["Work", "Personal"])
    check(d.title == "Send the revised budget to the team" && d.notes == "Send the revised budget to the team\nwith the new numbers"
          && d.primaryTag == "Work" && d.others == ["Personal"], "make_task_draft_from_selection")
    let long = MakeTask.draft(selection: String(repeating: "word ", count: 60), sourceTags: nil, groups: ["Work"])
    check(long.title.count <= 120 && long.primaryTag == "Work" && long.notes.count > 120, "make_task_long_selection_title_clipped")
    guard let jot = JotStore(store: store).create(text: "Send the revised budget to the team") else { check(false, "make task setup"); return }
    guard let id = store.makeTask(d, due: nil, dueHasTime: false, from: jot.shortID) else { check(false, "make_task_created"); return }
    let t = ShortID(kind: .task, number: id)
    let link = store.itemLinks(of: t).first
    check(store.card(id)?.title == d.title && store.card(id)?.notes == d.notes && store.itemTags(t) == ItemTags(primary: "Work", others: ["Personal"])
          && link?.other == jot.shortID && link?.kind == .source && link?.isSubject == true && link?.madeBy == .manual, "make_task_links_back_as_source")
}

// MARK: 11. Calendar guests and kept records

@MainActor private func calendarFoundationChecks(_ root: URL) {
    guard let store = foundationStore(root, "calendar.sqlite") else { return }
    let item: [String: Any] = ["id": "g1", "summary": "Review", "updated": "2026-11-17T10:00:00Z",
                               "start": ["dateTime": "2026-11-20T10:00:00Z"], "end": ["dateTime": "2026-11-20T11:00:00Z"],
                               "attendees": [["email": "a@example.com", "responseStatus": "accepted"],
                                             ["email": "B@Example.com", "responseStatus": "needsAction", "self": true]]]
    let change: GoogleEventChange?
    do { change = try GoogleCalendarAPI.change(from: item) } catch { check(false, "guests parse: \(error)"); return }
    check(change?.guests == [CalGuest(email: "a@example.com", status: "accepted"), CalGuest(email: "b@example.com", status: "needsAction")],
          "google_event_guests_read")
    let cache = CalendarCache(store: store)
    cache.apply(account: "me@example.com", calendarID: "me@example.com", changes: [change!], nextToken: nil)
    guard let e = cache.event(account: "me@example.com", calendarID: "me@example.com", eventID: "g1") else { check(false, "guests stored"); return }
    check(e.guests.map(\.email) == ["a@example.com", "b@example.com"], "event_guests_stored")
    // An update without guests read keeps them.
    var noGuests = change!; noGuests.guests = nil
    cache.apply(account: "me@example.com", calendarID: "me@example.com", changes: [noGuests], nextToken: nil)
    check(cache.event(shortID: e.shortID)?.guests.count == 2, "guests_kept_when_not_read")
    // A linked event keeps a minimal record after Google deletes it and the row is gone.
    store.add(title: "Prep", area: "Work", importance: .medium, due: nil)
    guard let task = store.cards.first else { return }
    store.link(ShortID(kind: .task, number: task.id), e.id, actor: .user)
    var renamed = change!; renamed.fields?.title = "Review (moved)"
    cache.apply(account: "me@example.com", calendarID: "me@example.com", changes: [renamed], nextToken: nil)
    store.performForTest("DELETE FROM cal_events WHERE short_id=\(e.shortID)")
    let kept = cache.kept(shortID: e.shortID)
    check(kept?.title == "Review (moved)" && kept?.end.timeIntervalSince(kept!.start) == 3600 && store.item(e.id)?.title == "Review (moved)",
          "linked_event_keeps_a_record")
}
