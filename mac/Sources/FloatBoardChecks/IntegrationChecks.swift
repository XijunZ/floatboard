import Foundation
import FloatBoardCore
import FloatBoardConnectors
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
    if let proof = ProcessInfo.processInfo.environment["FLOATBOARD_INTEGRATION_PROOF"] { integrationUpgradeProof(URL(fileURLWithPath: proof), root: root) }
}

@MainActor private func integrationStore(_ root: URL, _ name: String) -> Store? {
    checkStore(root, name, modules: Module.allCases)
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
    check(JotActions.makeDecision?(s, "We go with plan B\nbecause it is cheaper", jot.shortID, { _ in }) == true
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

// MARK: Upgrade proof on a copy of a real board (FLOATBOARD_INTEGRATION_PROOF=<copy>; never the live board)

/// Upgrades the copy the way the app's launch does (pre-migrate backup into the scratch folder, then open) and prints COUNTS
/// ONLY, before and after: never a title, name, note or any other content.
@MainActor private func integrationUpgradeProof(_ url: URL, root: URL) {
    guard !url.path.contains("/Library/Application Support/") else { check(false, "proof refused: not a scratch copy"); return }
    func one(_ q: String) -> String {
        var h: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(h) }
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, sqlite3_prepare_v2(h, q, -1, &st, nil) == SQLITE_OK,
              sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return "n/a" }
        return String(cString: c)
    }
    func facts() -> [(String, String)] {
        let hasKind = rawColumns(url, "links").contains("kind")
        return [("user_version", one("PRAGMA user_version")), ("integrity", one("PRAGMA integrity_check")),
                ("cards", one("SELECT count(*) FROM cards")), ("cards live", one("SELECT count(*) FROM cards WHERE deleted=0 AND withdrawn=0")),
                ("cards deleted", one("SELECT count(*) FROM cards WHERE deleted=1")), ("history events", one("SELECT count(*) FROM events")),
                ("links", one("SELECT count(*) FROM links")),
                ("links by kind", hasKind ? one("SELECT group_concat(k || '=' || n, ', ') FROM (SELECT kind || '/' || made_by AS k, count(*) AS n FROM links GROUP BY kind, made_by ORDER BY k)") : "no kinds yet"),
                ("links by ends", one("SELECT group_concat(k || '=' || n, ', ') FROM (SELECT from_type || '>' || to_type AS k, count(*) AS n FROM links GROUP BY from_type, to_type ORDER BY k)")),
                ("calendar events", one("SELECT count(*) FROM cal_events")), ("calendars", one("SELECT count(*) FROM cal_calendars")),
                ("settings (meta rows)", one("SELECT count(*) FROM meta")), ("connectors", one("SELECT count(*) FROM connectors")),
                ("tags (areas rows)", one("SELECT count(*) FROM areas")),
                ("item tag rows", one("SELECT count(*) FROM sqlite_master WHERE name='item_tags'") == "1" ? one("SELECT count(*) FROM item_tags") : "no table yet"),
                ("kept event records", one("SELECT count(*) FROM sqlite_master WHERE name='cal_kept'") == "1" ? one("SELECT count(*) FROM cal_kept") : "no table yet"),
                ("outbox", one("SELECT count(*) FROM outbox"))]
    }
    let before = facts()
    let cardSum = { one("SELECT sum(length(title) + length(notes)) || '/' || sum(id) FROM cards") }   // compared, never printed
    let sumBefore = cardSum()
    var backedUp = false
    if Backups.migrationCheck(url).needed {
        do { _ = try Backups(dbURL: url, dir: root.appendingPathComponent("proof-bk")).snapshot(reason: "pre-migrate"); backedUp = true }
        catch { check(false, "proof backup: \(type(of: error))"); return }
    }
    let store: Store
    do { store = Store(db: try DB(url: url)) } catch { check(false, "proof upgrade failed: \(type(of: error))"); return }
    let after = facts()
    let live = store.cards
    let primaryOK = live.filter { store.itemTags(ShortID(kind: .task, number: $0.id)).primary == $0.area }.count
    let groups = Set(live.map(\.area)).count
    print("PROOF before: " + before.map { "\($0.0) \($0.1)" }.joined(separator: "; "))
    print("PROOF after:  " + after.map { "\($0.0) \($0.1)" }.joined(separator: "; "))
    print("PROOF app: pre-migrate backup \(backedUp), tasks on the board \(live.count), live tasks whose primary tag is their group \(primaryOK), "
          + "groups in use \(groups), board groups \(store.areas.count), tags \(store.tags.count), modules on \(store.modules.count) of \(Module.allCases.count)")
    let get = { (f: [(String, String)], k: String) in f.first { $0.0 == k }?.1 ?? "" }
    check(get(after, "integrity") == "ok" && get(after, "user_version") == String(DB.schemaVersion) && cardSum() == sumBefore
          && ["cards", "cards live", "cards deleted", "history events", "links", "calendar events", "calendars", "connectors", "outbox"].allSatisfy { get(after, $0) == get(before, $0) }
          && Int(get(after, "settings (meta rows)")) ?? 0 >= Int(get(before, "settings (meta rows)")) ?? 0
          && primaryOK == live.count && store.modules == Set(Module.allCases), "real_board_copy_upgrades_to_16_keeping_everything")
}

// MARK: Settings sync holds back every oversized rulebook (round 4)

/// Every rulebook the merged code syncs (RulebookSync.keys, also Instructions.parts) is held back when it is over the engine's
/// limit, alone: the other settings, rulebooks within the limit included, still go.
@MainActor func integrationRulebookLimitChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-rulebooks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let keys = Set(RulebookSync.keys.values)
    check(keys == Set(Instructions.parts.filter { $0.hasPrefix("rulebook_") }) && keys.count == 3, "every_synced_rulebook_is_a_versioned_part")
    for big in keys.sorted() {
        guard let s = integrationStore(root, "rb-\(big).sqlite") else { return }
        var values: [String: Any] = ["learned": "L", "my_rules": "Mine"]
        for k in keys { values[k] = k == big ? String(repeating: "y", count: 20_001) : "Short \(k)" }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data(), as: UTF8.self) // try?-ok: empty fails the check
        s.performForTest { try s.db.run("INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('rb','rb',?,3,1)", [json]) }
        s.reload()
        let eng = goodEngine()
        let r = await ConnectorSync.run(connector: "rb", store: s, client: eng.client(), now: decisionsNow)
        let sent = eng.bodies("/v2/settings").first?["values"] as? [String: Any]
        check(r.error == nil && sent?[big] == nil && sent?["learned"] as? String == "L" && sent?["my_rules"] as? String == "Mine"
              && keys.subtracting([big]).allSatisfy { sent?[$0] as? String == "Short \($0)" }
              && s.recentActivity(limit: 20).contains { $0.level == .warning && $0.message.contains("rulebook is too long") },
              "oversized_\(big)_held_back_the_rest_synced")
    }
}

// MARK: Every size-limited setting (round 4b)

/// The settings the engine refuses when too long (the whole push would fail) are held back alone; settings the engine trims
/// itself (my_rules, chat_rules, learned) are sent whole. The engine's limits are pinned by engine/test/api/settings-size.test.ts.
@MainActor func integrationSettingsSizeChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-settings-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let limited = ConnectorSync.sizeLimitedSettings
    check(Set(limited.keys) == Set(RulebookSync.keys.values) && limited.values.allSatisfy { $0 == 20_000 }, "size_limited_settings_are_the_rulebooks_at_20000")
    guard let s = integrationStore(root, "settings-size.sqlite") else { return }
    // At the limit by the engine's count (UTF-16 units: one emoji is two), it is sent; one unit over, it is held back.
    let atLimit = String(repeating: "😀", count: 10_000), over = atLimit + "x"
    let long = String(repeating: "r", count: 50_000)
    let values: [String: Any] = ["rulebook_email": atLimit, "rulebook_chat": over, "my_rules": long, "chat_rules": long, "learned": long]
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: values)) ?? Data(), as: UTF8.self) // try?-ok: empty fails the check
    s.performForTest { try s.db.run("INSERT OR REPLACE INTO connectors(id,name,settings_json,settings_version,engine_settings_version) VALUES('sz','sz',?,3,1)", [json]) }
    s.reload()
    let eng = goodEngine()
    let r = await ConnectorSync.run(connector: "sz", store: s, client: eng.client(), now: decisionsNow)
    let sent = eng.bodies("/v2/settings").first?["values"] as? [String: Any]
    let warnings = s.recentActivity(limit: 20).filter { $0.level == .warning && $0.message.contains("too long to send") }
    check(r.error == nil && (sent?["rulebook_email"] as? String)?.utf16.count == 20_000 && sent?["rulebook_chat"] == nil
          && ["my_rules", "chat_rules", "learned"].allSatisfy { (sent?[$0] as? String)?.count == 50_000 } && warnings.count == 1,
          "only_settings_the_engine_refuses_are_held_back_trimmed_ones_sent_whole")
}

// MARK: A phone decision the Mac could not save stays on the engine (Codex review 3, finding 3)

@MainActor func integrationPhoneDecisionStorageChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-dec-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "dec-store.sqlite") else { return }
    DecisionsArea.registerCore()
    let ds = DecisionStore(store: s)
    func make(_ id: String, _ text: String) -> PhoneDecisionAction {
        var a = PhoneDecisionAction(id: id, decision: "", action: "make", madeAt: ISO8601DateFormatter().string(from: decisionsNow))
        a.text = text
        return a
    }
    // The decision row can't be written (a transient storage failure): not acknowledged, nothing recorded.
    s.performForTest("CREATE TRIGGER fail_dec BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let r1 = DecisionPhone.apply([make("s1", "Keep the old supplier"), make("s2", "  ")], store: s, now: decisionsNow)
    check(r1.applied.isEmpty && r1.waiting == ["s1"] && r1.skipped.map(\.0) == ["s2"] && ds.all().isEmpty,
          "phone_decision_storage_failure_is_retried_not_acked_empty_one_dropped")
    s.performForTest("DROP TRIGGER fail_dec")
    // The dedupe marker can't be written: the decision is rolled back with it (never saved without its marker).
    s.performForTest("CREATE TRIGGER fail_mark BEFORE INSERT ON meta WHEN NEW.key LIKE 'decisions.phone_made:%' BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let r2 = DecisionPhone.apply([make("s1", "Keep the old supplier")], store: s, now: decisionsNow)
    check(r2.applied.isEmpty && r2.waiting == ["s1"] && ds.all().isEmpty, "phone_decision_and_its_marker_commit_together")
    s.performForTest("DROP TRIGGER fail_mark")
    // Storage back: recorded once, acknowledged, and a repeat after that is acknowledged without a second decision.
    let r3 = DecisionPhone.apply([make("s1", "Keep the old supplier")], store: s, now: decisionsNow)
    let r4 = DecisionPhone.apply([make("s1", "Keep the old supplier")], store: s, now: decisionsNow)
    check(r3.applied == ["s1"] && r4.applied == ["s1"] && ds.all().filter { $0.text == "Keep the old supplier" }.count == 1, "phone_decision_recorded_once_after_retry")
}

// MARK: Round 7: nothing from the phone is acknowledged unless it was kept (Claude review, A-D)

@MainActor func integrationPhoneAckChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-acks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "acks.sqlite") else { return }
    DecisionsArea.registerCore()
    let ds = DecisionStore(store: s), js = JotStore(store: s)
    guard let d1 = ds.record(DecisionDraft(text: "Move the offsite"), now: decisionsNow.addingTimeInterval(-40 * 86400)),
          let d2 = ds.record(DecisionDraft(text: "Hire later"), now: decisionsNow.addingTimeInterval(-2 * 86400)) else { check(false, "acks setup"); return }
    let review = PhoneDecisionAction(id: "rv1", decision: d1.shortID.text, action: "review", happened: "It went well", sound: "yes")
    // (A) The review's jot can't be written: not acknowledged, the review still open; written later: once.
    s.performForTest("CREATE TRIGGER fail_jot BEFORE INSERT ON jots BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let a1 = DecisionPhone.apply([review], store: s, now: decisionsNow)
    check(a1.applied.isEmpty && a1.skipped.isEmpty && a1.waiting == ["rv1"] && ds.decision(d1.id)?.reviewState != .done,
          "phone_review_storage_failure_is_retried_not_acked")
    s.performForTest("DROP TRIGGER fail_jot")
    let a2 = DecisionPhone.apply([review, PhoneDecisionAction(id: "rv2", decision: d2.shortID.text, action: "review", happened: " ", sound: "")],
                                 store: s, now: decisionsNow)
    check(a2.applied == ["rv1"] && a2.skipped.map(\.0) == ["rv2"] && ds.decision(d1.id)?.reviewState == .done && ds.reviews(of: d1.id).count == 1,
          "phone_review_saved_once_empty_answer_skipped")
    // (B) "Not a decision" whose write fails: not acknowledged, the decision kept.
    s.performForTest("CREATE TRIGGER fail_ex BEFORE INSERT ON decision_examples BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let nd = PhoneDecisionAction(id: "nd1", decision: d2.shortID.text, action: "not_decision")
    let b1 = DecisionPhone.apply([nd], store: s, now: decisionsNow)
    check(b1.applied.isEmpty && b1.waiting == ["nd1"] && ds.decision(d2.id)?.deleted == false, "phone_not_a_decision_failure_is_retried_not_acked")
    s.performForTest("DROP TRIGGER fail_ex")
    check(DecisionPhone.apply([nd], store: s, now: decisionsNow).applied == ["nd1"] && ds.decision(d2.id)?.notDecision == true, "phone_not_a_decision_applied_after_retry")
    // (B) The decisions table can't be read: waiting, never "not found" and acknowledged.
    s.performForTest("ALTER TABLE decisions RENAME TO decisions_away")
    let b2 = DecisionPhone.apply([PhoneDecisionAction(id: "rv3", decision: d1.shortID.text, action: "review", happened: "x", sound: "")], store: s, now: decisionsNow)
    s.performForTest("ALTER TABLE decisions_away RENAME TO decisions")
    check(b2.applied.isEmpty && b2.skipped.isEmpty && b2.waiting == ["rv3"], "decision_read_error_is_waiting_not_not_found")
    check(DecisionPhone.apply([PhoneDecisionAction(id: "rv4", decision: "D-99999", action: "review", happened: "x", sound: "")], store: s, now: decisionsNow)
            .skipped.map(\.0) == ["rv4"], "unknown_decision_is_still_skipped")
    // (C) A phone edit of a jot whose row can't be read: not acknowledged; read again: applied.
    guard let j = js.create(text: "Budget notes", now: decisionsNow.addingTimeInterval(-3600)) else { check(false, "acks jot"); return }
    let edit = EngineJot(key: "J-\(j.id)", macID: j.id, text: "Budget notes, edited on the phone", kind: "jot", source: "typed",
                         added: decisionsNow.addingTimeInterval(-3600), updated: decisionsNow, deleted: false, rev: 2)
    s.performForTest("ALTER TABLE jots RENAME TO jots_away")
    let c1 = JotsSyncCore(store: s).apply([edit], now: decisionsNow)
    s.performForTest("ALTER TABLE jots_away RENAME TO jots")
    check(c1.isEmpty, "jot_read_error_does_not_ack_the_phone_edit")
    let c2 = JotsSyncCore(store: s).apply([edit], now: decisionsNow)
    check(c2.count == 1 && js.jot(j.id)?.text == "Budget notes, edited on the phone", "phone_edit_applied_after_the_read_works")
}

// MARK: Round 7 sweep (D): Circle and the older phone Make decision

@MainActor func integrationAckSweepChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-sweep-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "sweep.sqlite") else { return }
    DecisionsArea.registerCore()
    let c = CircleStore(store: s)
    var det = CircleDetails(); det.intervalDays = 14
    guard let p = c.add(name: "Sweep Person", tier: .close, tags: ItemTags(primary: nil, others: []), details: det,
                        handles: [], now: decisionsNow.addingTimeInterval(-86400)).person else { check(false, "sweep setup"); return }
    // A person whose row can't be read is not "unknown" (acknowledged and dropped): it stays for the next sync.
    let tap = CirclePhoneAction(id: "sw1", person: p.shortID.text, action: "snooze", madeAt: ISO8601DateFormatter().string(from: decisionsNow))
    s.performForTest("ALTER TABLE people RENAME TO people_away")
    let r1 = c.applyPhoneActions([tap], now: decisionsNow)
    s.performForTest("ALTER TABLE people_away RENAME TO people")
    check(r1.applied.isEmpty && r1.skipped.isEmpty && r1.failed == ["sw1"], "circle_person_read_error_is_retried_not_skipped")
    // A snooze never writes defaults over details it couldn't read.
    s.performForTest("ALTER TABLE circle_people RENAME TO circle_people_away")
    let r2 = c.applyPhoneActions([tap], now: decisionsNow)
    s.performForTest("ALTER TABLE circle_people_away RENAME TO circle_people")
    check(r2.failed == ["sw1"] && c.details(p.id).intervalDays == 14, "circle_snooze_never_overwrites_unread_details")
    check(c.applyPhoneActions([tap], now: decisionsNow).applied == ["sw1"] && c.details(p.id).snoozedUntil != nil, "circle_snooze_applied_after_retry")
    // An older phone's jot Make decision whose decision can't be written is not acknowledged.
    guard let j = JotStore(store: s).create(text: "We go with plan B", now: decisionsNow) else { check(false, "sweep jot"); return }
    s.performForTest("CREATE TRIGGER fail_dec2 BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let handed = JotActions.makeDecision?(s, "We go with plan B", j.shortID, { _ in })
    s.performForTest("DROP TRIGGER fail_dec2")
    check(handed == false, "older_phone_make_decision_storage_failure_is_not_acked")
}

// MARK: Round 7 (H): one parent per goal through unlink, reparent, undo and "No parent"

@MainActor func integrationGoalParentChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-int-parent-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "parent.sqlite") else { return }
    Resolutions.register()
    let rs = ResolutionStore(store: s)
    let year = GoalPeriod.current(.year, now: decisionsNow), quarter = GoalPeriod.current(.quarter, now: decisionsNow)
    guard case .success(let a) = rs.create(level: .year, period: year, title: "Grow the team", now: decisionsNow),
          case .success(let b) = rs.create(level: .year, period: year, title: "Keep costs flat", now: decisionsNow),
          case .success(let c) = rs.create(level: .quarter, period: quarter, title: "Hire two engineers", parent: a.id, now: decisionsNow)
    else { check(false, "parent setup"); return }
    let parents = { () -> [ShortID] in
        s.itemLinks(of: c.shortID).filter { $0.other.kind == .resolution && $0.kind == .serves && $0.isSubject }.map(\.other)
    }
    s.unlinkWithUndo(c.shortID, a.shortID)                                        // ✕ on the parent chip
    check(rs.setParent(c.id, b.id, now: decisionsNow.addingTimeInterval(60)) == nil && parents() == [b.shortID], "reparent_after_unlink")
    s.undoUnlink()                                                                // Undo brings A back: it replaces B, never a second parent
    check(parents() == [a.shortID] && rs.parent(of: c.id)?.id == a.id, "undo_unlink_of_a_parent_replaces_the_current_parent")
    check(rs.setParent(c.id, nil, now: decisionsNow.addingTimeInterval(120)) == nil && parents().isEmpty && rs.parent(of: c.id) == nil,
          "no_parent_removes_every_parent_link")
}

// MARK: Round 7 (G): the address a Circle feed fetch actually connected to is the one that counts (DNS rebinding)

func integrationRebindingChecks() async {
    // More ranges that are not the public internet: NAT64 local-use 64:ff9b:1::/48, 6to4 2002::/16, site-local fec0::/10.
    check(["64:ff9b:1::a00:1", "64:ff9b:1:ffff::1", "2002:c0a8:101::1", "2002::1", "fec0::1", "feff::1"].allSatisfy { !PublicAddress.isPublic($0) }
          && ["2606:4700::1111", "2001:4860:4860::8888"].allSatisfy { PublicAddress.isPublic($0) }, "bridge_blocks_nat64_local_6to4_and_site_local")
    // The name resolves to a public address for the check, then to a private one when the fetch connects (TTL 0).
    var lookups = 0
    let resolver: (String) -> [String] = { _ in lookups += 1; return lookups == 1 ? ["93.184.216.34"] : ["192.168.1.10"] }
    guard let req = try? LocalEngine.request(from: ["url": "https://feed.example.com/rss", "method": "GET", "publicOnly": true, "redirect": "manual"], // try?-ok: nil fails below
                                             resolve: resolver) else { check(false, "rebinding setup: the first answer is public"); return }
    let secret = Data("router admin page".utf8)
    let transport: LocalEngine.ConnectedTransport = { r in
        (secret, HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, resolver(r.url!.host!))
    }
    var got: Data?, refused = false
    do { got = try await LocalEngine.network(req, transport: transport).0 } catch { refused = "\(error)".contains("not a public") }
    check(refused && got == nil && lookups == 2, "bridge_discards_a_response_from_a_private_address_it_connected_to")
    // Connected to a public address: the answer comes through. Unknown address (no metrics): refused.
    let pub: LocalEngine.ConnectedTransport = { r in (Data("ok".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, ["93.184.216.34"]) }
    let unknown: LocalEngine.ConnectedTransport = { r in (Data("ok".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, [nil]) }
    let okData = try? await LocalEngine.network(req, transport: pub).0 // try?-ok: nil fails the check
    let unknownData = try? await LocalEngine.network(req, transport: unknown).0 // try?-ok: nil is the expected answer
    check(okData == Data("ok".utf8) && unknownData == nil, "bridge_passes_public_connections_and_refuses_unknown_ones")
    // Fetches not marked public only are not checked (the engine's own API calls, Gmail, Claude).
    let plain = URLRequest(url: URL(string: "http://10.0.0.1/x")!)
    let plainData = try? await LocalEngine.network(plain, transport: unknown).0 // try?-ok: nil fails the check
    check(plainData == Data("ok".utf8), "bridge_leaves_other_fetches_unchecked")
}

/// The same against the real network code: a local web server, a name the check was told is public, and URLSession then
/// connecting to this Mac (127.0.0.1 / ::1). The answer must be thrown away, unread.
func integrationRebindingLiveChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-rebind-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    try? "home router admin".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8) // try?-ok: the check below fails without it
    let port = Int.random(in: 20000...40000)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", root.path]
    // The server's request log: round 18 checks that the bridge's request never reaches it (refused before connecting).
    let log = root.appendingPathComponent("requests.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    server.standardOutput = FileHandle.nullDevice
    server.standardError = (try? FileHandle(forWritingTo: log)) ?? FileHandle.nullDevice // try?-ok: no log fails the check below
    do { try server.run() } catch { print("SKIP live rebinding check: no python3 (\(error))"); return }
    defer { server.terminate() }
    // Wait for it to answer (plain fetch, not checked).
    var up = false
    for _ in 0..<50 where !up {
        try? await Task.sleep(nanoseconds: 100_000_000) // try?-ok: a cancelled sleep just checks again
        up = (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil // try?-ok: not up yet
    }
    guard up else { check(false, "live rebinding setup: local server"); return }
    guard let req = try? LocalEngine.request(from: ["url": "http://localhost:\(port)/secret.txt", "method": "GET", "publicOnly": true, "redirect": "manual"], // try?-ok: nil fails below
                                             resolve: { _ in ["93.184.216.34"] }) else { check(false, "live rebinding setup: request"); return }
    var leaked: Data?, refused = false
    do { leaked = try await LocalEngine.liveNetwork(req).0 } catch { refused = "\(error)".contains("not a public") }
    check(refused && leaked == nil, "live_bridge_throws_away_an_answer_from_a_private_connection")
    // Round 18 (b): the bridge resolves the name itself and connects only to the public address it checked, so a name
    // that resolves to this Mac (or the home network) when connecting is refused before any request is sent.
    try? await Task.sleep(nanoseconds: 300_000_000) // try?-ok: only gives the server time to write its log
    let seen = (try? String(contentsOf: log, encoding: .utf8)) ?? "" // try?-ok: empty passes only if nothing was logged
    check(!seen.contains("/secret.txt"), "live_bridge_sends_nothing_to_a_private_address")
    // The pinned GET itself works end to end (to this Mac on purpose, past the public check): status, headers and body.
    var pinned: (Data, HTTPURLResponse)?
    do { pinned = try await PinnedHTTP.get(URLRequest(url: URL(string: "http://localhost:\(port)/secret.txt")!), ip: "127.0.0.1", timeout: 10) }
    catch { check(false, "pinned get: \(error)") }
    check(pinned?.1.statusCode == 200 && pinned.map { String(decoding: $0.0, as: UTF8.self) } == "home router admin", "pinned_get_reads_the_answer")
    // The answer parser: chunked bodies, Content-Length, folded duplicate headers, and a bad status line.
    let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: 1\r\nX-A: 2\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n".utf8)
    let p1 = try? PinnedHTTP.parse(chunked) // try?-ok: nil fails the check
    let p2 = try? PinnedHTTP.parse(Data("HTTP/1.1 301 Moved\r\nLocation: https://x.example/\r\nContent-Length: 3\r\n\r\nabcdef".utf8)) // try?-ok: nil fails the check
    let p3 = try? PinnedHTTP.parse(Data("garbage\r\n\r\n".utf8)) // try?-ok: nil is expected
    check(p1.map { String(decoding: $0.2, as: UTF8.self) } == "hello world" && p1?.1["X-A"] == "1, 2" && p1?.1["Transfer-Encoding"] == nil
          && p2?.0 == 301 && p2?.1["Location"] == "https://x.example/" && p2.map { String(decoding: $0.2, as: UTF8.self) } == "abc" && p3 == nil,
          "pinned_get_parses_http_answers")
    // Round 20 (1): a hostile or broken answer never crashes the app: negative or huge sizes are refused or ignored.
    let bad = ["HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nabc", "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\nabc",
               "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nabc\r\n0\r\n\r\n",
               "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nabc\r\n0\r\n\r\n",
               "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffffff\r\nabc\r\n"]
    let survived = bad.map { raw -> Bool in
        let r = try? PinnedHTTP.parse(Data(raw.utf8)) // try?-ok: refusing is fine; not crashing is the check
        return r == nil || r!.2.count <= 3
    }
    check(survived.allSatisfy { $0 }, "pinned_get_survives_bad_sizes")
    // Round 20 (2): a server that accepts and then never answers is given up on at the timeout (the connection is cancelled),
    // so the engine's run finishes and the next one can start.
    let stallPort = Int.random(in: 40001...50000)
    let staller = Process()
    staller.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    staller.arguments = ["-c", "import socket,time\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',\(stallPort)));s.listen(5)\nwhile True:\n c,_=s.accept();time.sleep(120)"]
    staller.standardOutput = FileHandle.nullDevice; staller.standardError = FileHandle.nullDevice
    if (try? staller.run()) != nil { // try?-ok: no python3 skips this part
        defer { staller.terminate() }
        try? await Task.sleep(nanoseconds: 500_000_000) // try?-ok: only waits for the server to listen
        let started = Date()
        let finished = await withTaskGroup(of: Bool.self) { g -> Bool in
            g.addTask {
                do { _ = try await PinnedHTTP.get(URLRequest(url: URL(string: "http://localhost:\(stallPort)/feed")!), ip: "127.0.0.1", timeout: 1) } catch {}
                return true
            }
            g.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return false } // try?-ok: the watchdog
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        check(finished && Date().timeIntervalSince(started) < 5, "pinned_get_gives_up_on_a_stalled_server_at_the_timeout")
    }
}

/// Round 13 (A4): Search everything keeps each person's and each event's search text until the board changes, instead of
/// rebuilding it on every keystroke; the search over that text can run off the main thread.
@MainActor func searchIndexChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-search-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "search.sqlite") else { return }
    CircleDue.register()
    let c = CircleStore(store: s), none = ItemTags(primary: nil, others: [])
    for i in 0..<300 { _ = c.add(name: "Person \(i)", tier: .network, tags: none, details: CircleDetails(), handles: []) }
    let b0 = SearchIndex.builds
    for q in ["Pe", "Per", "Pers", "Person 2"] { _ = GlobalSearch.run(q, store: s) }
    check(SearchIndex.builds - b0 == 1, "search_text_built_once_while_typing (\(SearchIndex.builds - b0))")
    _ = c.add(name: "Zed Newcomer", tier: .network, tags: none, details: CircleDetails(), handles: [])
    let hits = GlobalSearch.run("Newcomer", store: s).first { $0.0 == .person }?.1 ?? []
    check(hits.map(\.title) == ["Zed Newcomer"] && SearchIndex.builds - b0 == 2, "search_text_rebuilt_after_a_change")
    let snapshot = SearchIndex.people(store: s)
    let found = await Task.detached { SearchIndex.match(snapshot, "Person 29") }.value
    check(found.contains { $0.title == "Person 29" } && !found.contains { $0.title == "Person 3" }, "search_matching_runs_off_the_main_thread")
}

/// Round 13 (C3): the Circle tab's numbers are worked out once per change (not per keystroke), and merge suggestions are
/// found by grouping names, not by comparing every pair. 2,000 synthetic people.
@MainActor func circleSpeedChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-circle-speed-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "speed.sqlite") else { return }
    s.performForTest {
        for i in 0..<2000 {
            try s.db.run("INSERT INTO people(name, aliases, tier, source, added, updated) VALUES(?,?,?,?,?,?)",
                         [i % 500 == 7 ? "Same Name" : "Person \(i)", i == 1999 ? #"["Person 3"]"# : "[]", "network", "typed", 1_790_000_000.0, 1_790_000_000.0])
        }
    }
    s.reload()
    let c = CircleStore(store: s)
    let t0 = Date()
    let merges = c.mergeSuggestions()
    let took = Date().timeIntervalSince(t0)
    check(merges.filter { $0.reason == "Same name" }.count == 6 && merges.contains { $0.reason == "Also known as" } && took < 0.5,
          "merge_suggestions_for_2000_people_quickly (\(String(format: "%.2f", took)) s)")
    let now = Date()
    let b0 = CircleSnapshot.builds
    for _ in 0..<5 { _ = CircleSnapshot.current(store: s, now: now) }   // five keystrokes
    check(CircleSnapshot.builds - b0 == 1, "circle_tab_numbers_worked_out_once_per_change")
    _ = c.add(name: "Newcomer", tier: .network, tags: ItemTags(primary: nil, others: []), details: CircleDetails(), handles: [])
    let snap = CircleSnapshot.current(store: s, now: now)
    check(CircleSnapshot.builds - b0 == 2 && snap.people.count == 2001 && snap.suggestionCount >= 7, "circle_tab_numbers_follow_changes")
}

/// Round 13 (C5): a birthday reminder is its own kind: it never takes a due reminder's id for the same person and day, and
/// it gets no Contacted / Snooze buttons on the phone.
@MainActor func birthdayReminderChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-bday-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "bday.sqlite") else { return }
    let c = CircleStore(store: s), now = Date(timeIntervalSince1970: 1_794_391_200)
    var d = CircleDetails(); d.birthday = Due.dayString(now)
    guard let p = c.add(name: "Birthday Example", tier: .close, tags: ItemTags(primary: nil, others: []), details: d, handles: [], now: now.addingTimeInterval(-200 * 86400)).person
    else { check(false, "bday setup"); return }
    ReminderBudget(store: s).save(ReminderSettings(dailyLimit: 5, quietStart: 0, quietEnd: 0))
    _ = CircleDue.requestReminders(store: s, now: now)
    let pend = ReminderBudget(store: s).pending().filter { $0.item == p.shortID.text }
    check(pend.count == 2 && Set(pend.map(\.kind)) == ["circle_due", "circle_birthday"] && Set(pend.map(\.id)).count == 2,
          "birthday_and_due_reminders_are_two_reminders")
    check(pend.first { $0.kind == "circle_birthday" }?.id.hasPrefix("rb-circle_birthday-") == true, "birthday_reminder_has_its_own_id")
}

/// Round 13 (J2): a second review answer from the phone with different words is kept as another review jot; the same words
/// again (a repeat) add nothing.
@MainActor func secondReviewChecks() {
    let root = checkFolder("fb-review2")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "review2.sqlite") else { return }
    DecisionsArea.registerCore()
    let ds = DecisionStore(store: s)
    guard let d = ds.record(DecisionDraft(text: "Move the offsite"), now: decisionsNow.addingTimeInterval(-40 * 86400)) else { check(false, "review2 setup"); return }
    let a1 = PhoneDecisionAction(id: "r1", decision: d.shortID.text, action: "review", happened: "It went well", sound: "yes")
    let a2 = PhoneDecisionAction(id: "r2", decision: d.shortID.text, action: "review", happened: "Later: costs rose", sound: "partly")
    let r = DecisionPhone.apply([a1, a1, a2], store: s, now: decisionsNow)
    let texts = ds.reviews(of: d.id).map(\.text)
    check(r.applied == ["r1", "r1", "r2"] && texts.count == 2 && texts.contains { $0.contains("Later: costs rose") }, "a_second_different_review_is_kept_as_another_review")
}

/// Round 13 (minor): a screened version whose decision couldn't be saved is not marked screened (it is read again).
@MainActor func screeningRecordFailureChecks() {
    let root = checkFolder("fb-screenfail")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = integrationStore(root, "screenfail.sqlite") else { return }
    DecisionsArea.registerCore()
    guard let j = JotStore(store: s).create(text: "We decided to stop the newsletter.", now: decisionsNow.addingTimeInterval(-3600)) else { check(false, "sf setup"); return }
    let job = ScreenJot(ref: "J-\(j.id)@\(DecisionScreening.version(j.text))", kind: "jot", added: "", text: j.text, references: [])
    let ans = ScreenResult(ref: job.ref, ok: true, decisions: [ScreenFound(quote: "We decided to stop the newsletter", decision: "Stop the newsletter", type: "operational")])
    s.performForTest("CREATE TRIGGER fail_d BEFORE INSERT ON decisions BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let o = DecisionScreening.apply([ans], sent: [job], store: s, now: decisionsNow)
    s.performForTest("DROP TRIGGER fail_d")
    check(o.screened == 0 && o.unreadable == 1 && DecisionScreening.pending(store: s, now: decisionsNow).contains { $0.ref == job.ref },
          "screening_keeps_a_version_whose_decision_could_not_be_saved")
}

/// Round 14 (4): the people-to-follow list is sent per engine account (like the phone copies), so a connector moved to
/// another engine sends it again, and forgetting a connector forgets it.
@MainActor func circleWatchPerEngineChecks() async {
    let root = checkFolder("fb-watch")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = checkStore(root, "watch.sqlite", modules: [.circle]) else { return }
    var puts: [String] = []
    func engine(_ host: String) -> ConnectorClient {
        ConnectorClient(baseURL: URL(string: "https://\(host)")!, key: "k") { req in
            await MainActor.run {
                let ok = req.httpMethod == "PUT" && req.url!.path == "/v2/circle/watch"
                if ok { puts.append(host) }
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
    let a = engine("a.test"), b = engine("b.test")
    await CircleSync.run(store: s, client: a, connector: "cw", now: Date())
    await CircleSync.run(store: s, client: a, connector: "cw", now: Date())
    await CircleSync.run(store: s, client: b, connector: "cw", now: Date())
    ConnectorMemory.forget(connector: "cw", store: s)
    await CircleSync.run(store: s, client: b, connector: "cw", now: Date())
    check(puts == ["a.test", "b.test", "b.test"], "circle_watch_list_sent_per_engine_account_and_again_after_forget")
}

/// Round 15: a board upgraded from 17 to 18 keeps its screening place. The saved mark is the newest change_seq, which runs
/// ahead of the ids, so the new screen_seq starts as change_seq: a jot added and a jot edited after the mark are screened
/// after the upgrade, and a version screened before it is not sent again.
@MainActor func screenSeqUpgradeChecks() {
    let root = checkFolder("fb-v17-18")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let url = root.appendingPathComponent("v17.sqlite")
    do { _ = try DB(url: url) } catch { check(false, "v17 setup: \(error)"); return }
    var h: OpaquePointer?
    guard sqlite3_open(url.path, &h) == SQLITE_OK else { check(false, "v17 open"); return }
    func exec(_ sql: String) -> Bool { sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK }
    let seq = "(SELECT coalesce(max(change_seq), 0) + 1 FROM jots)"
    // Back to the version 17 shape: no jot_pushed, no screen_seq, the v17 triggers.
    let down = """
        DROP TABLE jot_pushed; DROP TRIGGER jots_seq_insert; DROP TRIGGER jots_seq_update; DROP TRIGGER jots_seq_task;
        DROP INDEX jots_screen_seq; ALTER TABLE jots DROP COLUMN screen_seq;
        CREATE TRIGGER jots_seq_insert AFTER INSERT ON jots BEGIN UPDATE jots SET change_seq = \(seq) WHERE id = NEW.id; END;
        CREATE TRIGGER jots_seq_update AFTER UPDATE OF text, kind, deleted, task_id ON jots WHEN NEW.change_seq = OLD.change_seq BEGIN
            UPDATE jots SET change_seq = \(seq) WHERE id = NEW.id; END;
        PRAGMA user_version = 17;
        """
    let t = Date().addingTimeInterval(-3600).timeIntervalSince1970
    let ins = { (text: String) in "INSERT INTO jots(text, kind, source, added, updated) VALUES('\(text)', 'jot', 'typed', \(t), \(t));" }
    let va = DecisionScreening.version("We decided A"), vc = DecisionScreening.version("We decided C")
    // A and C were screened; the jots' change order then ran ahead of the ids (tag changes); then the mark M was kept.
    let ok = exec(down) && exec(ins("We decided A") + ins("We decided C"))
        && exec("INSERT INTO decision_screened(jot_id, version, screened, found) VALUES(1, '\(va)', \(t), 0), (2, '\(vc)', \(t), 0);")
        && exec("UPDATE jots SET change_seq = change_seq + 50;")
        && exec("INSERT OR REPLACE INTO meta(key, value) VALUES('decisions.screen_jot_id', (SELECT max(change_seq) FROM jots));")
        && exec(ins("We decided B, added after the run")) && exec("UPDATE jots SET text='We decided C, then changed it' WHERE id=2;")
    let why = String(cString: sqlite3_errmsg(h))
    sqlite3_close(h)
    guard ok else { check(false, "v17 board setup: \(why)"); return }
    let store: Store
    do { store = Store(db: try DB(url: url)) } catch { check(false, "v17->18 upgrade: \(error)"); return }
    store.setModule(.jots, on: true); store.setModule(.decisions, on: true)
    let refs = DecisionScreening.pending(store: store, now: Date().addingTimeInterval(30 * 86400)).map(\.ref)
    check(refs.contains { $0.hasPrefix("J-3@") } && refs.contains { $0.hasPrefix("J-2@") } && !refs.contains { $0.hasPrefix("J-1@") },
          "upgrade_17_to_18_screens_jots_written_after_the_mark_and_not_those_before")
}

/// Round 18 (3): a save that fails is reported, so a sheet or form stays open with its fields: editing a goal answers with
/// a problem when its write fails, and every swallowed write failure is counted (forms compare the count before closing).
@MainActor func saveFailureChecks() {
    let root = checkFolder("fb-savefail")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = checkStore(root, "sf.sqlite", modules: [.resolutions, .jots, .circle]) else { return }
    let r = ResolutionStore(store: s)
    guard case .success(let g) = r.create(level: .quarter, period: GoalPeriod.current(.quarter, now: Date()), title: "Ship the plan") else { check(false, "sf setup"); return }
    s.performForTest("CREATE TRIGGER fail_r BEFORE UPDATE ON resolutions BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    let before = s.failedWrites
    let problem = r.update(g.id, title: "Ship the plan by Friday", notes: "")
    check(problem != nil && r.goal(g.id)?.title == "Ship the plan", "a_goal_edit_that_fails_says_so")
    guard let p = PeopleStore(store: s).create(name: "Ann Example") else { check(false, "sf person"); return }
    s.performForTest("CREATE TRIGGER fail_p BEFORE UPDATE ON people BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END")
    var q = p; q.name = "Ann B Example"
    let mid = s.failedWrites
    PeopleStore(store: s).update(q)
    check(mid > before && s.failedWrites == mid + 1, "a_swallowed_write_failure_is_counted")
}

/// Round 20 (3): what this Mac read from an engine (Circle's activity and What's new cursors) belongs to that engine
/// account: another engine or key starts from the beginning, and forgetting a connector forgets them.
@MainActor func circleCursorPerEngineChecks() async {
    let root = checkFolder("fb-ccur")
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    guard let s = checkStore(root, "ccur.sqlite", modules: [.circle]) else { return }
    var asked: [String] = []
    func engine(_ host: String) -> ConnectorClient {
        ConnectorClient(baseURL: URL(string: "https://\(host)")!, key: "k") { req in
            await MainActor.run {
                let path = req.url!.path
                if path == "/v2/circle/exchanges" || path == "/v2/circle/updates" { asked.append("\(host)\(path)?\(req.url!.query ?? "")") }
                let body: Any = path == "/v2/circle/exchanges" ? ["exchanges": [], "readers": [], "next": 50, "more": false]
                    : path == "/v2/circle/updates" ? ["updates": [], "next": 40, "more": false] : [:]
                let ok = path == "/v2/circle/exchanges" || path == "/v2/circle/updates"
                return ((try? JSONSerialization.data(withJSONObject: body)) ?? Data(), // try?-ok: test stand-in
                        HTTPURLResponse(url: req.url!, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!)
            }
        }
    }
    let a = engine("a.test"), b = engine("b.test")
    await CircleSync.run(store: s, client: a, connector: "cc", now: Date())
    await CircleSync.run(store: s, client: a, connector: "cc", now: Date())
    let againA = asked.filter { $0.hasPrefix("a.test") }.suffix(2)
    asked = []
    await CircleSync.run(store: s, client: b, connector: "cc", now: Date())   // the connector now points at another engine
    check(againA.allSatisfy { $0.contains("after=50") || $0.contains("after=40") } && asked.allSatisfy { $0.contains("after=0") } && asked.count == 2,
          "circle_cursors_start_again_on_another_engine")
    asked = []
    ConnectorMemory.forget(connector: "cc", store: s)
    await CircleSync.run(store: s, client: b, connector: "cc", now: Date())
    check(asked.count == 2 && asked.allSatisfy { $0.contains("after=0") }, "forgetting_a_connector_forgets_its_circle_cursors")
}

/// Round 22: the toolbar search's list: results grouped by where they live (Tasks, Calendar, Jots, Circle, Decisions,
/// Goals), at most 5 a group with "Show all N", and ↓/↑ moving through every row across groups.
@MainActor func searchListChecks() {
    func hits(_ k: ItemKind, _ n: Int) -> [SearchHit] { (1...n).map { SearchHit(id: ShortID(kind: k, number: Int64($0)), title: "\(k.noun) \($0)", detail: "", date: nil) } }
    let results: [(ItemKind, [SearchHit])] = [(.jot, hits(.jot, 7)), (.task, hits(.task, 2)), (.person, hits(.person, 1))]
    var list = SearchList(results: results)
    check(list.groups.map(\.title) == ["Tasks", "Jots", "Circle"] && list.groups.map(\.count) == [2, 7, 1], "search_list_groups_in_tab_order_with_counts")
    check(list.rows.compactMap(\.hit).count == 2 + 5 + 1 && list.rows.contains { $0.showAll == .jot } && !list.rows.contains { $0.showAll == .task },
          "search_list_shows_five_a_group_then_show_all")
    list.expand(.jot)
    check(list.rows.compactMap(\.hit).count == 2 + 7 + 1 && !list.rows.contains { $0.showAll != nil }, "search_list_show_all_expands_the_group")
    var nav = SearchList(results: results)
    nav.move(1)
    let first = nav.highlighted?.hit?.id
    nav.move(1); nav.move(1)
    let third = nav.highlighted?.hit?.id
    nav.move(-1); nav.move(-1); nav.move(-1)
    check(first == ShortID(kind: .task, number: 1) && third == ShortID(kind: .jot, number: 1) && nav.highlighted?.hit?.id == ShortID(kind: .task, number: 1),
          "search_list_arrows_move_across_groups_and_stop_at_the_ends")
    check(SearchList(results: []).rows.isEmpty && SearchList(results: []).groups.isEmpty, "search_list_empty")
    check(SearchList.title(.event) == "Calendar" && SearchList.title(.resolution) == "Goals" && SearchList.title(.decision) == "Decisions", "search_list_group_names")
}

/// Round 23: a search result asks its tab to reveal the item once that tab is on screen (the board's columns, the
/// Calendar's day): the request waits until the view holding the item takes it, and picking the same item twice asks twice.
@MainActor func revealRequestChecks() {
    var pending: RevealRequest? = RevealRequest(42)
    let notHere = RevealRequest.take(&pending, ifIn: [1, 2, 3])
    check(notHere == nil && pending?.id == 42, "a_reveal_waits_for_the_view_holding_the_item")
    let taken = RevealRequest.take(&pending, ifIn: [41, 42])
    check(taken == 42 && pending == nil, "a_reveal_is_taken_once_by_the_view_holding_it")
    check(RevealRequest(42) != RevealRequest(42), "picking_the_same_item_twice_asks_twice")
}
