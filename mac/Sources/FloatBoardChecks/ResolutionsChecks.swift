import Foundation
import FloatBoardCore
import SQLite3

/// Resolutions (docs/superpowers/specs/2026-11-17-resolutions-design.md): schema 16, periods, limits, parent links that
/// can't loop, serves links (picker and typed R-n), progress without scoring, rollover, review notes as jots, nudges,
/// search, the board filter's task set and the phone's copy.
@MainActor func resolutionsChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-resolutions-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    Resolutions.register()
    resolutionSchemaChecks(root)
    resolutionPeriodChecks()
    resolutionCreateChecks(root)
    resolutionParentChecks(root)
    resolutionWorkChecks(root)
    resolutionProgressChecks(root)
    resolutionReviewChecks(root)
    resolutionNudgeChecks(root)
    resolutionSearchPhoneChecks(root)
}

/// 12:00 on a day in the app's zone.
private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    AppTime.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)) ?? Date()
}
private let nov17 = day(2026, 11, 17)

@MainActor private func goalsStore(_ root: URL, _ name: String) -> Store? {
    guard let s = foundationStore(root, name) else { return nil }
    s.setModule(.resolutions, on: true)
    s.setModule(.jots, on: true)
    return s
}

@MainActor private func make(_ r: ResolutionStore, _ level: GoalLevel, _ key: String, _ title: String, parent: Int64? = nil) -> Goal? {
    guard let p = GoalPeriod.parse(level: level, key: key) else { check(false, "period \(key)"); return nil }
    switch r.create(level: level, period: p, title: title, parent: parent, now: nov17) {
    case .success(let g): return g
    case .failure(let e): check(false, "create \(title): \(e.message)"); return nil
    }
}

private extension Result { var ok: Success? { if case .success(let v) = self { return v } else { return nil } } }

private func refused<T>(_ r: Result<T, GoalRefusal>) -> Bool { if case .failure = r { return true } else { return false } }

@MainActor private func task(_ store: Store, _ title: String, done: Bool = false) -> ShortID {
    store.add(title: title, area: store.areas.first?.name ?? "Work", importance: .medium, due: nil, status: done ? .done : .todo)
    return ShortID(kind: .task, number: store.cards.first { $0.title == title }?.id ?? 0)
}

// MARK: Schema 16

private func masterRows16(_ url: URL) -> [[String?]] {
    var h: OpaquePointer?, st: OpaquePointer?
    defer { sqlite3_finalize(st); sqlite3_close(h) }
    guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_prepare_v2(h, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name", -1, &st, nil) == SQLITE_OK else { return [] }
    var out: [[String?]] = []
    while sqlite3_step(st) == SQLITE_ROW { out.append((0..<4).map { i in sqlite3_column_text(st, Int32(i)).map { String(cString: $0) } }) }
    return out
}

private func norm16(_ rows: [[String?]]) -> [[String?]] {
    rows.map { $0.map { $0.map { s in
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([(),])\s*"#, with: "$1", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    } } }
}

/// A board at version 12 built from the v12 fixture (tables first, then indexes and triggers).
private func makeV12Schema(_ url: URL) -> Bool {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/schema-v12.json")
    guard let data = try? Data(contentsOf: fixture), // try?-ok: nil fails the check
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return false } // try?-ok: nil fails the check
    let order = ["table": 0, "index": 1, "trigger": 2]
    let sql = rows.filter { !($0[1] as? String ?? "").hasPrefix("sqlite_") && $0[3] is String }
        .sorted { (order[$0[0] as? String ?? ""] ?? 3) < (order[$1[0] as? String ?? ""] ?? 3) }.compactMap { $0[3] as? String }.joined(separator: ";\n")
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { return false }
    return sqlite3_exec(h, sql + ";\nPRAGMA user_version = 12;\n", nil, nil, nil) == SQLITE_OK
}

@MainActor private func resolutionSchemaChecks(_ root: URL) {
    check(DB.schemaVersion >= 16, "schema_version_is_at_least_16")
    let old = root.appendingPathComponent("v12.sqlite"), fresh = root.appendingPathComponent("fresh16.sqlite")
    guard makeV12Schema(old) else { check(false, "v12 board setup"); return }
    guard foundationStore(root, "v12.sqlite") != nil, foundationStore(root, "fresh16.sqlite") != nil else { return }
    let upgraded = masterRows16(old)
    check(upgraded.contains { $0[1] == "resolutions" } && upgraded.contains { $0[1] == "resolution_history" }
          && norm16(upgraded) == norm16(masterRows16(fresh)), "v12_board_upgrades_to_the_resolutions_schema")
}

// MARK: Periods

@MainActor private func resolutionPeriodChecks() {
    let q = GoalPeriod.current(.quarter, now: nov17), y = GoalPeriod.current(.year, now: nov17), f = GoalPeriod.current(.fiveYear, now: nov17)
    check(q.key == "2026-Q4" && q.title == "Q4 2026" && q.next.key == "2027-Q1" && q.next.title == "Q1 2027" && q.previous.key == "2026-Q3",
          "quarter_periods")
    check(y.key == "2026" && y.next.key == "2027" && f.key == "2026-2030" && f.title == "2026–2030", "year_and_five_year_periods")
    let q1 = GoalPeriod.parse(level: .quarter, key: "2027-Q1")
    check(y.contains(q) && q1.map { !y.contains($0) } == true && f.contains(y.next) && !q.contains(y)
          && GoalPeriod.parse(level: .quarter, key: "2027-Q5") == nil && GoalPeriod.parse(level: .year, key: "2027-Q1") == nil, "period_containment_and_parse")
    let start = AppTime.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)) ?? Date()
    check(q.interval.start == start && q.interval.end == AppTime.calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)),
          "quarter_interval_in_app_zone")
}

// MARK: Create, limits, ids

@MainActor private func resolutionCreateChecks(_ root: URL) {
    guard let store = goalsStore(root, "create.sqlite") else { return }
    let r = ResolutionStore(store: store)
    let q = GoalPeriod.current(.quarter, now: nov17), y = GoalPeriod.current(.year, now: nov17), f = GoalPeriod.current(.fiveYear, now: nov17)
    let made = (1...3).compactMap { make(r, .quarter, q.key, "Quarter goal \($0)") }
    check(made.count == 3 && refused(r.create(level: .quarter, period: q, title: "Fourth", now: nov17))
          && r.goals(in: q).map(\.title) == ["Quarter goal 1", "Quarter goal 2", "Quarter goal 3"], "at_most_three_quarterly_goals")
    let years = (1...5).compactMap { make(r, .year, y.key, "Year goal \($0)") }
    check(years.count == 5 && refused(r.create(level: .year, period: y, title: "Sixth", now: nov17)), "at_most_five_yearly_goals")
    check(make(r, .fiveYear, f.key, "Line one\nLine two") != nil && refused(r.create(level: .fiveYear, period: f, title: "Another", now: nov17)),
          "one_five_year_picture")
    check(refused(r.create(level: .quarter, period: q.next, title: "   ", now: nov17))
          && refused(r.create(level: .quarter, period: y, title: "Wrong level", now: nov17)), "empty_title_or_wrong_period_refused")
    guard let g = made.first else { return }
    check(g.shortID.text == "R-\(g.id)" && store.item(g.shortID)?.title == "Quarter goal 1" && store.itemExists(g.shortID), "goal_is_an_item")
    // Edit keeps the earlier wording; delete hides it (and frees its place), Undo brings it back.
    check(r.update(g.id, title: "Quarter goal one", notes: "why", now: nov17) == nil && r.goal(g.id)?.title == "Quarter goal one"
          && r.history(g.id).map(\.title) == ["Quarter goal 1"], "edit_keeps_history")
    r.delete(g.id, now: nov17)
    check(store.item(g.shortID)?.deleted == true && !store.itemExists(g.shortID) && r.goals(in: q).count == 2
          && make(r, .quarter, q.key, "Replacement") != nil, "deleted_goal_frees_its_place")
}

// MARK: Parents

@MainActor private func resolutionParentChecks(_ root: URL) {
    guard let store = goalsStore(root, "parents.sqlite") else { return }
    let r = ResolutionStore(store: store)
    guard let five = make(r, .fiveYear, "2026-2030", "Picture"), let y = make(r, .year, "2026", "Year A"), let y2 = make(r, .year, "2026", "Year B"),
          let q = make(r, .quarter, "2026-Q4", "Quarter A"), let q2027 = make(r, .quarter, "2027-Q1", "Next quarter"),
          let q2 = make(r, .quarter, "2026-Q4", "Quarter B") else { return }
    check(r.setParent(q.id, y.id, now: nov17) == nil && r.parent(of: q.id)?.id == y.id && r.children(of: y.id).map(\.id) == [q.id]
          && store.itemLinks(of: q.shortID).contains { $0.other == y.shortID && $0.kind == .serves && $0.isSubject }, "quarter_under_year")
    check(r.setParent(y.id, five.id, now: nov17) == nil && r.parent(of: y.id)?.id == five.id, "year_under_five_year")
    check(r.setParent(q2.id, q.id, now: nov17) != nil && r.setParent(y.id, q.id, now: nov17) != nil
          && r.setParent(q.id, five.id, now: nov17) != nil, "parent_level_rules")
    check(r.setParent(q2027.id, y.id, now: nov17) != nil, "parent_period_must_contain_child")
    check(r.setParent(q.id, y2.id, now: nov17) == nil && r.parent(of: q.id)?.id == y2.id && r.children(of: y.id).isEmpty, "one_parent_per_goal")
    check(r.setParent(q.id, nil, now: nov17) == nil && r.parent(of: q.id) == nil, "parent_removed")
    // A loop made outside the picker (five-year → quarter) is caught when the quarter is put under the year.
    store.link(five.shortID, q2.shortID, kind: .serves, actor: .user, now: nov17)
    check(r.setParent(q2.id, y.id, now: nov17) == "That would make a loop: a goal can't sit under itself." && r.parent(of: q2.id) == nil,
          "parent_links_cannot_loop")
}

// MARK: Work links

@MainActor private func resolutionWorkChecks(_ root: URL) {
    guard let store = goalsStore(root, "work.sqlite") else { return }
    let r = ResolutionStore(store: store)
    guard let five = make(r, .fiveYear, "2026-2030", "Picture"), let y = make(r, .year, "2026", "Ship the assistant"),
          let q = make(r, .quarter, "2026-Q4", "Jots live") else { return }
    let t = task(store, "Write the jots design")
    check(r.linkWork(t, to: q.id, now: nov17) == nil
          && store.itemLinks(of: t).contains { $0.other == q.shortID && $0.kind == .serves && $0.isSubject && $0.madeBy == .manual }
          && r.goals(servedBy: t).map(\.id) == [q.id], "task_serves_goal_by_picker")
    guard let jot = JotStore(store: store).create(text: "Thinking about the capture window", now: nov17) else { check(false, "jot"); return }
    check(r.linkWork(jot.shortID, to: y.id, now: nov17) == nil && r.goals(servedBy: jot.shortID).map(\.id) == [y.id], "jot_serves_goal")
    check(r.linkWork(t, to: five.id, now: nov17) != nil && r.linkWork(ShortID(kind: .person, number: 1), to: q.id, now: nov17) != nil
          && r.linkWork(ShortID(kind: .task, number: 9999), to: q.id, now: nov17) != nil, "only_tasks_jots_decisions_serve_year_or_quarter_goals")
    // Typing R-n in a task's notes or a jot links it as serving that goal; the five-year picture stays a plain link.
    let t2 = task(store, "Draft the capture window")
    if var c = store.card(t2.number) {
        c.notes = "Part of \(q.shortID.text); see also \(five.shortID.text)"
        store.update(c, now: nov17)
    }
    let kinds = Dictionary(uniqueKeysWithValues: store.itemLinks(of: t2).map { ($0.other, $0.kind) })
    check(kinds[q.shortID] == .serves && kinds[five.shortID] == .related, "typed_goal_id_in_task_notes_serves")
    let j2 = JotStore(store: store).create(text: "Idea for \(y.shortID.text)", now: nov17)
    check(j2.map { store.itemLinks(of: $0.shortID).first { $0.other == y.shortID }?.kind == .serves } == true, "typed_goal_id_in_jot_serves")
    // Decisions link by id, so they work once the Decisions area registers its items (a link row is all it takes).
    let d = ShortID(kind: .decision, number: 7)
    store.link(d, q.shortID, kind: .serves, actor: .user, now: nov17)
    check(r.progress(q.id).decisions == [d], "decision_serves_goal_by_id")
    // A reviewed goal takes no new work.
    _ = r.review(q.id, outcome: .dropped, note: "", newTitle: nil, now: nov17)
    check(r.linkWork(task(store, "Late task"), to: q.id, now: nov17) != nil, "reviewed_goal_takes_no_new_work")
}

// MARK: Progress

@MainActor private func resolutionProgressChecks(_ root: URL) {
    guard let store = goalsStore(root, "progress.sqlite") else { return }
    let r = ResolutionStore(store: store)
    guard let y = make(r, .year, "2026", "Year"), let q = make(r, .quarter, "2026-Q4", "Quarter", parent: nil) else { return }
    _ = r.setParent(q.id, y.id, now: nov17)
    let t1 = task(store, "Done one", done: true), t2 = task(store, "Open two"), t3 = task(store, "Year only"), gone = task(store, "Deleted")
    for t in [t1, t2, gone] { _ = r.linkWork(t, to: q.id, now: nov17) }
    _ = r.linkWork(t3, to: y.id, now: nov17)
    _ = r.linkWork(t2, to: y.id, now: nov17)     // also directly under the year: still counted once
    if let c = store.card(gone.number) { store.delete(c) }
    let pq = r.progress(q.id), py = r.progress(y.id)
    check(pq.done == [t1.number] && pq.open == [t2.number], "quarter_progress_counts_its_tasks")
    check(py.done == [t1.number] && Set(py.open) == [t2.number, t3.number] && py.open.count == 2, "year_progress_counts_its_and_its_quarters_tasks_once")
    check(r.taskIDs(for: y.id) == [t1.number, t2.number, t3.number] && r.taskIDs(for: q.id) == [t1.number, t2.number], "board_filter_task_sets")
    check(pq.summary == "1 done · 1 open" && GoalProgress(done: [], open: [], jots: [], decisions: []).summary == "Nothing linked yet",
          "progress_without_scoring")
}

// MARK: Review and rollover

@MainActor private func resolutionReviewChecks(_ root: URL) {
    guard let store = goalsStore(root, "review.sqlite") else { return }
    let r = ResolutionStore(store: store)
    guard let y = make(r, .year, "2026", "Year 2026"), let q = make(r, .quarter, "2026-Q4", "Keep me"),
          let q2 = make(r, .quarter, "2026-Q4", "Change me"), let q3 = make(r, .quarter, "2026-Q4", "Drop me") else { return }
    _ = r.setParent(q.id, y.id, now: nov17)
    store.setTags(q.shortID, primary: store.areas.first?.name, others: [])
    let done = task(store, "Finished", done: true), open = task(store, "Still open")
    _ = r.linkWork(done, to: q.id, now: nov17); _ = r.linkWork(open, to: q.id, now: nov17)
    let at = day(2026, 12, 29)
    // Kept: the reviewed goal stays as it was; a new goal carries on next quarter with its open work.
    guard case .success(let next?) = r.review(q.id, outcome: .kept, note: "Went well, more to do.", newTitle: nil, now: at) else {
        check(false, "review kept"); return
    }
    let old = r.goal(q.id)
    check(old?.status == .kept && old?.reviewed == at && old?.title == "Keep me" && next.title == "Keep me" && next.period.key == "2027-Q1"
          && next.carriedFrom == q.id && next.status == .active && r.continuation(of: q.id)?.id == next.id, "kept_goal_rolls_over")
    check(store.itemTags(next.shortID) == store.itemTags(q.shortID) && r.parent(of: next.id) == nil, "rollover_copies_tags_parent_only_if_it_covers")
    check(r.progress(next.id).open == [open.number] && r.progress(next.id).done.isEmpty
          && r.progress(q.id).done == [done.number] && r.progress(q.id).open == [open.number], "open_work_follows_reviewed_version_keeps_its_record")
    check(r.update(q.id, title: "Rewritten", notes: "", now: at) != nil && r.goal(q.id)?.title == "Keep me", "reviewed_goal_is_read_only")
    let reviews = store.itemLinks(of: q.shortID).filter { $0.kind == .reviewOf }
    let jot = reviews.first.flatMap { JotStore(store: store).jot($0.other.number) }
    check(reviews.count == 1 && reviews.first?.madeBy == .auto && reviews.first?.isSubject == false
          && jot?.text.contains("Went well, more to do.") == true && jot?.text.contains("Q4 2026") == true && jot?.kind == .jot,
          "review_note_saved_as_jot_with_review_of_link")
    // Changed: new wording next quarter. Dropped: nothing carries on. No note: no jot.
    let jotsBefore = JotStore(store: store).jots(addedFrom: .distantPast, to: .distantFuture).count
    guard case .success(let changed?) = r.review(q2.id, outcome: .changed, note: "", newTitle: "Changed wording", now: at) else {
        check(false, "review changed"); return
    }
    check(changed.title == "Changed wording" && r.goal(q2.id)?.title == "Change me" && r.goal(q2.id)?.status == .changed, "changed_goal_rolls_over_with_new_wording")
    guard case .success(let none) = r.review(q3.id, outcome: .dropped, note: "", newTitle: nil, now: at) else { check(false, "review dropped"); return }
    check(none == nil && r.goal(q3.id)?.status == .dropped && r.goals(in: GoalPeriod.current(.quarter, now: at).next).count == 2
          && JotStore(store: store).jots(addedFrom: .distantPast, to: .distantFuture).count == jotsBefore, "dropped_goal_ends_no_note_no_jot")
    check(refused(r.review(q.id, outcome: .kept, note: "", newTitle: nil, now: at)), "goal_reviewed_once")
    check(refused(r.review(y.id, outcome: .changed, note: "", newTitle: "  ", now: at)) && r.goal(y.id)?.status == .active,
          "changed_needs_new_wording")
    // A full next period refuses the rollover and changes nothing.
    guard let fullStore = goalsStore(root, "full.sqlite") else { return }
    let rf = ResolutionStore(store: fullStore)
    guard let a = make(rf, .quarter, "2026-Q4", "Ending") else { return }
    for i in 1...3 { _ = make(rf, .quarter, "2027-Q1", "Next \(i)") }
    check(refused(rf.review(a.id, outcome: .kept, note: "note", newTitle: nil, now: at)) && rf.goal(a.id)?.status == .active
          && JotStore(store: fullStore).jots(addedFrom: .distantPast, to: .distantFuture).isEmpty, "rollover_refused_when_next_period_is_full")
    // Year end: the yearly goal rolls over, and its quarter's continuation sits under the year's continuation.
    guard let yearStore = goalsStore(root, "year.sqlite") else { return }
    let ry = ResolutionStore(store: yearStore)
    guard let yy = make(ry, .year, "2026", "Year goal"), let qq = make(ry, .quarter, "2026-Q4", "Quarter goal") else { return }
    _ = ry.setParent(qq.id, yy.id, now: nov17)
    guard case .success(let ny?) = ry.review(yy.id, outcome: .kept, note: "", newTitle: nil, now: at),
          case .success(let nq?) = ry.review(qq.id, outcome: .kept, note: "", newTitle: nil, now: at) else { check(false, "year review"); return }
    check(ny.period.key == "2027" && ry.goal(yy.id)?.status == .kept && ry.parent(of: nq.id)?.id == ny.id
          && ry.parent(of: qq.id)?.id == yy.id, "yearly_goal_rolls_over_and_parent_follows")
}

// MARK: Nudges

@MainActor private func resolutionNudgeChecks(_ root: URL) {
    guard let store = goalsStore(root, "nudges.sqlite") else { return }
    let r = ResolutionStore(store: store)
    check(ResolutionNudges.due(store: store, now: day(2026, 12, 27)).isEmpty, "no_nudge_without_goals")
    guard let q = make(r, .quarter, "2026-Q4", "Quarter"), make(r, .year, "2026", "Year") != nil else { return }
    check(ResolutionNudges.due(store: store, now: nov17).isEmpty, "no_nudge_mid_quarter")
    let dueQ = ResolutionNudges.due(store: store, now: day(2026, 12, 20))
    check(dueQ.map(\.level) == [.quarter, .year] && dueQ.first?.period.key == "2026-Q4" && dueQ.last?.period.key == "2026", "nudge_in_last_two_weeks_of_period")
    check(ResolutionNudges.due(store: store, now: day(2026, 12, 27, 23)).isEmpty, "nudge_waits_for_quiet_hours_to_end")
    check(ResolutionNudges.due(store: store, now: day(2027, 1, 15)).count == 2, "nudge_open_early_next_period")
    ResolutionNudges.markNudged(dueQ, store: store)
    check(ResolutionNudges.due(store: store, now: day(2026, 12, 28)).isEmpty && ResolutionNudges.due(store: store, now: day(2027, 1, 3)).isEmpty,
          "nudge_at_most_once_per_period")
    check(ResolutionNudges.text(dueQ) == "Time to review Q4 2026 and 2026.", "one_notification_for_both")
    // The review clears the nudge: nothing active left in the period.
    guard let store2 = goalsStore(root, "nudges2.sqlite") else { return }
    let r2 = ResolutionStore(store: store2)
    guard let q2 = make(r2, .quarter, "2026-Q4", "Only") else { return }
    _ = r2.review(q2.id, outcome: .dropped, note: "", newTitle: nil, now: day(2026, 12, 20))
    check(ResolutionNudges.due(store: store2, now: day(2026, 12, 21)).isEmpty, "reviewed_period_needs_no_nudge")
    check(ResolutionNudges.openReview(store: store2, now: day(2026, 12, 21)) == nil
          && ResolutionNudges.openReview(store: store, now: day(2026, 12, 21))?.key == "2026-Q4", "open_review_banner")
    store.setModule(.resolutions, on: false)
    check(ResolutionNudges.due(store: store, now: day(2027, 3, 28)).isEmpty, "no_nudge_while_area_off")
    _ = q
}

// MARK: Search and phone

@MainActor private func resolutionSearchPhoneChecks(_ root: URL) {
    guard let store = goalsStore(root, "search.sqlite") else { return }
    let r = ResolutionStore(store: store)
    let now = Date()
    let qp = GoalPeriod.current(.quarter, now: now), yp = GoalPeriod.current(.year, now: now)
    guard let y = r.create(level: .year, period: yp, title: "Launch the studio", now: now).ok,
          let q = r.create(level: .quarter, period: qp, title: "Find a studio space", notes: "near the river", now: now).ok else {
        check(false, "search setup"); return
    }
    _ = r.setParent(q.id, y.id, now: now)
    let hits = GlobalSearch.run("studio river", store: store)
    check(hits.first { $0.0 == .resolution }?.1.map(\.id) == [q.shortID], "search_finds_goals_by_title_and_notes")
    check(GlobalSearch.run(y.shortID.text, store: store).first?.1.first?.title == "Launch the studio", "search_typed_goal_id")
    let t1 = task(store, "Visit three spaces", done: true), t2 = task(store, "Ask about the lease")
    _ = r.linkWork(t1, to: q.id, now: now); _ = r.linkWork(t2, to: q.id, now: now)
    let goals = PhoneBoard.extras(store: store, now: now).goals ?? []
    check(goals.count == 1 && goals.first?.id == q.shortID.text && goals.first?.period == qp.title && goals.first?.done == 1
          && goals.first?.open == 1 && goals.first?.tasks == [t2.number] && goals.first?.parent == "\(y.shortID.text) · Launch the studio",
          "phone_copy_carries_this_quarters_goals")
    let body = (try? PhoneBoard.body([], extras: PhoneBoard.extras(store: store, now: now))).map { String(decoding: $0, as: UTF8.self) } ?? "" // try?-ok: empty fails the check
    check(body.contains("\"goals\":[{") && body.contains("\"title\":\"Find a studio space\""), "phone_body_has_goals")
    store.setModule(.resolutions, on: false)
    check(PhoneBoard.extras(store: store, now: now).goals == nil && GlobalSearch.run("studio", store: store).allSatisfy { $0.0 != .resolution },
          "goals_hidden_while_area_off")
}
