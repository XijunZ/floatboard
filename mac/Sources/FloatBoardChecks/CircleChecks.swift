import Foundation
import FloatBoardCore
import SQLite3

/// Circle (docs/superpowers/specs/2026-11-17-circle-design.md): schema 14, handles, merges, the three clocks, the due list
/// and reminders, suggestions, timeline. Readers, imports, updates and the phone copy are in CircleMoreChecks.swift.
@MainActor func circleChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    circleSchemaChecks(root)
    circleHandleChecks(root)
    circleClockChecks()
    circleStoreClockChecks(root)
    circleMergeChecks(root)
    circleDueChecks(root)
    circleSuggestionChecks(root)
    circleTimelineChecks(root)
}

/// A scratch board with Circle on.
@MainActor func circleStore(_ root: URL, _ name: String) -> Store? {
    checkStore(root, name, modules: [.circle])
}

/// 2026-11-18 (a Wednesday) at `h`:00, London.
func circleDay(_ day: Int, _ h: Int = 12, month: Int = 11) -> Date {
    AppTime.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: h))!
}

@MainActor private func circleSchemaChecks(_ root: URL) {
    check(DB.schemaVersion >= 14, "circle_schema_version_at_least_14")
    guard let s = circleStore(root, "schema.sqlite") else { return }
    let tables = Set(((try? s.db.query("SELECT name FROM sqlite_master WHERE type='table'") { DB.text($0, 0) }) ?? [])) // try?-ok: empty fails the check
    check(["circle_people", "person_handles", "circle_exchanges", "circle_channels", "circle_merges", "circle_candidates",
           "circle_dismissed", "linkedin_imports", "linkedin_rows", "circle_updates", "officer_candidates"].allSatisfy(tables.contains),
          "circle_tables_exist")
    // No column anywhere in Circle's tables can hold message text.
    let cols = ["circle_exchanges", "circle_channels"].flatMap { t in
        ((try? s.db.query("PRAGMA table_info(\(t))") { DB.text($0, 1) }) ?? []) } // try?-ok: empty fails the check
    check(!cols.isEmpty && !cols.contains { ["text", "body", "preview", "subject", "snippet"].contains($0) }, "circle_stores_no_message_text")
    // A board at 12 (the foundation's fixture) upgrades to exactly a new board's shape, keeping its people.
    let v12 = root.appendingPathComponent("v12.sqlite")
    guard makeBoardFromFixture(v12, fixture: "schema-v12.json", version: 12,
                               extra: "INSERT INTO people(name, added, updated) VALUES('Kept Person', 1, 1);") else { check(false, "v12 board setup"); return }
    guard let up = foundationStore(root, "v12.sqlite") else { return }
    let fresh = Set(((try? s.db.query("SELECT type || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") { DB.text($0, 0) }) ?? [])) // try?-ok: empty fails the check
    let upgraded = Set(((try? up.db.query("SELECT type || name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") { DB.text($0, 0) }) ?? [])) // try?-ok: empty fails the check
    check(!fresh.isEmpty && fresh == upgraded && PeopleStore(store: up).people().map(\.name) == ["Kept Person"], "v12_board_upgrades_to_14")
}

/// A board at `version` built from a schema fixture (its tables and indexes), plus `extra` SQL.
func makeBoardFromFixture(_ url: URL, fixture: String, version: Int, extra: String = "") -> Bool {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/\(fixture)")
    guard let data = try? Data(contentsOf: file), // try?-ok: nil fails the check
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return false } // try?-ok: nil fails the check
    let rank = ["table": 0, "index": 1, "trigger": 2]
    let sql = rows.filter { !($0[1] as? String ?? "").hasPrefix("sqlite_") }
        .sorted { rank[$0[0] as? String ?? "", default: 3] < rank[$1[0] as? String ?? "", default: 3] }.compactMap { $0[3] as? String }.joined(separator: ";\n")
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { return false }
    return sqlite3_exec(h, sql + ";\nPRAGMA user_version = \(version);\n" + extra, nil, nil, nil) == SQLITE_OK
}

@MainActor private func circleHandleChecks(_ root: URL) {
    check(Handles.normalize(.phone, "+44 7700 900123") == "447700900123" && Handles.normalize(.phone, "07700 900123") == "447700900123"
          && Handles.normalize(.phone, "0044 7700-900123") == "447700900123" && Handles.normalize(.phone, "12") == nil,
          "phone_numbers_normalised")
    check(Handles.normalize(.email, " Anna@Example.COM ") == "anna@example.com" && Handles.normalize(.email, "nope") == nil, "emails_normalised")
    check(Handles.normalize(.linkedin, "https://www.linkedin.com/in/Anna-Example-123/?trk=x") == "linkedin.com/in/anna-example-123"
          && Handles.normalize(.linkedin, "https://example.com/x") == nil, "linkedin_urls_normalised")
    check(Handles.fromWhatsApp("447700900123@s.whatsapp.net") == Handle(kind: .phone, value: "447700900123")
          && Handles.fromWhatsApp("1203630@lid") == Handle(kind: .whatsapp, value: "1203630@lid"), "whatsapp_ids_become_phones")

    guard let s = circleStore(root, "handles.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let anna = c.add(name: "Anna Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                           handles: [Handle(kind: .email, value: "ANNA@example.com"), Handle(kind: .phone, value: "07700 900123")]).person
    else { check(false, "handles setup"); return }
    check(Set(c.handles(anna.id)) == [Handle(kind: .email, value: "anna@example.com"), Handle(kind: .phone, value: "447700900123")]
          && c.person(owning: Handle(kind: .phone, value: "+447700900123")) == anna.id, "handles_saved_normalised_and_found")
    // A second person with the same email: merged automatically into the first (exact match), and the merge can be split.
    guard let dup = c.add(name: "A. Example", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: []).person
    else { check(false, "dup setup"); return }
    let r = c.addHandle(dup.id, Handle(kind: .email, value: "anna@example.com"))
    check(r == .merged(into: anna.id) && PeopleStore(store: s).person(dup.id)?.deleted == true
          && PeopleStore(store: s).person(anna.id)?.aliases.contains("A. Example") == true && c.merges(of: anna.id).first?.auto == true,
          "exact_email_match_merges_automatically")
    // A LinkedIn profile on someone else is refused (a suggestion, never an automatic merge).
    guard let bo = c.add(name: "Bo Other", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                         handles: [Handle(kind: .linkedin, value: "https://linkedin.com/in/bo")]).person else { check(false, "bo setup"); return }
    if case .refused(let why) = c.addHandle(anna.id, Handle(kind: .linkedin, value: "linkedin.com/in/bo")) {
        check(why.contains("Bo Other") && c.person(owning: Handle(kind: .linkedin, value: "linkedin.com/in/bo")) == bo.id, "other_handle_kinds_never_merge")
    } else { check(false, "other_handle_kinds_never_merge") }
    // Rules for the fixed tags and prospects.
    check(c.add(name: "Fam", tier: .family, tags: ItemTags(primary: TagRules.prospect, others: []), details: CircleDetails(), handles: []).problem
          == "Prospect can't be used on Family.", "prospect_refused_on_family")
    var prospect = CircleDetails(); prospect.purpose = ProspectPurpose.career.rawValue; prospect.stage = ProspectStage.inTouch.rawValue
    for i in 1...5 {
        _ = c.add(name: "Prospect \(i)", tier: .network, tags: ItemTags(primary: TagRules.prospect, others: []), details: prospect, handles: [])
    }
    check(c.activeProspects().count == 5
          && c.add(name: "Prospect 6", tier: .network, tags: ItemTags(primary: TagRules.prospect, others: []), details: prospect, handles: []).problem
          == "You already have 5 active prospects. Move one to dropped first.", "at_most_five_active_prospects")
    var dropped = prospect; dropped.stage = ProspectStage.dropped.rawValue
    check(c.add(name: "Prospect 7", tier: .network, tags: ItemTags(primary: TagRules.prospect, others: []), details: dropped, handles: []).problem == nil,
          "dropped_prospects_do_not_count")
    // Details round-trip.
    var d = c.details(anna.id); d.company = "Acme"; d.role = "CFO"; d.birthday = "1985-04-12"; d.notes = "Met at the conference"
    check(c.save(anna.id, d) == nil && c.details(anna.id).company == "Acme" && c.details(anna.id).birthday == "1985-04-12", "details_saved")
}

@MainActor private func circleClockChecks() {
    let t0 = circleDay(1, month: 9)
    func ex(_ day: Double, _ dir: Direction, _ ch: Channel = .whatsapp) -> Exchange {
        Exchange(id: Int64(day * 10), channel: ch, direction: dir, at: t0.addingTimeInterval(day * 86400), handle: Handle(kind: .phone, value: "1"),
                 name: "", ref: "", ignored: false)
    }
    let now = circleDay(18)
    // In 3 Sep, out 20 Sep (17 days later: no conversation); in 1 Oct and out 10 Oct (9 days: a conversation on 10 Oct).
    let list = [ex(2, .incoming), ex(19, .outgoing), ex(30, .incoming), ex(39, .outgoing, .gmail)]
    let c = CircleClock.clocks(exchanges: list, added: t0, tier: .close, tags: [], intervalDays: nil, snoozedUntil: nil, now: now)
    check(c.lastConversation == t0.addingTimeInterval(39 * 86400) && c.lastHeard == t0.addingTimeInterval(30 * 86400)
          && c.lastOutreach == t0.addingTimeInterval(39 * 86400), "clocks_conversation_needs_both_directions_within_14_days")
    check(c.dueDate == AppTime.calendar.date(byAdding: .day, value: 14, to: c.lastConversation!) && c.due, "close_friend_due_two_weeks_after")
    // One-way only: never a conversation; due counts from the date added.
    let oneWay = CircleClock.clocks(exchanges: [ex(2, .incoming), ex(5, .incoming)], added: t0, tier: .family, tags: [], intervalDays: nil,
                                    snoozedUntil: nil, now: now)
    check(oneWay.lastConversation == nil && oneWay.dueDate == AppTime.calendar.date(byAdding: .month, value: 1, to: t0) && oneWay.due,
          "one_way_messages_are_not_a_conversation")
    // A met meeting is a conversation by itself.
    let met = CircleClock.clocks(exchanges: [ex(40, .met, .calendar)], added: t0, tier: .network, tags: [], intervalDays: nil, snoozedUntil: nil, now: now)
    check(met.lastConversation == t0.addingTimeInterval(40 * 86400) && met.conversationVia == .calendar && !met.due, "meeting_counts_as_talked")
    // Outreach in the last 7 days: not due. Snoozed: not due. Investor caps Network's 3 months... (network is already 3).
    let reached = CircleClock.clocks(exchanges: list + [ex(76, .outgoing)], added: t0, tier: .close, tags: [], intervalDays: nil, snoozedUntil: nil, now: now)
    check(!reached.due && reached.lastOutreach == t0.addingTimeInterval(76 * 86400), "recent_outreach_holds_due_for_7_days")
    let snoozed = CircleClock.clocks(exchanges: list, added: t0, tier: .close, tags: [], intervalDays: nil, snoozedUntil: now + 86400, now: now)
    check(!snoozed.due && snoozed.snoozedUntil == now + 86400, "snoozed_is_not_due")
    check(CircleClock.interval(tier: .network, tags: [TagRules.investor], intervalDays: 200) == DateComponents(month: 3)
          && CircleClock.interval(tier: .network, tags: [], intervalDays: 200) == DateComponents(day: 200)
          && CircleClock.interval(tier: .family, tags: [], intervalDays: nil) == DateComponents(month: 1)
          && CircleClock.interval(tier: .close, tags: [TagRules.investor], intervalDays: nil) == DateComponents(day: 14), "intervals_with_investor_cap")
    // Ignored (corrected) meetings don't count.
    var wrong = ex(40, .met, .calendar); wrong.ignored = true
    check(CircleClock.clocks(exchanges: [wrong], added: t0, tier: .network, tags: [], intervalDays: nil, snoozedUntil: nil, now: now).lastConversation == nil,
          "corrected_meeting_does_not_count")
}

@MainActor private func circleStoreClockChecks(_ root: URL) {
    guard let s = circleStore(root, "clocks.sqlite") else { return }
    let c = CircleStore(store: s)
    let added = circleDay(1, month: 8)
    guard let p = c.add(name: "Chris Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                        handles: [Handle(kind: .phone, value: "447700900001")], now: added).person else { check(false, "clock setup"); return }
    let h = Handle(kind: .phone, value: "447700900001")
    c.record([ExchangeInput(channel: .whatsapp, direction: .incoming, at: circleDay(1, 9), handle: h, name: "Chris"),
              ExchangeInput(channel: .whatsapp, direction: .incoming, at: circleDay(1, 15), handle: h, name: "Chris"),
              ExchangeInput(channel: .whatsapp, direction: .outgoing, at: circleDay(2, 10), handle: h, name: "")], now: circleDay(2))
    check(c.exchanges(of: p.id).count == 2 && c.exchanges(of: p.id).first { $0.direction == .incoming }?.at == circleDay(1, 15),
          "exchanges_kept_one_per_day_and_direction")
    let now = circleDay(18)
    check(c.clocks(p, now: now).lastConversation == circleDay(2, 10) && c.clocks(p, now: now).due, "store_clocks_from_exchanges")
    c.contacted(p.id, at: now)
    check(!c.clocks(p, now: now + 3600).due && c.clocks(p, now: now + 8 * 86400).due, "contacted_clears_due_for_a_week")
    c.talked(p.id, at: now + 3600)
    check(c.clocks(p, now: now + 2 * 3600).lastConversation == now + 3600 && !c.clocks(p, now: now + 8 * 86400).due, "we_talked_is_a_conversation")
    c.snooze(p.id, now: now + 15 * 86400)
    check(c.details(p.id).snoozedUntil == AppTime.calendar.date(byAdding: .day, value: 14, to: now + 15 * 86400), "snooze_pushes_back_one_interval")
    // Bulk changes: tier and tags for several, with the fixed-tag rules.
    guard let q = c.add(name: "Dana Example", tier: .family, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: []).person
    else { return }
    check(c.setTier([p.id, q.id], .network).isEmpty && PeopleStore(store: s).person(q.id)?.tier == .network, "bulk_tier_change")
    check(c.addTags([p.id, q.id], [TagRules.investor]).isEmpty && s.itemTags(q.shortID).all == [TagRules.investor], "bulk_add_tag")
    c.setTier([q.id], .family)
    check(c.addTags([q.id], [TagRules.prospect]) == ["Dana Example: Prospect can't be used on Family."], "bulk_tags_checked_by_rules")
    check(c.setTier([q.id], .family).isEmpty, "bulk_tier_ok")
    check(c.removeTags([p.id, q.id], [TagRules.investor]).isEmpty && s.itemTags(p.shortID).all.isEmpty, "bulk_remove_tag")
}

@MainActor private func circleMergeChecks(_ root: URL) {
    guard let s = circleStore(root, "merge.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let a = c.add(name: "Eve Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "eve@example.com")]).person,
          let b = c.add(name: "Eve E.", tier: .network, tags: ItemTags(primary: TagRules.investor, others: []), details: {
              var d = CircleDetails(); d.company = "Fund"; return d }(), handles: [Handle(kind: .phone, value: "447700900002")]).person
    else { check(false, "merge setup"); return }
    s.add(title: "Call Eve", area: "Personal", importance: .medium, due: nil)
    guard let task = s.cards.last else { return }
    s.link(ShortID(kind: .task, number: task.id), b.shortID, actor: .user)
    c.talked(b.id, at: circleDay(10))
    check(c.merge(kept: a.id, merged: b.id) == nil, "merge_two_people")
    check(c.handles(a.id).count == 2 && s.links(of: a.shortID) == [ShortID(kind: .task, number: task.id)] && s.links(of: b.shortID).isEmpty
          && s.itemTags(a.shortID).all == [TagRules.investor] && c.details(a.id).company == "Fund"
          && PeopleStore(store: s).person(a.id)?.aliases == ["Eve E."] && c.clocks(PeopleStore(store: s).person(a.id)!, now: circleDay(11)).lastConversation == circleDay(10),
          "merge_moves_handles_links_tags_details_and_talks")
    guard let m = c.merges(of: a.id).first else { check(false, "merge record"); return }
    c.split(m.id)
    check(c.handles(a.id) == [Handle(kind: .email, value: "eve@example.com")] && c.handles(b.id) == [Handle(kind: .phone, value: "447700900002")]
          && s.links(of: b.shortID) == [ShortID(kind: .task, number: task.id)] && s.links(of: a.shortID).isEmpty
          && s.itemTags(a.shortID).all.isEmpty && c.details(a.id).company.isEmpty && PeopleStore(store: s).person(a.id)?.aliases == []
          && PeopleStore(store: s).person(b.id)?.deleted == false && c.merges(of: a.id).isEmpty, "split_puts_everything_back")
    // Suggestions: the same name (case and accents ignored) or a name that is another's alias.
    _ = c.add(name: "José Example", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: [])
    _ = c.add(name: "jose example", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: [])
    let sug = c.mergeSuggestions()
    check(sug.count == 1 && sug.first?.reason == "Same name", "merge_suggested_on_same_name")
    if let first = sug.first { c.dismiss(first.key) }
    check(c.mergeSuggestions().isEmpty, "dismissed_merge_suggestion_stays_away")
}

@MainActor private func circleDueChecks(_ root: URL) {
    guard let s = circleStore(root, "due.sqlite") else { return }
    let c = CircleStore(store: s)
    let added = circleDay(1, month: 6)
    var made: [Person] = []
    for (i, tier) in [PersonTier.family, .close, .network, .close, .close].enumerated() {
        if let p = c.add(name: "Due Person \(i)", tier: tier, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                         handles: [Handle(kind: .phone, value: "4477009001\(i)0")], now: added).person { made.append(p) }
    }
    guard made.count == 5 else { check(false, "due setup"); return }
    // Network person talked last month: not due. Others: never talked since June: due.
    c.talked(made[2].id, at: circleDay(10, month: 10))
    let now = circleDay(18, 10, month: 10)
    let due = CircleDue.entries(store: s, now: now)
    check(Set(due.map(\.person.id)) == Set([made[0], made[1], made[3], made[4]].map(\.id)) && due.allSatisfy(\.overdue), "due_this_week_lists_past_interval")
    // Budget: at most the daily limit (3), most overdue first (the close friends, due since mid June; Family waits).
    let grants = CircleDue.requestReminders(store: s, now: now)
    check(grants.filter { if case .granted = $0 { return true }; return false }.count == 3 && ReminderBudget(store: s).pending().count == 3
          && ReminderBudget(store: s).pending().contains { $0.item == made[1].shortID.text }
          && !ReminderBudget(store: s).pending().contains { $0.item == made[0].shortID.text }, "due_reminders_inside_the_budget_most_overdue_first")
    _ = CircleDue.requestReminders(store: s, now: now + 3600)
    check(ReminderBudget(store: s).pending().count == 3, "due_reminders_not_repeated_the_same_day")
    // A reminder task: one per person; while it is open no budget reminder.
    guard let tid = CircleDue.makeTask(store: s, personID: made[4].id, now: now) else { check(false, "due_make_task"); return }
    check(s.card(tid)?.title == "Message Due Person 4" && s.links(of: made[4].shortID) == [ShortID(kind: .task, number: tid)]
          && CircleDue.makeTask(store: s, personID: made[4].id, now: now) == tid, "make_task_once_linked_to_person")
    check(CircleDue.entries(store: s, now: now).first { $0.person.id == made[4].id }?.hasTask == true, "due_entry_shows_its_task")
    // The weekly review lists Circle's due people.
    CircleDue.register()
    let review = WeeklyReview.sections(store: s, now: now).first { $0.0.id == "circle.due" }
    check(review?.1.count == 4 && review?.0.order == 40, "weekly_review_has_circle_due")
    // Search finds people by name, company, handle; a typed id finds exactly that person.
    var d = c.details(made[1].id); d.company = "Northwind"; c.save(made[1].id, d)
    check(GlobalSearch.run("northwind", store: s).first { $0.0 == .person }?.1.map(\.id) == [made[1].shortID]
          && GlobalSearch.run("447700900110", store: s).first { $0.0 == .person }?.1.map(\.id) == [made[1].shortID], "search_finds_people")
    // Context: a birthday this week and a meeting next week.
    d = c.details(made[3].id); d.birthday = "1990-10-21"; c.save(made[3].id, d)
    check(CircleDue.entries(store: s, now: now).first { $0.person.id == made[3].id }?.context.first?.hasPrefix("Birthday") == true, "birthday_context")
    // Circle off: nothing requested, review hidden.
    s.setModule(.circle, on: false)
    check(CircleDue.requestReminders(store: s, now: now + 86400).isEmpty && WeeklyReview.sections(store: s, now: now).first { $0.0.id == "circle.due" } == nil,
          "circle_off_stops_reminders")
}

@MainActor private func circleSuggestionChecks(_ root: URL) {
    guard let s = circleStore(root, "sugg.sqlite") else { return }
    let c = CircleStore(store: s)
    let wa = Handle(kind: .phone, value: "447700900555"), oneWay = Handle(kind: .email, value: "news@example.com")
    c.record([ExchangeInput(channel: .whatsapp, direction: .incoming, at: circleDay(10), handle: wa, name: "Fay Example"),
              ExchangeInput(channel: .whatsapp, direction: .outgoing, at: circleDay(11), handle: wa, name: ""),
              ExchangeInput(channel: .gmail, direction: .incoming, at: circleDay(11), handle: oneWay, name: "News")], now: circleDay(12))
    let sug = c.conversationSuggestions()
    check(sug.map(\.handle) == [wa] && sug.first?.name == "Fay Example" && sug.first?.channels == [.whatsapp], "suggested_from_two_way_conversations")
    c.dismiss(sug[0].key)
    check(c.conversationSuggestions().isEmpty, "dismissed_conversation_suggestion")
}

@MainActor private func circleTimelineChecks(_ root: URL) {
    guard let s = circleStore(root, "timeline.sqlite") else { return }
    let c = CircleStore(store: s)
    guard let p = c.add(name: "Gus Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                        handles: [Handle(kind: .email, value: "gus@example.com")]).person else { return }
    c.record([ExchangeInput(channel: .gmail, direction: .outgoing, at: circleDay(10), handle: Handle(kind: .email, value: "gus@example.com"), name: "",
                            ref: "me@example.com")], now: circleDay(10))
    guard let jot = JotStore(store: s).create(text: "Lunch idea with Gus", now: circleDay(11)) else { return }
    s.link(jot.shortID, p.shortID, actor: .user)
    let rows = CircleTimeline.rows(store: s, personID: p.id)
    check(rows.count == 2 && rows[0].item == jot.shortID && rows[1].title == "Email sent" && rows[1].channel == .gmail, "timeline_lists_exchanges_and_items")
}

/// Drops Circle's version-14 tables (for checks that build an older board from a new one).
let circleV14Drops = ["circle_people", "person_handles", "circle_exchanges", "circle_channels", "circle_merges", "circle_candidates",
                      "circle_dismissed", "linkedin_imports", "linkedin_rows", "circle_updates", "officer_candidates"]
    .map { "DROP TABLE \($0);" }.joined(separator: " ")

/// Codex C1: a split puts back only what is unchanged since the merge; a field the owner edited afterwards stays.
@MainActor func circleSplitEditChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-split-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = circleStore(root, "split-edit.sqlite") else { return }
    let c = CircleStore(store: s)
    var md = CircleDetails(); md.company = "Fund"; md.role = "Partner"; md.notes = "From the merged card"
    guard let a = c.add(name: "Uma Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: []).person,
          let b = c.add(name: "Uma E.", tier: .close, tags: ItemTags(primary: nil, others: []), details: md, handles: []).person,
          c.merge(kept: a.id, merged: b.id) == nil, let m = c.merges(of: a.id).first else { check(false, "split edit setup"); return }
    var kd = c.details(a.id); kd.company = "Fund Two"; kd.notes = ""   // the owner edits company and clears notes after the merge
    c.save(a.id, kd)
    c.split(m.id)
    let after = c.details(a.id)
    check(after.company == "Fund Two" && after.role.isEmpty && after.notes.isEmpty && c.details(b.id).company == "Fund",
          "split_keeps_fields_edited_after_the_merge")
}
