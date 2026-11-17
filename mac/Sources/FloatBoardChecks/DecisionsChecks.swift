import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Decisions (docs/superpowers/specs/2026-11-17-decisions-design.md): schema 15, recording, two dates, people by code,
/// statuses, "Not a decision" and the rulebook, the weekly screening, reviews in the budget, the weekly review sections, the
/// phone's copy and actions.
@MainActor func decisionsChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-decisions-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    DecisionsArea.registerCore()
    decisionSchemaChecks(root)
    decisionRecordChecks(root)
    decisionPeopleChecks(root)
    decisionScreeningChecks(root)
    decisionReviewChecks(root)
    decisionRulebookChecks(root)
    decisionPhoneChecks(root)
    await decisionEngineChecks(root)
}

@MainActor func decisionsStore(_ root: URL, _ name: String) -> Store? {
    do {
        let s = Store(db: try DB(url: root.appendingPathComponent(name)))
        s.setModule(.jots, on: true); s.setModule(.decisions, on: true)
        return s
    } catch { check(false, "decisions setup \(name): \(error)"); return nil }
}

@MainActor private func rows(_ store: Store, _ sql: String, _ args: [Any?] = []) -> Int64 {
    ((try? store.db.query(sql, args) { DB.int($0, 0) }) ?? []).first ?? -1 // try?-ok: -1 fails the check
}

/// A fixed moment: Wednesday 11 Nov 2026, 10:00 in London.
let decisionsNow = Date(timeIntervalSince1970: 1_794_391_200)

// MARK: Schema

@MainActor private func decisionSchemaChecks(_ root: URL) {
    check(DB.schemaVersion == 15, "decisions_schema_version_is_15")
    guard let s = decisionsStore(root, "schema.sqlite") else { return }
    let cols = (try? s.db.query("PRAGMA table_info(decisions)") { DB.text($0, 1) }) ?? [] // try?-ok: empty fails the check
    check(["text", "quote", "source_item", "recorded", "decided", "expected_added", "confidence_added", "found_by", "review_due",
           "review_ask_after", "not_decision"].allSatisfy(cols.contains), "decisions_table_has_both_dates_and_review_columns")
    check(rows(s, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('decision_screened','decision_suggestions','decision_examples')") == 3,
          "decisions_side_tables_exist")
}

// MARK: Recording (D2, D3, D5, §9 two dates, predictions)

@MainActor private func decisionRecordChecks(_ root: URL) {
    guard let s = decisionsStore(root, "record.sqlite") else { return }
    let js = JotStore(store: s), ds = DecisionStore(store: s)
    let written = decisionsNow.addingTimeInterval(-3 * 86400)
    guard let anna = PeopleStore(store: s).create(name: "Anna Lopez", aliases: ["Annie"]),
          let jot = js.create(text: "Board call. We decided to move the offsite to March because the venue was double booked. Annie agreed.",
                              kind: .meetingNotes, source: .meeting, now: written) else { check(false, "record setup"); return }
    s.setTags(jot.shortID, primary: "Work", others: [])
    let quote = "We decided to move the offsite to March because the venue was double booked. Annie agreed."
    guard let d = ds.record(DecisionDraft(text: "Move the offsite to March", quote: quote, why: "", type: .strategic, foundByClaude: true,
                                          source: .claude, sourceItem: jot.shortID, decided: "2026-11-20"), now: decisionsNow) else {
        check(false, "record decision"); return
    }
    check(d.recorded == written && d.decided == "" && d.added == decisionsNow, "recorded_is_the_sources_date_and_decided_unknown_unless_said")
    check(d.expected.isEmpty && d.confidence == nil && d.needsPrediction && d.why.isEmpty, "screened_decision_has_no_invented_prediction")
    check(d.sourceLabel == "meeting notes \(jot.shortID.text)" && d.foundByClaude, "card_labels_meeting_notes_source")
    let links = s.itemLinks(of: d.shortID)
    check(links.contains { $0.other == jot.shortID && $0.kind == .source && $0.isSubject && $0.madeBy == .auto }, "decision_linked_to_its_jot_auto")
    check(links.contains { $0.other == anna.shortID && $0.kind == .related && $0.madeBy == .auto }, "decision_naming_a_person_links_them")
    check(s.itemTags(d.shortID).primary == "Work", "decision_takes_the_sources_tags")
    check(d.reviewDue == DecisionStore.reviewDate(recorded: written, type: .strategic)
          && abs((d.reviewDue ?? .distantPast).timeIntervalSince(written) - 90 * 86400) < 7200, "strategic_review_90_days_from_recorded")
    // A said date is kept (not after the source was written).
    let said = ds.record(DecisionDraft(text: "Hire a designer", quote: "", sourceItem: jot.shortID, decided: "2026-11-01"), now: decisionsNow)
    check(said?.decided == "2026-11-01" && ds.record(DecisionDraft(text: "x", decided: "2026-02-31"), now: decisionsNow)?.decided == "", "decided_kept_only_when_real")
    // The quote stays when the jot is edited or deleted; the card says so.
    js.update(jot.id, text: "Board call notes rewritten.", now: decisionsNow)
    check(ds.decision(d.id)?.quote == quote && ds.sourceNote(ds.decision(d.id)!) == "source edited", "quote_kept_when_source_edited")
    js.delete(jot.id, now: decisionsNow)
    check(ds.decision(d.id)?.quote == quote && ds.sourceNote(ds.decision(d.id)!) == "source deleted", "quote_kept_when_source_deleted")
    js.undoDelete(jot.id, now: decisionsNow)
    // Predictions added later are marked so.
    var e = ds.decision(d.id)!
    e.expected = "Better attendance"; e.confidence = .medium
    check(ds.update(e, now: decisionsNow.addingTimeInterval(60)), "decision_update_saved")
    let after = ds.decision(d.id)!
    check(after.expectedAdded != nil && after.confidenceAdded != nil && !after.needsPrediction, "prediction_added_later_is_marked")
    // A decision made by hand (selection in a task: the task is the source) has its predictions as given.
    s.add(title: "Plan the offsite", area: "Work", importance: .medium, due: nil)
    let task = ShortID(kind: .task, number: s.cards.last!.id)
    let manual = ds.record(DecisionDraft(text: "Use the small venue", why: "cheaper", expected: "Saves money", confidence: .high, sourceItem: task), now: decisionsNow)
    check(manual?.expectedAdded == nil && manual?.confidence == .high && !manual!.foundByClaude
          && s.itemLinks(of: manual!.shortID).contains { $0.other == task && $0.kind == .source && $0.madeBy == .manual }, "manual_decision_from_task_selection")
    check(ds.record(DecisionDraft(text: "No source", why: "not recorded"))?.why == "", "why_not_recorded_stored_empty")
    // Statuses, supersedes.
    ds.acceptSupersedes(manual!.id, replaces: d.id, now: decisionsNow)
    check(ds.decision(d.id)?.status == .superseded
          && s.itemLinks(of: manual!.shortID).contains { $0.other == d.shortID && $0.kind == .supersedes && $0.isSubject }, "accepting_supersedes_links_and_marks_old")
    // Filters (D8) and search.
    check(ds.list(DecisionFilter(type: .strategic)).map(\.id) == [d.id] && ds.list(DecisionFilter(person: anna.shortID)).map(\.id) == [d.id]
          && ds.list(DecisionFilter(query: "venue")).map(\.id).contains(manual!.id) && ds.list(DecisionFilter(tags: ["Work"])).contains { $0.id == d.id } && ds.list(DecisionFilter(tags: ["Work"])).allSatisfy { $0.text != "No source" }
          && ds.list(DecisionFilter(status: .superseded)).map(\.id) == [d.id], "decision_filters_tag_type_status_person")
    check(GlobalSearch.run("offsite March", store: s).contains { $0.0 == .decision && $0.1.contains { $0.id == d.shortID } }
          && s.item(d.shortID)?.title == "Move the offsite to March", "decisions_in_global_search_and_catalog")
    // Not a decision: dismissed, links hidden, example queued; Undo takes it back.
    ds.notADecision(manual!.id, now: decisionsNow)
    check(ds.decision(manual!.id)?.deleted == true && !ds.list(DecisionFilter()).contains { $0.id == manual!.id }
          && s.links(of: manual!.shortID).isEmpty && DecisionRulebook.pending(store: s).count == 1, "not_a_decision_dismisses_and_queues_example")
    ds.undoNotADecision(manual!.id, now: decisionsNow)
    check(ds.decision(manual!.id)?.deleted == false && DecisionRulebook.pending(store: s).isEmpty && !s.links(of: manual!.shortID).isEmpty,
          "not_a_decision_undo")
    // Tell / ask suggestions become tasks only on ✓.
    ds.suggest(d.id, kind: .tell, target: anna.shortID, text: "Tell Anna the offsite moved to March")
    ds.suggest(d.id, kind: .tell, target: anna.shortID, text: "again")
    let sug = ds.suggestions(d.id)
    check(sug.count == 1, "suggestion_made_once")
    let before = s.cards.count
    let tid = sug.first.flatMap { ds.acceptTask($0, now: decisionsNow) }
    check(tid != nil && s.cards.count == before + 1 && ds.suggestions(d.id).isEmpty
          && s.links(of: ShortID(kind: .task, number: tid!)).contains(anna.shortID), "tell_suggestion_accepted_makes_linked_task")
}

// MARK: People by code (D7)

@MainActor private func decisionPeopleChecks(_ root: URL) {
    guard let s = decisionsStore(root, "people.sqlite") else { return }
    let ps = PeopleStore(store: s)
    let people = [("Anna", [String]()), ("José Ruiz", ["Pepe"]), ("李明", []), ("Al", ["A"])].compactMap { ps.create(name: $0.0, aliases: $0.1) }
    let ids = people.map(\.id)
    check(DecisionPeople.named(in: "Told anna and jose ruiz.", people: people).map(\.id) == [ids[0], ids[1]], "people_matched_case_and_accent_insensitive")
    check(DecisionPeople.named(in: "Annabel and Pepper", people: people).isEmpty, "people_matched_as_whole_words_only")
    check(DecisionPeople.named(in: "和李明确认了", people: people).map(\.id) == [ids[2]], "chinese_names_matched_inside_text")
    check(DecisionPeople.named(in: "Al said A", people: people).map(\.id) == [ids[3]], "short_alias_ignored_name_matched")
}

// MARK: Screening (D1 ⚑)

@MainActor private func decisionScreeningChecks(_ root: URL) {
    // Due once a week from Sunday 17:00.
    let sunday1659 = decisionsNow.addingTimeInterval(4 * 86400 + 6 * 3600 + 59 * 60)   // Sun 15 Nov 16:59
    let sunday1700 = sunday1659.addingTimeInterval(60)
    check(!DecisionScreening.isDue(now: sunday1659, lastRun: decisionsNow) && DecisionScreening.isDue(now: sunday1700, lastRun: decisionsNow)
          && !DecisionScreening.isDue(now: sunday1700.addingTimeInterval(3600), lastRun: sunday1700)
          && DecisionScreening.isDue(now: sunday1700.addingTimeInterval(86400 * 2), lastRun: sunday1659), "screening_due_weekly_from_sunday_17")
    guard let s = decisionsStore(root, "screen.sqlite") else { return }
    let js = JotStore(store: s), ds = DecisionStore(store: s)
    let old = js.create(text: "Old idea from last month: we decided to sell the car.", now: decisionsNow.addingTimeInterval(-30 * 86400))
    guard let a = js.create(text: "Decided: we will stop the weekly newsletter. Maybe hire someone?", now: decisionsNow.addingTimeInterval(-86400)),
          let b = js.create(text: "Shopping list: milk, eggs.", now: decisionsNow.addingTimeInterval(-3600)) else { check(false, "screen setup"); return }
    let pending = DecisionScreening.pending(store: s, now: decisionsNow)
    check(pending.map(\.ref) == ["J-\(a.id)@\(DecisionScreening.version(a.text))", "J-\(b.id)@\(DecisionScreening.version(b.text))"]
          && old.map { o in !pending.contains { $0.ref.hasPrefix("J-\(o.id)@") } } == true, "first_screening_reads_the_last_7_days_only")
    let big = (0..<25).map { i in ScreenJot(ref: "J-\(i)@x", kind: "jot", added: "", text: String(repeating: "a", count: 5000), references: []) }
    check(DecisionScreening.batches(big).map(\.count) == [8, 8, 8, 1] && DecisionScreening.batches(Array(big.prefix(3))).count == 1,
          "screening_batches_capped_by_count_and_size")
    guard pending.count == 2 else { check(false, "screening pending setup"); return }
    let results = [
        ScreenResult(ref: pending[0].ref, ok: true, decisions: [
            ScreenFound(quote: "we will stop the weekly newsletter", decision: "Stop the weekly newsletter", type: "operational", why: nil,
                        decidedOn: nil, sure: true),
            ScreenFound(quote: "Maybe hire someone?", decision: "Hire someone", type: "strategic", sure: false),
            ScreenFound(quote: "words that are not in the jot", decision: "Invented", type: "operational", sure: true)]),
        ScreenResult(ref: pending[1].ref, ok: false, decisions: []),
    ]
    let out = DecisionScreening.apply(results, sent: pending, store: s, now: decisionsNow)
    check(out.recorded.count == 1 && out.maybe.count == 2 && out.unreadable == 1 && out.screened == 1, "screening_records_sure_and_maybes_unsure")
    guard out.recorded.count == 1 else { return }
    let rec = ds.decision(out.recorded[0])
    check(rec?.foundByClaude == true && rec?.source == .claude && rec?.status == .decided && rec?.expected == "" && rec?.confidence == nil,
          "screened_decision_found_by_claude_without_predictions")
    check(out.maybe.compactMap { ds.decision($0)?.status } == [.maybe, .maybe], "unverified_quote_goes_to_maybe")
    DecisionScreening.finishRun(store: s, started: decisionsNow, readFrom: DecisionScreening.readFrom(store: s, now: decisionsNow), complete: out.unreadable == 0, now: decisionsNow)
    let again = DecisionScreening.pending(store: s, now: decisionsNow.addingTimeInterval(60))
    check(again.map(\.ref) == [pending[1].ref], "each_jot_version_screened_once_unreadable_retried")
    // An edit is a new version; decisions already recorded from the jot are not recorded again.
    js.update(a.id, text: a.text + " Also: we decided to move to a monthly digest.", now: decisionsNow.addingTimeInterval(120))
    let v2 = DecisionScreening.pending(store: s, now: decisionsNow.addingTimeInterval(180)).first { $0.ref.hasPrefix("J-\(a.id)@") }
    check(v2 != nil, "edited_jot_screened_again_as_new_version")
    if let v2 {
        let o2 = DecisionScreening.apply([ScreenResult(ref: v2.ref, ok: true, decisions: [
            ScreenFound(quote: "we will stop the weekly newsletter", decision: "Stop the weekly newsletter", type: "operational"),
            ScreenFound(quote: "we decided to move to a monthly digest", decision: "Move to a monthly digest", type: "operational")])],
                                         sent: [v2], store: s, now: decisionsNow)
        check(o2.recorded.count == 1 && o2.references == 1, "repeat_screening_records_nothing_twice")
    }
    // A review quoting an older decision is a reference, not a new decision.
    guard let first = rec, let review = DecisionReviews.answer(first.id, happened: "We stopped the weekly newsletter as planned", sound: "yes",
                                                              store: s, now: decisionsNow.addingTimeInterval(200)) else { check(false, "review setup"); return }
    let r = DecisionScreening.pending(store: s, now: decisionsNow.addingTimeInterval(300)).first { $0.ref.hasPrefix("J-\(review.id)@") }
    check(r?.references.map(\.id) == [first.shortID.text], "review_jot_sent_with_its_decision_as_reference")
    if let r {
        let o3 = DecisionScreening.apply([ScreenResult(ref: r.ref, ok: true, decisions: [
            ScreenFound(quote: "Stop the weekly newsletter", decision: "Stop the weekly newsletter", type: "operational")])], sent: [r], store: s, now: decisionsNow)
        check(o3.recorded.isEmpty && o3.references == 1, "quoted_older_decision_is_a_reference")
    }
}

// MARK: Reviews (D6) and the weekly review (D4)

@MainActor private func decisionReviewChecks(_ root: URL) {
    guard let s = decisionsStore(root, "reviews.sqlite") else { return }
    let js = JotStore(store: s), ds = DecisionStore(store: s)
    let longAgo = decisionsNow.addingTimeInterval(-40 * 86400)
    guard let j = js.create(text: "We chose the cheaper supplier. Tell Anna.", now: longAgo),
          let anna = PeopleStore(store: s).create(name: "Anna"),
          let d = ds.record(DecisionDraft(text: "Use the cheaper supplier", quote: "We chose the cheaper supplier. Tell Anna.", expected: "Lower costs",
                                          type: .operational, sourceItem: j.shortID), now: decisionsNow),
          let later = ds.record(DecisionDraft(text: "Invest in the fund", type: .investment, sourceItem: j.shortID), now: decisionsNow) else {
        check(false, "reviews setup"); return
    }
    _ = anna
    check(DecisionReviews.due(store: s, by: decisionsNow).map(\.id) == [d.id] && !DecisionReviews.due(store: s, by: decisionsNow).contains { $0.id == later.id },
          "review_due_counts_from_recorded_date_by_type")
    ReminderBudget(store: s).save(ReminderSettings(dailyLimit: 3, quietStart: 22 * 60, quietEnd: 8 * 60))
    let g = DecisionReviews.askBudget(store: s, now: decisionsNow)
    check(g.count == 1 && { if case .granted = g[0] { return true }; return false }()
          && ReminderBudget(store: s).pending().contains { $0.kind == ReminderKind.decisionReview.rawValue && $0.item == d.shortID.text },
          "due_review_asks_the_shared_budget")
    check(DecisionReviews.askBudget(store: s, now: decisionsNow.addingTimeInterval(900)).isEmpty
          && DecisionReviews.askBudget(store: s, now: decisionsNow.addingTimeInterval(3 * 86400)).isEmpty, "review_reminded_once")
    // Over the limit: deferred, asked again then.
    let full = decisionsStore(root, "reviews-full.sqlite")!
    ReminderBudget(store: full).save(ReminderSettings(dailyLimit: 0, quietStart: 22 * 60, quietEnd: 8 * 60))
    if let j2 = JotStore(store: full).create(text: "x", now: longAgo), let d2 = DecisionStore(store: full).record(DecisionDraft(text: "y", sourceItem: j2.shortID), now: decisionsNow) {
        let g2 = DecisionReviews.askBudget(store: full, now: decisionsNow)
        check({ if case .deferred = g2.first { return true }; return false }() && DecisionStore(store: full).decision(d2.id)?.reviewAskAfter != nil,
              "review_over_budget_deferred")
    }
    // Weekly review sections.
    let week = WeeklyReview.week(containing: decisionsNow)
    let sections = WeeklyReview.sections(store: s, now: decisionsNow)
    let ids = sections.map(\.0.id)
    check(ids.contains(DecisionReviews.recordedSection) && ids.contains(DecisionReviews.reviewsSection) && !ids.contains(DecisionReviews.maybeSection),
          "weekly_review_lists_recorded_and_due_reviews")
    check(DecisionReviews.recordedThisWeek(store: s, week: week).count == 2, "recorded_this_week_counts_added_this_week")
    s.setModule(.decisions, on: false)
    check(!WeeklyReview.sections(store: s, now: decisionsNow).contains { $0.0.module == .decisions } && DecisionReviews.askBudget(store: s, now: decisionsNow).isEmpty,
          "decisions_off_hides_sections_and_stops_reviews")
    s.setModule(.decisions, on: true)
    // Snooze, turn off, answer.
    DecisionReviews.snooze(d.id, store: s, now: decisionsNow)
    check(DecisionReviews.due(store: s, by: decisionsNow).isEmpty && DecisionReviews.due(store: s, by: decisionsNow.addingTimeInterval(8 * 86400)).map(\.id) == [d.id],
          "snooze_moves_review_a_week")
    DecisionReviews.setOn(d.id, false, store: s, now: decisionsNow)
    check(DecisionReviews.due(store: s, by: decisionsNow.addingTimeInterval(30 * 86400)).isEmpty, "review_turned_off_per_decision")
    DecisionReviews.setOn(d.id, true, store: s, now: decisionsNow)
    let jot = DecisionReviews.answer(d.id, happened: "Costs fell", sound: "Mostly", store: s, now: decisionsNow)
    check(jot != nil && jot!.text.contains("What happened? Costs fell") && ds.decision(d.id)?.reviewState == .done
          && s.itemLinks(of: jot!.shortID).contains { $0.other == d.shortID && $0.kind == .reviewOf && $0.isSubject && $0.madeBy == .auto }
          && ds.reviews(of: d.id).map(\.id) == [jot!.id], "review_answer_saved_as_jot_linked_review_of")
    check(DecisionReviews.answer(d.id, happened: "again", sound: "", store: s, now: decisionsNow) == nil, "review_answered_once")
    check(DecisionReviews.checkInTitles(d.id, store: s).map(\.1) == ["Check in with Anna about how it went"], "review_suggests_check_in_by_code")
}

// MARK: "Not a decision" → rulebook

@MainActor private func decisionRulebookChecks(_ root: URL) {
    let builtIn = "# Decisions rulebook\nA decision is a commitment."
    let one = "- Not a decision: \"Maybe hire someone?\" (was marked strategic)"
    let started = DecisionRulebook.withExamples(current: "", builtIn: builtIn, examples: [one])
    check(started?.hasPrefix(builtIn) == true && started?.contains(DecisionRulebook.heading) == true && started?.hasSuffix(one) == true,
          "example_starts_copy_from_builtin")
    check(DecisionRulebook.withExamples(current: started!, builtIn: builtIn, examples: [one]) == started, "example_added_once")
    check(DecisionRulebook.withExamples(current: "", builtIn: nil, examples: [one]) == nil, "example_waits_without_builtin")
    guard let s = decisionsStore(root, "rulebook.sqlite") else { return }
    do { try s.upsertConnector(id: "eng", name: "Engine", baseURL: "https://engine.invalid") } catch { check(false, "rulebook connector: \(error)"); return }
    s.reload()
    guard let d = DecisionStore(store: s).record(DecisionDraft(text: "Maybe hire someone", quote: "Maybe hire someone?", type: .strategic)) else { return }
    DecisionStore(store: s).notADecision(d.id)
    check(DecisionRulebook.applyPending(store: s, connector: "eng") == 0, "example_kept_until_builtin_known")
    check(DecisionRulebook.applyPending(store: s, connector: "eng", builtIn: builtIn) == 1 && DecisionRulebook.pending(store: s).isEmpty
          && (s.connectors.first { $0.id == "eng" }?.settings[DecisionRulebook.settingsKey] as? String)?.contains("Maybe hire someone?") == true,
          "example_written_into_rulebook_copy")
    check(rows(s, "SELECT count(*) FROM instructions WHERE part='rulebook_decisions'") >= 1, "rulebook_change_is_a_restorable_version")
}

// MARK: Phone copy and actions (§10)

@MainActor private func decisionPhoneChecks(_ root: URL) {
    guard let s = decisionsStore(root, "phone.sqlite") else { return }
    let ds = DecisionStore(store: s)
    guard let j = JotStore(store: s).create(text: "We picked the red logo.", now: decisionsNow.addingTimeInterval(-35 * 86400)),
          let d = ds.record(DecisionDraft(text: "Pick the red logo", quote: "We picked the red logo.", foundByClaude: true, source: .claude, sourceItem: j.shortID), now: decisionsNow),
          let m = ds.record(DecisionDraft(text: "Perhaps rebrand", status: .maybe, foundByClaude: true, source: .claude), now: decisionsNow) else { check(false, "phone setup"); return }
    let copy = DecisionPhone.copy(store: s, now: decisionsNow)
    check(copy.count == 2 && copy.first { $0.id == d.shortID.text }?.review == "due" && copy.first { $0.id == m.shortID.text }?.status == "maybe"
          && copy.allSatisfy(\.thisWeek), "phone_copy_has_due_reviews_and_maybe")
    let data = try? JSONEncoder().encode(copy) // try?-ok: nil fails the check
    check(data.map { String(decoding: $0, as: UTF8.self).contains("\"review_due\"") } == true, "phone_copy_uses_snake_case")
    let res = DecisionPhone.apply([PhoneDecisionAction(id: "a1", decision: d.shortID.text, action: "review", happened: "Customers liked it", sound: "Yes"),
                                   PhoneDecisionAction(id: "a2", decision: d.shortID.text, action: "review", happened: "dup", sound: ""),
                                   PhoneDecisionAction(id: "a3", decision: m.shortID.text, action: "not_decision"),
                                   PhoneDecisionAction(id: "a4", decision: "D-999", action: "review")], store: s, now: decisionsNow)
    let reviewJot = ds.reviews(of: d.id).first
    check(res.applied == ["a1", "a2", "a3"] && res.skipped.map(\.0) == ["a4"] && reviewJot?.source == .phone && ds.reviews(of: d.id).count == 1,
          "phone_review_saved_once_as_phone_jot")
    check(ds.decision(m.id)?.notDecision == true && DecisionRulebook.pending(store: s).count == 1, "phone_not_a_decision_teaches_rulebook")
    s.setModule(.decisions, on: false)
    check(DecisionPhone.copy(store: s, now: decisionsNow).isEmpty, "phone_copy_empty_while_off")
}

// MARK: Engine calls (stubbed; no live AI)

@MainActor private func decisionEngineChecks(_ root: URL) async {
    guard let s = decisionsStore(root, "engine.sqlite") else { return }
    do { try s.upsertConnector(id: "eng", name: "Engine", baseURL: "https://engine.test") } catch { check(false, "engine connector: \(error)"); return }
    s.reload()
    let js = JotStore(store: s)
    guard let a = js.create(text: "We agreed to hire Sam as designer from January.", now: decisionsNow.addingTimeInterval(-2 * 86400)),
          let _ = PeopleStore(store: s).create(name: "Sam") else { check(false, "engine setup"); return }
    _ = js.create(text: "Groceries.", now: decisionsNow.addingTimeInterval(-86400))
    // A dismissed decision waits as a rulebook example; the screening writes it into the copy first (built-in text known).
    RulebookSync.setBase("# Decisions rulebook", "eng", DecisionRulebook.settingsKey, store: s)
    if let x = DecisionStore(store: s).record(DecisionDraft(text: "Maybe a trip", quote: "maybe a trip")) { DecisionStore(store: s).notADecision(x.id) }
    var screenBodies = 0
    let engine = FakeEngine { method, path, body in
        switch (method, path) {
        case ("POST", "/v2/decisions/screen"):
            screenBodies += 1
            let jots = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["jots"] as? [[String: Any]]) ?? []
            let results = jots.map { j -> [String: Any] in
                let ref = j["ref"] as? String ?? ""
                let text = j["text"] as? String ?? ""
                return ["ref": ref, "ok": true, "decisions": text.contains("hire Sam")
                    ? [["quote": "We agreed to hire Sam as designer from January.", "decision": "Hire Sam as designer", "type": "strategic",
                        "why": NSNull(), "decided_on": NSNull(), "sure": true]] : []]
            }
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: ["results": results]), as: UTF8.self))
        case ("POST", "/v2/decisions/supersedes"): return (200, #"{"results":[]}"#)
        case ("POST", "/v2/decisions/tell-ask"):
            let items = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            let id = items.first?["id"] as? String ?? ""
            let person = ((items.first?["people"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
            return (200, #"{"results":[{"id":"\#(id)","suggestions":[{"person":"\#(person)","kind":"tell","title":"Tell Sam he is hired"}]}]}"#)
        case ("POST", "/v2/decisions/fill"):
            return (200, #"{"decision":"Hire Sam","why":"not recorded","expected":"","confidence":null,"type":"strategic","alternatives":""}"#)
        case ("GET", "/v2/decision-actions"):
            return (200, #"{"server_time":"2026-11-11T10:00:00Z","actions":[{"id":"act-00000001","decision":"D-999","action":"review","happened":"x","sound":"y"}]}"#)
        case ("POST", "/v2/decision-actions/ack"), ("PUT", "/v2/decisions"): return (200, #"{"ok":true}"#)
        default: return (404, "{}")
        }
    }
    let client = engine.client()
    let out = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: client, now: decisionsNow)
    check(out?.recorded.count == 1 && screenBodies == 1 && engine.bodies("/v2/decisions/screen").first.map { (($0["jots"] as? [Any])?.count ?? 0) == 2 } == true,
          "screening_sends_the_weeks_jots_in_one_batch_and_records")
    let d = DecisionStore(store: s).all().first { $0.text == "Hire Sam as designer" }
    check(d?.foundByClaude == true && d?.sourceItem == a.shortID && DecisionStore(store: s).people(of: d?.id ?? 0).map(\.name) == ["Sam"],
          "screened_decision_linked_to_jot_and_person")
    check(DecisionStore(store: s).suggestions(d?.id ?? 0).map(\.text) == ["Tell Sam he is hired"], "tell_ask_suggested_after_screening")
    check((s.connectors.first { $0.id == "eng" }?.settings[DecisionRulebook.settingsKey] as? String)?.contains("maybe a trip") == true
          && DecisionRulebook.pending(store: s).isEmpty, "screening_writes_waiting_examples_into_the_rulebook_first")
    let again = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: client, now: decisionsNow.addingTimeInterval(3600))
    check(again == nil && screenBodies == 1, "screening_runs_once_a_week")
    s.setModule(.decisions, on: false)
    let off = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: client, now: decisionsNow.addingTimeInterval(8 * 86400))
    check(off == nil && screenBodies == 1, "screening_skipped_while_decisions_off")
    s.setModule(.decisions, on: true)
    // A failed request marks nothing and the run stays due.
    _ = js.create(text: "We chose the blue logo.", now: decisionsNow.addingTimeInterval(7 * 86400))
    let broken = FakeEngine { _, _, _ in (500, "{}") }
    let failed = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: broken.client(), now: decisionsNow.addingTimeInterval(8 * 86400))
    check(failed == nil && DecisionScreening.isDue(now: decisionsNow.addingTimeInterval(8 * 86400), lastRun: DecisionScreening.lastRun(store: s))
          && s.recentActivity(limit: 5).contains { $0.component == "decisions" && $0.level == .warning }, "screening_failure_logged_and_stays_due")
    let before = screenBodies
    let soon = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: client, now: decisionsNow.addingTimeInterval(8 * 86400 + 600))
    let later = await DecisionsEngine.screenIfDue(store: s, connector: "eng", client: client, now: decisionsNow.addingTimeInterval(8 * 86400 + 3700))
    check(soon == nil && later != nil && screenBodies == before + 1, "failed_screening_retried_after_an_hour")
    // Form filling.
    let fill = try? await client.fillDecision(selection: "We agreed to hire Sam", context: a.text) // try?-ok: nil fails the check
    check(fill?.decision == "Hire Sam" && fill?.type == .strategic && fill?.confidence == nil && fill?.why == "not recorded", "fill_form_answer_read")
    // Phone step: actions applied (unknown ones skipped but acked), copy sent once while unchanged.
    await DecisionsEngine.phoneStep(connector: "eng", store: s, client: client, now: decisionsNow)
    let puts = engine.requests.filter { $0.path == "/v2/decisions" }.count
    check(puts == 1 && engine.requests.contains { $0.path == "/v2/decision-actions/ack" }, "phone_step_acks_actions_and_sends_copy")
    await DecisionsEngine.phoneStep(connector: "eng", store: s, client: client, now: decisionsNow)
    check(engine.requests.filter { $0.path == "/v2/decisions" }.count == 1, "phone_copy_sent_only_when_changed")
}
