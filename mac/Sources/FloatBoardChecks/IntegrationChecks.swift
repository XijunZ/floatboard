import Foundation
import FloatBoardCore

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
