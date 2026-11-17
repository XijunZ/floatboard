import Foundation
import FloatBoardCore
import SQLite3

/// The four areas together (integration of Jots, Circle, Decisions and Resolutions): typed ids in a decision link it, a
/// decision can serve a goal, the screening reads task notes and meeting notes, one reminder budget for Circle's due people
/// and decision reviews, and the weekly review shows both areas' sections.
@MainActor func integrationChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-integration-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    JotsArea.register(); CircleDue.register(); DecisionsArea.registerCore(); Resolutions.register()
    integrationLinkChecks(root)
    integrationScreeningChecks(root)
    integrationBudgetChecks(root)
    integrationPhoneMakeChecks(root)
    integrationUpgradeRehearsal(root)
}

@MainActor private func integrationStore(_ root: URL, _ name: String) -> Store? {
    do {
        let s = Store(db: try DB(url: root.appendingPathComponent(name)))
        for m in Module.allCases { s.setModule(m, on: true) }
        return s
    } catch { check(false, "integration setup \(name): \(error)"); return nil }
}

@MainActor private func integrationLinkChecks(_ root: URL) {
    guard let s = integrationStore(root, "links.sqlite") else { return }
    let js = JotStore(store: s), ds = DecisionStore(store: s), rs = ResolutionStore(store: s)
    guard let source = js.create(text: "Call notes: we decided to pause hiring until March.", now: decisionsNow),
          let other = js.create(text: "Hiring plan draft", now: decisionsNow),
          let anna = PeopleStore(store: s).create(name: "Anna Lopez", aliases: []),
          case .success(let goal) = rs.create(level: .quarter, period: GoalPeriod.current(.quarter, now: decisionsNow), title: "Keep costs flat", now: decisionsNow)
    else { check(false, "integration links setup"); return }
    let d = ds.record(DecisionDraft(text: "Pause hiring until March (see \(other.shortID.text), \(source.shortID.text))", quote: "we decided to pause hiring until March",
                                    why: "Ask \(anna.shortID.text) first", foundByClaude: true, source: .claude, sourceItem: source.shortID), now: decisionsNow)
    guard let d else { check(false, "integration decision"); return }
    let links = s.itemLinks(of: d.shortID)
    check(links.contains { $0.other == other.shortID && $0.madeBy == .manual } && links.contains { $0.other == anna.shortID },
          "decision_typed_ids_link_jots_and_people")
    check(links.first { $0.other == source.shortID }.map { $0.kind == .source && $0.madeBy == .auto } == true, "decision_source_link_kept_when_its_id_is_typed")
    var edited = d; edited.expected = "Costs stay flat (\(goal.shortID.text))"
    check(ds.update(edited, now: decisionsNow.addingTimeInterval(60)) && s.links(of: d.shortID).contains(goal.shortID), "decision_edit_links_a_typed_goal_id")
    // Resolutions' Link work takes a decision (ItemCatalog knows D-n).
    guard case .success(let goal2) = rs.create(level: .quarter, period: GoalPeriod.current(.quarter, now: decisionsNow), title: "Ship the new site", now: decisionsNow)
    else { check(false, "integration goal 2"); return }
    check(rs.linkWork(d.shortID, to: goal2.id, now: decisionsNow) == nil && rs.work(of: goal2.id).contains(d.shortID) && s.item(d.shortID)?.title == d.text,
          "goal_link_work_takes_a_decision")
}

@MainActor private func integrationScreeningChecks(_ root: URL) {
    guard let s = integrationStore(root, "screen.sqlite") else { return }
    let js = JotStore(store: s)
    s.add(title: "Vendor review", area: "Work", importance: .medium, due: nil)
    guard var task = s.cards.first(where: { $0.title == "Vendor review" }) else { check(false, "integration task"); return }
    task.notes = "We decided to drop the second vendor after the trial."
    s.update(task, now: decisionsNow.addingTimeInterval(-3600))
    guard let meeting = js.create(text: "Weekly sync. Decision: the launch moves to Thursday.", kind: .meetingNotes, source: .meeting,
                                  now: decisionsNow.addingTimeInterval(-7200)) else { check(false, "integration meeting notes"); return }
    let pending = DecisionScreening.pending(store: s, now: decisionsNow)
    let note = js.list(JotQuery(text: "", limit: 50)).map(\.jot).first { $0.kind == .taskNote }
    check(note != nil && pending.contains { $0.ref.hasPrefix("J-\(note!.id)@") && $0.kind == "task_note" && $0.text.contains("second vendor") }
          && pending.contains { $0.ref.hasPrefix("J-\(meeting.id)@") && $0.kind == "meeting_notes" }, "screening_reads_task_notes_and_meeting_notes")
}

@MainActor private func integrationBudgetChecks(_ root: URL) {
    guard let s = integrationStore(root, "budget.sqlite") else { return }
    let c = CircleStore(store: s), ds = DecisionStore(store: s)
    let added = decisionsNow.addingTimeInterval(-150 * 86400)
    var people: [Person] = []
    for i in 0..<2 {
        if let p = c.add(name: "Due Friend \(i)", tier: .close, tags: ItemTags(primary: nil, others: []), details: CircleDetails(),
                         handles: [Handle(kind: .phone, value: "4477009002\(i)0")], now: added).person { people.append(p) }
    }
    let recorded = decisionsNow.addingTimeInterval(-40 * 86400)
    let decisions = (0..<2).compactMap { ds.record(DecisionDraft(text: "Old decision \($0)", type: .operational), now: recorded) }
    guard people.count == 2, decisions.count == 2 else { check(false, "integration budget setup"); return }
    // Default limit 3 a day: Circle takes two, Decisions gets one and the other waits for tomorrow.
    let circle = CircleDue.requestReminders(store: s, now: decisionsNow)
    let reviews = DecisionReviews.askBudget(store: s, now: decisionsNow)
    let granted = { (g: [ReminderGrant]) in g.filter { if case .granted = $0 { return true }; return false }.count }
    let pend = ReminderBudget(store: s).pending()
    check(granted(circle) == 2 && granted(reviews) == 1 && reviews.contains { if case .deferred = $0 { return true }; return false }
          && pend.count == 3 && Set(pend.map(\.kind)) == [ReminderKind.circleDue.rawValue, ReminderKind.decisionReview.rawValue],
          "circle_and_decision_reminders_share_one_daily_limit")
    let ids = WeeklyReview.sections(store: s, now: decisionsNow).map(\.0.id)
    check(ids.contains("circle.due") && ids.contains(DecisionReviews.reviewsSection), "weekly_review_shows_circle_and_decisions")
}

// MARK: Make decision on the phone

@MainActor private func integrationPhoneMakeChecks(_ root: URL) {
    guard let s = integrationStore(root, "phone-make.sqlite") else { return }
    DecisionsArea.registerCore()
    let js = JotStore(store: s), ds = DecisionStore(store: s)
    guard let jot = js.create(text: "Supplier call: we decided to keep the old supplier.", now: decisionsNow.addingTimeInterval(-3600)),
          let phoneJot = js.add("Captured on the phone: we hire a designer in January.", kind: .jot, source: .phone, origin: "phone:abc-1",
                                 tags: [], now: decisionsNow.addingTimeInterval(-1800)) else { check(false, "phone make setup"); return }
    s.setTags(jot.shortID, primary: "Work", others: [])
    func make(_ id: String, source: String, text: String = "Keep the old supplier", madeAt: Date = decisionsNow) -> PhoneDecisionAction {
        var a = PhoneDecisionAction(id: id, decision: "", action: "make", madeAt: ISO8601DateFormatter().string(from: madeAt))
        a.text = text; a.why = "Cheaper"; a.expected = "Costs flat"; a.confidence = "medium"; a.type = "strategic"
        a.quote = "we decided to keep the old supplier"; a.source = source
        return a
    }
    let r1 = DecisionPhone.apply([make("m1", source: jot.shortID.text), make("m1", source: jot.shortID.text)], store: s, now: decisionsNow)
    let made = ds.all().filter { $0.source == .phone }
    let d = made.first
    check(r1.applied == ["m1", "m1"] && made.count == 1 && d?.status == .decided && d?.foundByClaude == false && d?.why == "Cheaper"
          && d?.expected == "Costs flat" && d?.confidence == .medium && d?.type == .strategic && d?.quote == "we decided to keep the old supplier",
          "phone_decision_recorded_once_with_its_four_fields")
    check(d.map { x in s.itemLinks(of: x.shortID).contains { $0.other == jot.shortID && $0.kind == .source && $0.madeBy == .manual } } == true
          && d.map { s.itemTags($0.shortID).primary == "Work" } == true, "phone_decision_linked_to_its_jot_with_its_tags")
    // By the jot's key (a jot made on the phone); a jot not here yet waits a day, then the decision is recorded without it.
    let r2 = DecisionPhone.apply([make("m2", source: "phone:abc-1", text: "Hire a designer in January"),
                                  make("m3", source: "phone:not-here-yet", text: "Move the offsite"),
                                  make("m4", source: "phone:never-came", text: "Close the old account", madeAt: decisionsNow.addingTimeInterval(-2 * 86400))],
                                 store: s, now: decisionsNow)
    let byText = { (t: String) in ds.all().first { $0.text == t } }
    check(r2.applied == ["m2", "m4"] && r2.waiting == ["m3"] && byText("Move the offsite") == nil
          && byText("Hire a designer in January").map { x in s.itemLinks(of: x.shortID).contains { $0.other == phoneJot.shortID } } == true
          && byText("Close the old account").map { s.itemLinks(of: $0.shortID).isEmpty } == true, "phone_decision_waits_a_day_for_its_jot_then_recorded")
    // Decisions switched off when the Mac takes it in: kept as a jot-linked Maybe draft.
    s.setModule(.decisions, on: false)
    let r3 = DecisionPhone.apply([make("m5", source: jot.shortID.text, text: "Pause the newsletter")], store: s, now: decisionsNow)
    let off = byText("Pause the newsletter")
    check(r3.applied == ["m5"] && off?.status == .maybe && off.map { x in s.itemLinks(of: x.shortID).contains { $0.other == jot.shortID } } == true,
          "phone_decision_kept_as_maybe_while_decisions_is_off")
    check(DecisionPhone.apply([make("m6", source: "", text: "   ")], store: s, now: decisionsNow).skipped.map(\.0) == ["m6"], "empty_phone_decision_skipped")
    // An older phone's jot action never opens a form and never waits: a Maybe draft linked to the jot.
    check(JotActions.makeDecision?(s, "We go with plan B\nbecause it is cheaper", jot.shortID) == true
          && byText("We go with plan B").map { $0.status == .maybe && $0.source == .phone } == true, "older_phone_make_decision_kept_as_maybe_draft")
}

// MARK: Upgrade rehearsal (v11 -> 16)

/// A synthetic v11 board shaped like a real one (90 tasks in four groups, done and deleted ones, history, calendar events
/// linked to tasks, task-to-task links, settings) upgraded to the current version: nothing lost, groups become primary tags,
/// all four areas on. Prints the counts.
@MainActor private func integrationUpgradeRehearsal(_ root: URL) {
    let url = root.appendingPathComponent("rehearsal-v11.sqlite")
    let groups = ["Work", "Personal", "Family", "Side project"]
    let statuses = ["todo", "doing", "watch", "done"]
    var sql = groups.enumerated().map { "INSERT INTO areas(name,color,position) VALUES('\($0.1)','#0A84FF',\($0.0));" }.joined(separator: "\n")
    for i in 1...90 {
        let g = groups[i % 4], st = statuses[i % 4], deleted = i % 15 == 0 ? 1 : 0
        let due = i % 3 == 0 ? "\(1_794_391_200 + i * 86400)" : "NULL", day = i % 3 == 0 ? "'2026-11-\(String(format: "%02d", 11 + i % 18))'" : "NULL"
        sql += "\nINSERT INTO cards(id,title,notes,area,status,created,updated,deleted,due,due_day) VALUES(\(i),'Task \(i)','\(i % 5 == 0 ? "Notes for task \(i), see T-\(i % 90 + 1)" : "")','\(g)','\(st)',\(1_790_000_000 + i),\(1_790_000_000 + i),\(deleted),\(due),\(day));"
        sql += "\nINSERT INTO events(card_id,at,kind,actor,uuid) VALUES(\(i),\(1_790_000_000 + i),'created','user','u\(i)');"
    }
    for e in 1...20 {
        sql += "\nINSERT INTO cal_events(short_id,account,calendar_id,event_id,start,end,all_day,title,google_updated) VALUES(\(e),'a@example.com','a@example.com','ev\(e)',\(1_794_391_200 + e * 3600),\(1_794_394_800 + e * 3600),0,'Meeting \(e)',1);"
    }
    for e in 1...15 { sql += "\nINSERT INTO links(from_type,from_id,to_type,to_id,created,actor) VALUES('E','\(e)','T','\(e * 5)',1,'user');" }
    for t in 1...10 { sql += "\nINSERT INTO links(from_type,from_id,to_type,to_id,created,actor) VALUES('T','\(t)','T','\(t + 40)',1,'user');" }
    sql += "\nINSERT INTO meta(key,value) VALUES('time_zone','Europe/London'),('quiet_start','22:00'),('first_launch_at','1790000000');"
    guard makeV11Schema(url, extra: sql) else { check(false, "rehearsal v11 board"); return }
    func raw(_ q: String) -> Int64 {
        var h: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(h) }
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, sqlite3_prepare_v2(h, q, -1, &st, nil) == SQLITE_OK,
              sqlite3_step(st) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(st, 0)
    }
    let before = (cards: raw("SELECT count(*) FROM cards"), live: raw("SELECT count(*) FROM cards WHERE deleted=0"), links: raw("SELECT count(*) FROM links"),
                  events: raw("SELECT count(*) FROM cal_events"), history: raw("SELECT count(*) FROM events"), meta: raw("SELECT count(*) FROM meta"),
                  titles: raw("SELECT sum(length(title) + length(notes)) FROM cards"))
    let store: Store
    do { store = Store(db: try DB(url: url)) } catch { check(false, "rehearsal upgrade: \(error)"); return }
    let after = (cards: raw("SELECT count(*) FROM cards"), live: raw("SELECT count(*) FROM cards WHERE deleted=0"), links: raw("SELECT count(*) FROM links"),
                 events: raw("SELECT count(*) FROM cal_events"), history: raw("SELECT count(*) FROM events"), meta: raw("SELECT count(*) FROM meta"),
                 titles: raw("SELECT sum(length(title) + length(notes)) FROM cards"))
    let oldMeta = ["time_zone", "quiet_start", "first_launch_at"].allSatisfy { k in raw("SELECT count(*) FROM meta WHERE key='\(k)'") == 1 }
    check(raw("PRAGMA user_version") == Int64(DB.schemaVersion) && before.cards == 90 && after.cards == before.cards && after.live == before.live
          && after.titles == before.titles && after.history >= before.history && after.events == before.events && after.links >= before.links
          && after.meta >= before.meta && oldMeta, "rehearsal_v11_upgrade_loses_no_card_link_event_or_setting")
    // The 25 links made above, each found again by its two ends.
    check(raw("SELECT count(*) FROM links WHERE (from_type='E' AND to_type='T' AND CAST(to_id AS INTEGER)=CAST(from_id AS INTEGER)*5) OR (from_type='T' AND to_type='T' AND CAST(to_id AS INTEGER)=CAST(from_id AS INTEGER)+40)") == 25,
          "rehearsal_every_link_kept")
    let live = store.cards
    check(!live.isEmpty && live.allSatisfy { store.itemTags(ShortID(kind: .task, number: $0.id)).primary == $0.area }
          && store.areas.map(\.name) == groups, "rehearsal_groups_become_primary_tags")
    check(store.modules == Set(Module.allCases), "rehearsal_all_four_areas_on")
    print("REHEARSAL v11->\(DB.schemaVersion): cards \(before.cards)->\(after.cards) (live \(before.live)->\(after.live)), links \(before.links)->\(after.links), "
          + "calendar events \(before.events)->\(after.events), history \(before.history)->\(after.history), meta \(before.meta)->\(after.meta), "
          + "board tasks shown \(live.count), groups \(store.areas.count), tags \(store.tags.count), modules on \(store.modules.count)")
}
