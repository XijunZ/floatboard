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
