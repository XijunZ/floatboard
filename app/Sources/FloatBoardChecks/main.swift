import Foundation
import FloatBoardCore
import SQLite3
import FloatBoardConnectors

// Core self-checks. Never touches real data: refuses to run unless both scratch paths are set.
let env = ProcessInfo.processInfo.environment
guard env[LocalData.databaseEnv] != nil, env[LocalData.credentialsEnv] != nil, let bkDir = env[LocalData.backupsEnv] else {
    print("FloatBoardChecks needs FLOATBOARD_DB, FLOATBOARD_CREDS and FLOATBOARD_BACKUPS set to scratch paths so it never touches real data")
    exit(2)
}

var failures: [String] = []
func check(_ ok: Bool, _ name: String) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures.append(name) } }

nonisolated(unsafe) var sharedStore: Store?

MainActor.assumeIsolated {
    let store: Store
    do { store = Store(db: try DB()) } catch { print("CHECKS FAILED: cannot open db: \(error)"); exit(1) }
    sharedStore = store

    store.seedCard(title: "Reply to Anna", importance: .high, source: "test", externalID: "email:abc",
                   link: "https://example.com", meta: ["why": "asked"])
    let card = store.card(externalID: "email:abc")
    check(card?.source == "test" && card?.sourceLink == "https://example.com" && card?.sourceMeta["why"] == "asked",
          "connector_card_loads_source_link_and_meta")
    if let c = card { store.delete(c) }
    store.seedCard(title: "Weekly planning call", area: "Personal", importance: .medium, source: "test", externalID: "cal:planning")
    if let planning = store.card(externalID: "cal:planning") {
        store.setAISummary(cardID: planning.id, text: "Meeting notes", actor: .connector("email"))
    }
    check(store.card(externalID: "cal:planning")?.aiSummary.contains("Meeting notes") ?? false, "ai_summary_set_by_card_id")

    // History actors and AI summaries
    store.add(title: "Typed card", area: "Personal", importance: .medium, due: nil)
    let typed = store.cards.first { $0.title == "Typed card" }
    check(typed.map { store.isTouched($0.id) } ?? false, "typed_card_is_touched_by_its_creator")
    if let t = typed {
        var edited = t; edited.notes = "my note"
        store.update(edited)
        check(store.isTouched(t.id), "user_edit_records_user_actor")
        let actors = (try? store.db.query("SELECT actor, uuid FROM events WHERE card_id=?", [t.id]) { (DB.text($0, 0), DB.text($0, 1)) }) ?? [] // try?-ok: a failed query makes the check fail
        check(!actors.isEmpty && actors.allSatisfy { $0.0 == "user" && !$0.1.isEmpty }
              && Set(actors.map(\.1)).count == actors.count, "events_have_actor_and_unique_uuid")
        store.setAISummary(cardID: t.id, text: "first", actor: .connector("email"))
        store.setAISummary(cardID: t.id, text: "second", actor: .connector("email"))
        let after = store.card(t.id)
        check(after?.aiSummary == "first\n\nsecond" && after?.notes == "my note", "ai_summary_separate_from_notes")
        let who = (try? store.db.query("SELECT actor FROM events WHERE card_id=? ORDER BY id DESC LIMIT 1", [t.id]) { DB.text($0, 0) }) ?? [] // try?-ok: a failed query makes the check fail
        check(who == ["connector:email"], "connector_event_records_connector_actor")
        check(Actor.parse("connector:email") == .connector("email") && Actor.parse("user") == .user
              && Actor.connector("x").stored == "connector:x", "actor_roundtrip")
        store.record(t.id, "withdrawn by connector", actor: .connector("email"))
        check(store.isTouched(t.id), "user_event_still_counts_after_connector_events")
    }
    store.seedCard(title: "Connector only", area: "Personal", importance: .low, source: "email", externalID: "email:conly")
    if let c = store.card(externalID: "email:conly") {
        store.setAISummary(cardID: c.id, text: "s", actor: .connector("email"))
        check(!store.isTouched(c.id), "new_card_untouched_until_user_acts")
        store.move(c, to: .doing)
        check(store.isTouched(c.id), "user_move_touches_connector_card")
    }
    store.seedCard(title: "New mail", area: "Personal", importance: .low, source: "email", externalID: "email:newmid")

    // Outbox and corrections
    @MainActor func outboxRows() -> [(kind: String, payload: [String: String], uuid: String)] {
        let r = (try? store.db.query("SELECT kind, payload_json, uuid FROM outbox ORDER BY created, rowid") { // try?-ok: a failed query makes the check fail
            (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2)) }) ?? []
        return r.map { ($0.0, ((try? JSONSerialization.jsonObject(with: Data($0.1.utf8))) as? [String: String]) ?? [:], $0.2) } // try?-ok: bad json fails the check
    }
    @MainActor func connectorCard(_ ext: String, item: String = "item-1") -> Card? {
        store.seedCard(title: "OB \(ext)", importance: .medium, source: "email", externalID: ext, meta: ["itemId": item])
        return store.card(externalID: ext)
    }
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    do {
        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        // Only a connector that exists gets changes queued for sending (a removed one's are kept detached).
        try store.db.run("INSERT OR IGNORE INTO connectors(id,name,settings_json) VALUES('email','email','{}')")
        guard let c1 = connectorCard("email:ob1") else { check(false, "outbox setup"); return }
        try store.db.run("UPDATE cards SET source_sent='2026-11-01T10:00:00Z' WHERE id=?", [c1.id])
        store.reload()
        let c1b = store.card(c1.id)!
        store.move(c1b, to: .done, now: t0)
        let rows = outboxRows()
        check(rows.count == 1 && rows[0].kind == "done" && rows[0].payload["source_mid"] == "ob1"
              && rows[0].payload["source_sent"] == "2026-11-01T10:00:00Z" && rows[0].payload["item_id"] == "item-1"
              && rows[0].payload["at"] != nil, "done_on_connector_card_queues_outbox")

        try store.db.run("DELETE FROM outbox")
        store.add(title: "Plain", area: "Personal", importance: .medium, due: nil)
        let plain = store.cards.first { $0.title == "Plain" }!
        store.move(plain, to: .done, now: t0)
        store.setArea(plain, "Work", now: t0)
        store.deleteCard(plain, verdict: nil, now: t0)
        check(outboxRows().isEmpty, "plain_card_queues_nothing")

        guard let c2 = connectorCard("email:ob2", item: "item-2") else { check(false, "outbox setup 2"); return }
        try store.db.run("UPDATE cards SET proposal_json=? WHERE id=?", ["{\"area\":\"Personal\"}", c2.id])
        store.deleteCard(c2, verdict: "not_action", now: t0)
        let rows2 = outboxRows()
        let corr = try store.db.query("SELECT connector, source_mid, proposed_json, verdict FROM corrections") {
            (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2), DB.text($0, 3)) }
        check(rows2.count == 1 && rows2[0].kind == "deleted" && rows2[0].payload["verdict"] == "not_action"
              && rows2[0].payload["item_id"] == "item-2" && corr.count == 1 && corr[0].0 == "email"
              && corr[0].1 == "ob2" && corr[0].2 == "{\"area\":\"Personal\"}" && corr[0].3 == "not_action"
              && store.card(c2.id) == nil, "delete_with_verdict_records_correction_and_outbox")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let cd = connectorCard("email:obd", item: "item-d") else { check(false, "outbox setup dup"); return }
        store.deleteCard(cd, verdict: "duplicate", now: t0)
        let rowsD = outboxRows()
        check(rowsD.count == 1 && rowsD[0].kind == "deleted" && rowsD[0].payload["verdict"] == "duplicate"
              && rowsD[0].payload["source_mid"] == "obd" && store.card(cd.id) == nil, "duplicate_delete_tells_the_connector")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c3 = connectorCard("email:ob3", item: "item-3") else { check(false, "outbox setup 3"); return }
        store.setArea(c3, "Work", now: t0)
        store.setImportance(store.card(c3.id)!, .high, now: t0.addingTimeInterval(3))
        store.setArea(store.card(c3.id)!, "Acme-x", now: t0.addingTimeInterval(6))
        let rows3 = outboxRows()
        let nCorr = try store.db.query("SELECT count(*) FROM corrections") { DB.int($0, 0) }
        check(rows3.count == 1 && rows3[0].kind == "changed"
              && (rows3[0].payload["detail"] ?? "").contains("group: Personal → ")
              && (rows3[0].payload["detail"] ?? "").contains("importance: Medium → High")
              && !(rows3[0].payload["detail"] ?? "").contains("Work")
              && nCorr == [1], "rapid_changes_collapse")
        store.setImportance(store.card(c3.id)!, .low, now: t0.addingTimeInterval(60))
        check(outboxRows().count == 2, "changes_more_than_5s_apart_stay_separate")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c4 = connectorCard("email:ob4", item: "item-4") else { check(false, "outbox setup 4"); return }
        let origArea = c4.area
        store.setArea(c4, "Work", now: t0)
        check(outboxRows().count == 1, "change_queued_first")
        store.setArea(store.card(c4.id)!, origArea, now: t0.addingTimeInterval(2))
        let nCorr4 = try store.db.query("SELECT count(*) FROM corrections") { DB.int($0, 0) }
        check(outboxRows().isEmpty && nCorr4 == [0],
              "change_back_to_original_queues_nothing")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c5 = connectorCard("email:ob5", item: "item-5") else { check(false, "outbox setup 5"); return }
        store.move(c5, to: .done, now: t0)
        store.deleteCard(store.card(c5.id)!, verdict: nil, now: t0)
        let ids = outboxRows().map(\.uuid)
        check(ids.count == 2, "done_then_delete_queues_two")
        let pend = store.pendingOutbox(connector: "email", limit: 10, now: t0)
        check(pend.count == 2 && pend[0].kind == .done && pend[1].kind == .deleted && pend[0].attempts == 0
              && store.waitingCount(connector: "email") == 2 && store.waitingCount(connector: "other") == 0,
              "pending_outbox_oldest_first")
        store.markFailed([ids[0]], error: "offline", now: t0)
        var after = store.pendingOutbox(connector: "email", limit: 10, now: t0.addingTimeInterval(10))
        check(after.count == 1 && after[0].uuid == ids[1], "failed_item_hidden_until_next_try")
        after = store.pendingOutbox(connector: "email", limit: 10, now: t0.addingTimeInterval(31))
        let failedRow = after.first { $0.uuid == ids[0] }
        let backedOff: Bool = failedRow.map { r -> Bool in
            let delay: Double = abs(r.nextTry.timeIntervalSince(t0) - 30)
            return r.attempts == 1 && r.lastError == "offline" && delay < 0.01
        } ?? false
        check(after.count == 2 && backedOff, "failed_send_backs_off_30s")
        check(store.trace(ids[0]).contains { $0.level == .warning }, "failed_send_logs_activity_with_trace")
        for _ in 0..<3 { store.markFailed([ids[0]], error: "offline", now: t0) }
        check(store.pendingOutbox(connector: "email", limit: 10, now: t0.addingTimeInterval(239)).count == 1
              && store.pendingOutbox(connector: "email", limit: 10, now: t0.addingTimeInterval(241)).count == 2,
              "failed_send_attempt4_backs_off_240s")
        for _ in 0..<10 { store.markFailed([ids[0]], error: "offline", now: t0) }
        let nt = try store.db.query("SELECT next_try FROM outbox WHERE uuid=?", [ids[0]]) { sqlite3_column_double($0, 0) }
        check(nt == [t0.timeIntervalSince1970 + 3600], "failed_send_backoff_capped_at_3600s")

        store.markSent([ids[1]], now: t0)
        check(store.waitingCount(connector: "email") == 1, "mark_sent_removes_from_waiting")

        let reopened = try DB()
        let n = try reopened.query("SELECT count(*) FROM outbox WHERE sent IS NULL") { DB.int($0, 0) }
        check(n == [1], "outbox_survives_reopen")
    } catch { check(false, "outbox checks: \(error)") }

    // Stale snapshots, atomicity, activity surviving rollback, double delete
    do {
        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c6 = connectorCard("email:ob6", item: "item-6") else { check(false, "outbox setup 6"); return }
        store.setArea(c6, "Work", now: t0)
        store.setImportance(c6, .high, now: t0.addingTimeInterval(1)) // stale snapshot: still shows the old group
        let r6 = outboxRows()
        let d6 = r6.first?.payload["detail"] ?? ""
        check(r6.count == 1 && d6.contains("group: ") && d6.contains("importance: Medium → High"),
              "stale_snapshot_changes_keep_both_fields")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c7 = connectorCard("email:ob7", item: "item-7") else { check(false, "outbox setup 7"); return }
        store.setArea(c7, "Work", now: t0)
        store.setImportance(c7, .high, now: t0.addingTimeInterval(1))
        store.setArea(c7, c7.area, now: t0.addingTimeInterval(2)) // group back to original; importance still changed
        let r7 = outboxRows()
        let d7 = r7.first?.payload["detail"] ?? ""
        check(r7.count == 1 && d7.contains("importance: Medium → High") && !d7.contains("group:"),
              "change_back_after_other_field_change_keeps_row")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c8 = connectorCard("email:ob8", item: "item-8") else { check(false, "outbox setup 8"); return }
        try store.db.run("CREATE TEMP TRIGGER fail_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'forced outbox failure'); END")
        store.move(c8, to: .done, now: t0)
        try store.db.run("DROP TRIGGER fail_outbox")
        check(store.card(c8.id)?.status == .todo && outboxRows().isEmpty, "outbox_failure_rolls_back_board_change")
        let hasErr = store.recentActivity(limit: 20).contains { (e: ActivityEntry) -> Bool in
            e.level == .error && (e.detail ?? "").contains("forced outbox failure") }
        check(hasErr,
              "outbox_failure_writes_activity_error")

        store.performForTest { store.activity("checks", .info, "logged inside transaction", trace: "tx-1"); throw DBError.sql("fail") }
        check(store.trace("tx-1").map(\.message) == ["logged inside transaction"], "activity_in_failed_transaction_survives")

        try store.db.run("DELETE FROM outbox"); try store.db.run("DELETE FROM corrections")
        guard let c9 = connectorCard("email:ob9", item: "item-9") else { check(false, "outbox setup 9"); return }
        store.deleteCard(c9, verdict: nil, now: t0)
        store.deleteCard(c9, verdict: nil, now: t0.addingTimeInterval(1))
        let nDel = try store.db.query("SELECT count(*) FROM events WHERE card_id=? AND kind='deleted'", [c9.id]) { DB.int($0, 0) }
        check(nDel == [1] && outboxRows().count == 1, "second_delete_is_a_noop")
    } catch { check(false, "outbox atomicity checks: \(error)") }


    // Backups
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: bkDir, isDirectory: true)
        try? fm.removeItem(at: root) // try?-ok: scratch dir may not exist yet
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
        func integrityOK(_ u: URL) -> Bool {
            var h: OpaquePointer?
            defer { sqlite3_close(h) }
            guard sqlite3_open_v2(u.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
            var st: OpaquePointer?
            defer { sqlite3_finalize(st) }
            guard sqlite3_prepare_v2(h, "PRAGMA integrity_check", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { return false }
            return String(cString: sqlite3_column_text(st, 0)) == "ok"
        }

        store.add(title: "Backup me", area: "Personal", importance: .medium, due: nil)
        let b = Backups(dbURL: store.db.url, dir: root.appendingPathComponent("one"))
        let snap = try b.snapshot(reason: "manual", now: now)
        check(integrityOK(snap) && snap.lastPathComponent == "board-20261107-120000-manual.sqlite"
              && b.list().map(\.url.lastPathComponent) == [snap.lastPathComponent] && b.list().first?.reason == "manual", "snapshot_is_verified")

        // 400 daily snapshots, one per day at 03:00, then rotate
        let rot = Backups(dbURL: store.db.url, dir: root.appendingPathComponent("rot"))
        for d in 0..<400 {
            let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: now))!
            let at = cal.date(byAdding: .hour, value: 3, to: day)!
            _ = try rot.snapshot(reason: "daily", now: at)
        }
        let tiers = rot.tierKeeps(now: now)
        try rot.rotate(now: now)
        let left = Set(rot.list().map(\.url.lastPathComponent))
        let union = tiers.day.union(tiers.week).union(tiers.month)
        check(tiers.day.count == 14 && tiers.week.count == 8 && tiers.month.count == 12
              && left == Set(union.map(\.lastPathComponent)) && left.count == union.count, "rotation_keeps_14_daily_8_weekly_12_monthly")
        check(left.count < 14 + 8 + 12 && left.count > 14, "rotation_counts_overlap_once")

        // non-daily snapshots survive 90 days, then go
        let rs = Backups(dbURL: store.db.url, dir: root.appendingPathComponent("reason"))
        let young = try rs.snapshot(reason: "pre-migrate", now: now.addingTimeInterval(-89 * 86400))
        let old = try rs.snapshot(reason: "pre-migrate", now: now.addingTimeInterval(-91 * 86400))
        try rs.rotate(now: now)
        check(fm.fileExists(atPath: young.path) && !fm.fileExists(atPath: old.path), "reason_snapshots_kept_90_days")

        // restore: current DB is snapshotted first, then replaced
        let rdb = root.appendingPathComponent("restore.sqlite")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: snap, to: rdb)
        let rb = Backups(dbURL: rdb, dir: root.appendingPathComponent("rest"))
        let good = try rb.snapshot(reason: "daily", now: now.addingTimeInterval(-3600))
        let rdbDB = try DB(url: rdb)
        try rdbDB.run("INSERT INTO areas(name,color,position) VALUES('AfterBackup','#000000',99)")
        try rb.restore(good)
        let areas = try DB(url: rdb).query("SELECT name FROM areas") { DB.text($0, 0) }
        let pre = rb.list().filter { $0.reason == "pre-restore" }
        var preHas = false
        if let p = pre.first { preHas = (try DB(url: p.url).query("SELECT name FROM areas") { DB.text($0, 0) }).contains("AfterBackup") }
        check(!areas.contains("AfterBackup") && pre.count == 1 && preHas && integrityOK(rdb), "restore_snapshots_current_first")

        // schema version gates the pre-migrate backup (older versions: see schemaChecks)
        check(!Backups.migrationCheck(store.db.url).needed, "current_db_needs_no_backup")
        check(!Backups.migrationCheck(root.appendingPathComponent("absent.sqlite")).needed, "missing_db_needs_no_backup")
        let junk = root.appendingPathComponent("junk.sqlite")
        try Data("this is not a database, just text padding padding padding".utf8).write(to: junk)
        let jc = Backups.migrationCheck(junk)
        check(jc.needed && jc.problem != nil, "unreadable_db_counts_as_needs_migration")
        let jb = Backups(dbURL: junk, dir: root.appendingPathComponent("junkbk"))
        var junkThrew = false
        do { try jb.snapshot(reason: "daily", now: now) } catch { junkThrew = true }
        check(junkThrew && jb.list().isEmpty, "failed_snapshot_leaves_no_file")

        // restore still works when the current DB is corrupt
        let cdb = root.appendingPathComponent("corrupt-current.sqlite")
        try fm.copyItem(at: snap, to: cdb)
        let cb = Backups(dbURL: cdb, dir: root.appendingPathComponent("corruptbk"))
        let healthy = try cb.snapshot(reason: "daily", now: now.addingTimeInterval(-60))
        try Data("garbage garbage garbage".utf8).write(to: cdb)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: cdb.path + "-journal"))
        try cb.restore(healthy)
        check(integrityOK(cdb) && cb.list().contains { $0.reason == "pre-restore" }
              && !fm.fileExists(atPath: cdb.path + "-journal"), "restore_works_when_current_db_corrupt")

        // a daily snapshot dated in the future (clock skew) is kept
        let sk = Backups(dbURL: store.db.url, dir: root.appendingPathComponent("skew"))
        let future = try sk.snapshot(reason: "daily", now: now.addingTimeInterval(3 * 86400))
        try sk.rotate(now: now)
        check(fm.fileExists(atPath: future.path), "future_daily_snapshot_kept")

        // an unwritable backups dir is logged, not fatal
        let bad = Backups(dbURL: store.db.url, dir: URL(fileURLWithPath: "/dev/null/nope"))
        let res = store.takeBackup(bad, reason: "daily", now: now)
        check(res == nil && store.recentActivity(limit: 3).contains { $0.level == .error && $0.component == "backup" }, "backup_failure_logged")
    } catch { check(false, "backup checks: \(error)") }


    // Reconciler
    @MainActor func prop(_ id: String, _ mid: String?, _ sent: String = "2026-11-01T09:00:00Z", kind: ProposalKind = .task,
              title: String = "Task", why: String = "because", due: String? = nil, group: String? = "Work",
              importance: Int = 1, summary: String? = nil, taskRef: String? = nil, learned: String? = nil) -> Proposal {
        Proposal(id: id, kind: kind, sourceKey: mid.map { SourceKey(messageID: $0, sentAt: sent) }, title: title,
                 why: why, due: due, hasTime: due?.contains("T") ?? false, group: group, importance: importance,
                 sourceLabel: "Inbox", link: "https://mail/\(mid ?? "x")", summary: summary, taskRef: taskRef, learned: learned,
                 provenance: Provenance(model: "m", skillVersion: "1", created: "2026-11-01T09:00:00Z"))
    }
    @MainActor func rcard(_ c: String, _ mid: String, _ sent: String = "2026-11-01T09:00:00Z") -> Card? {
        store.cards.first { $0.connector == c && $0.sourceKey == SourceKey(messageID: mid, sentAt: sent) }
    }
    @MainActor func rcount(_ c: String, _ mid: String) -> Int {
        ((try? store.db.query("SELECT count(*) FROM cards WHERE connector=? AND source_mid=?", [c, mid]) { DB.int($0, 0) })?.first).map { Int($0) } ?? -1 // try?-ok: a failed query makes the check fail
    }
    @MainActor func revents(_ id: Int64) -> [(String, String)] {
        (try? store.db.query("SELECT kind, actor FROM events WHERE card_id=? ORDER BY id", [id]) { (DB.text($0, 0), DB.text($0, 1)) }) ?? [] // try?-ok: a failed query makes the check fail
    }
    @MainActor func outboxCount() -> Int {
        ((try? store.db.query("SELECT count(*) FROM outbox") { DB.int($0, 0) })?.first).map { Int($0) } ?? -1 // try?-ok: a failed query makes the check fail
    }
    do {
        let r1 = try Reconciler.apply([prop("p1", "m1", title: "Reply to Bob", due: "2026-11-12", importance: 2)],
                                      connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let c1 = rcard("rc", "m1")
        check(r1.added == 1 && c1?.title == "Reply to Bob" && c1?.area == "Work" && c1?.importance == .high
              && c1?.connector == "rc" && c1?.status == .todo, "new_proposal_added_with_connector_actor")
        if let c = c1 {
            let ev = revents(c.id)
            check(!ev.isEmpty && ev.allSatisfy { $0.1 == "connector:rc" } && !store.isTouched(c.id), "reconciler_history_is_connector_actor")
            check(c.sourceKey?.sentAt == "2026-11-01T09:00:00Z" && !c.withdrawn, "added_card_has_source_key")
        }
        check(store.trace("p1").contains { $0.component == "reconciler" }, "reconciler_activity_traced_by_proposal_id")
        let r2 = try Reconciler.apply([prop("p1", "m1", title: "Reply to Bob", due: "2026-11-12", importance: 2)],
                                      connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(rcount("rc", "m1") == 1 && r2.added == 0, "same_proposal_twice_one_card")
        let r3 = try Reconciler.apply([prop("p2a", "m2"), prop("p2b", "m2")], connector: "rc", store: store,
                                      defaultGroup: "Personal", autoAdd: true)
        check(rcount("rc", "m2") == 1 && r3.added == 1, "same_email_two_inboxes_one_card")
        let r3b = try Reconciler.apply([prop("p3", "m3")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: false)
        check(rcount("rc", "m3") == 0 && r3b.added == 0, "auto_add_off_adds_nothing")

        // deleted card blocks
        if let m2 = rcard("rc", "m2") { store.delete(m2) }
        let r4 = try Reconciler.apply([prop("p2c", "m2", title: "Changed")], connector: "rc", store: store,
                                      defaultGroup: "Personal", autoAdd: true)
        check(rcount("rc", "m2") == 1 && r4.added == 0 && r4.skippedExisting == 1, "deleted_card_blocks_new_proposal")

        // untouched refreshed
        let r5 = try Reconciler.apply([prop("p1b", "m1", title: "Reply to Bob today", why: "new why", due: "2026-11-13T15:30",
                                            group: "Personal", importance: 0)], connector: "rc", store: store,
                                      defaultGroup: "Personal", autoAdd: true)
        let c5 = rcard("rc", "m1")
        check(r5.refreshed == 1 && c5?.title == "Reply to Bob today" && c5?.area == "Personal" && c5?.importance == .low
              && c5?.due == Reconciler.parseDue("2026-11-13T15:30") && c5?.sourceMeta["why"] == "new why", "untouched_card_refreshed")
        let pj = (try? store.db.query("SELECT proposal_json FROM cards WHERE id=?", [c5?.id ?? 0]) { DB.text($0, 0) })?.first ?? "" // try?-ok: failed query fails the check
        check(pj.contains("\"id\":\"p1b\"") && pj.contains("skill_version"), "refresh_stores_proposal_json")
        check(c5.map { revents($0.id).contains { $0.0.hasPrefix("refreshed") && $0.1 == "connector:rc" } } ?? false, "refresh_recorded_in_history")

        // touched never changed
        if let c = c5 { store.move(c, to: .doing) }
        let before = rcard("rc", "m1")
        let r6 = try Reconciler.apply([prop("p1c", "m1", title: "Overwrite!", due: "2026-12-01", group: "Work", importance: 2)],
                                      connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let after = rcard("rc", "m1")
        check(r6.keptTouched == 1 && r6.refreshed == 0 && after == before, "touched_card_never_changed")
        _ = try Reconciler.apply([prop("p1c", "m1", title: "Overwrite!")], connector: "rc", store: store,
                                 defaultGroup: "Personal", autoAdd: true)
        check(after.map { revents($0.id).filter { $0.0.hasPrefix("update ignored") }.count } == 1, "kept_touched_logged_once")

        // withdraw
        _ = try Reconciler.apply([prop("p4", "m4")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let r7 = try Reconciler.apply([prop("p4w", "m4", kind: .withdraw)], connector: "rc", store: store,
                                      defaultGroup: "Personal", autoAdd: true)
        let c7 = rcard("rc", "m4")
        check(r7.withdrawn == 1 && c7?.withdrawn == true && rcount("rc", "m4") == 1
              && (c7.map { revents($0.id).contains { $0 == ("withdrawn by connector", "connector:rc") } } ?? false),
              "withdraw_hides_untouched_keeps_row_and_history")
        let r8 = try Reconciler.apply([prop("p1w", "m1", kind: .withdraw)], connector: "rc", store: store,
                                      defaultGroup: "Personal", autoAdd: true)
        check(r8.withdrawn == 0 && r8.keptTouched == 1 && rcard("rc", "m1")?.withdrawn == false, "withdraw_ignores_touched")

        // summary
        let r9 = try Reconciler.apply([prop("p1s", nil, kind: .summary, summary: "Bob wants the deck", taskRef: "card:\(after?.id ?? 0)"),
                                       prop("p4s", "m4", kind: .summary, summary: "By source key")],
                                      connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let c9 = rcard("rc", "m1")
        check(r9.summaries == 2 && c9?.aiSummary == "Bob wants the deck" && c9?.notes == "" && rcard("rc", "m4")?.aiSummary == "By source key",
              "summary_goes_to_ai_summary_not_notes")
        let r9b = try Reconciler.apply([prop("p1s", nil, kind: .summary, summary: "Bob wants the deck", taskRef: "card:\(after?.id ?? 0)")],
                                       connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(r9b.summaries == 0 && rcard("rc", "m1")?.aiSummary == "Bob wants the deck", "summary_not_appended_twice")
        // Meeting notes with no linked card are ignored quietly: noted in Activity, not raised as a warning.
        _ = try Reconciler.apply([prop("p9n", nil, kind: .summary, summary: "Notes for an unlinked meeting")],
                                 connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let noted = store.recentActivity(limit: 5).first { $0.message.hasPrefix("Meeting notes not attached") }
        check(noted?.level == .info, "unlinked_meeting_notes_ignored_quietly")

        // unknown group
        _ = try Reconciler.apply([prop("p5", "m5", group: "Nonexistent"), prop("p6", "m6", group: "work"), prop("p7", "m7", group: nil)],
                                 connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(rcard("rc", "m5")?.area == "Personal" && rcard("rc", "m6")?.area == "Work" && rcard("rc", "m7")?.area == "Personal",
              "unknown_group_uses_default")

        // learned
        let r10 = try Reconciler.apply([prop("pl", nil, kind: .learned, learned: "Prefers short titles\nIgnore newsletters")],
                                       connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(r10.learnedUpdates == 1 && store.learned(connector: "rc") == "Prefers short titles\nIgnore newsletters", "learned_saved")
        let r11 = try Reconciler.apply([prop("pl2", nil, kind: .learned, learned: "Prefers short titles\nAlways High for Anna")],
                                       connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let lrows = store.trace("pl2")
        check(r11.learnedUpdates == 1 && lrows.contains { $0.message.hasPrefix("Learned:") && $0.message.contains("+Always High for Anna")
              && $0.message.contains("-Ignore newsletters") && !$0.message.contains("+Prefers") }, "learned_saved_and_logged")
        try store.db.run("UPDATE connectors SET settings_json=? WHERE id='rc'", ["{\"other\":\"keep\",\"learned\":\"x\"}"])
        store.setLearned(connector: "rc", text: "y")
        let sj = (try? store.db.query("SELECT settings_json FROM connectors WHERE id='rc'") { DB.text($0, 0) })?.first ?? "" // try?-ok: failed query fails the check
        check(sj.contains("\"other\"") && sj.contains("\"learned\":\"y\""), "set_learned_preserves_other_settings_keys")

        // corrections
        let cardsBefore = store.cards.count
        let r12 = try Reconciler.apply([prop("pc1", "mc1", kind: .correction, why: "missed_action", summary: "Please send the signed form by Friday")],
                                       connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let r12b = try Reconciler.apply([prop("pc1", "mc1", kind: .correction, why: "missed_action", summary: "Please send the signed form by Friday")],
                                        connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let crow = (try? store.db.query("SELECT connector,source_mid,source_sent,verdict,detail,proposed_json FROM corrections WHERE uuid='pc1'") { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2), DB.text($0, 3), DB.text($0, 4), DB.text($0, 5)) }) ?? [] // try?-ok: failed query fails the check
        let ccount = (try? store.db.query("SELECT count(*) FROM corrections WHERE uuid='pc1'") { DB.int($0, 0) })?.first ?? 0 // try?-ok: failed query fails the check
        check(r12.corrections == 1 && r12b.corrections == 0 && ccount == 1 && crow.first?.0 == "rc" && crow.first?.1 == "mc1"
              && crow.first?.3 == "missed_action" && crow.first?.4 == "Please send the signed form by Friday"
              && crow.first?.5.contains("\"id\":\"pc1\"") == true && rcount("rc", "mc1") == 0 && store.cards.count == cardsBefore
              && store.trace("pc1").contains { $0.message == "Learned from a missed email" }, "correction_stored_idempotent_no_card")

        // withdrawn card restored when the source re-proposes it (untouched only)
        _ = try Reconciler.apply([prop("rw1", "mrw")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        _ = try Reconciler.apply([prop("rw1w", "mrw", kind: .withdraw)], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let wasW = rcard("rc", "mrw")?.withdrawn
        let r14 = try Reconciler.apply([prop("rw2", "mrw", title: "Back again")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let c14 = rcard("rc", "mrw")
        check(wasW == true && r14.refreshed == 1 && c14?.withdrawn == false && c14?.title == "Back again"
              && (c14.map { revents($0.id).contains { $0 == ("restored by connector", "connector:rc") } } ?? false), "task_restores_untouched_withdrawn_card")
        _ = try Reconciler.apply([prop("rt1", "mrt")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        if let t = rcard("rc", "mrt") { store.setImportance(t, .high) }
        try store.db.run("UPDATE cards SET withdrawn=1 WHERE connector='rc' AND source_mid='mrt'")
        store.reload()
        let r15 = try Reconciler.apply([prop("rt2", "mrt", title: "Nope")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        check(r15.keptTouched == 1 && rcard("rc", "mrt")?.withdrawn == true && rcard("rc", "mrt")?.title == "Task", "touched_withdrawn_card_stays_withdrawn")

        // Bad input from the engine never erases or corrupts what is stored
        let learnedBefore = store.learned(connector: "rc")
        let r20 = try Reconciler.apply([prop("pl3", nil, kind: .learned, learned: nil)], connector: "rc", store: store,
                                       defaultGroup: "Personal", autoAdd: true)
        check(r20.learnedUpdates == 0 && !learnedBefore.isEmpty && store.learned(connector: "rc") == learnedBefore
              && store.trace("pl3").contains { $0.level == .warning }, "learned_without_text_is_ignored_not_erased")

        _ = try Reconciler.apply([prop("fd1", "mfd", due: "2026-12-01")], connector: "rc", store: store, defaultGroup: "Personal", autoAdd: true)
        let dueBefore = rcard("rc", "mfd")?.due
        let r21 = try Reconciler.apply([prop("fd2", "mfd", due: "next tuesday-ish")], connector: "rc", store: store,
                                       defaultGroup: "Personal", autoAdd: true)
        check(dueBefore != nil && r21.refreshed == 0 && rcard("rc", "mfd")?.due == dueBefore
              && store.trace("fd2").contains { $0.level == .warning }, "unreadable_due_keeps_existing_due")

        try store.db.run("""
            INSERT INTO cards(title,area,importance,status,created,connector,source_mid,source_sent,source_link,source_meta)
            VALUES('Task','Work',1,'todo',?,'rm','mm','S','https://mail/mm','{"z":"1","why":"because","n":5}')
            """, [Date()])
        store.reload()
        let r22 = try Reconciler.apply([prop("fm1", "mm", "S")], connector: "rm", store: store, defaultGroup: "Personal", autoAdd: true)
        check(r22.refreshed == 0 && r22.skippedExisting == 1, "unsorted_legacy_meta_is_not_a_change")
        let r23 = try Reconciler.apply([prop("fm2", "mm", "S", title: "Task renamed")], connector: "rm", store: store,
                                       defaultGroup: "Personal", autoAdd: true)
        let mj = (try? store.db.query("SELECT source_meta FROM cards WHERE source_mid='mm'") { DB.text($0, 0) })?.first ?? "" // try?-ok: failed query fails the check
        check(r23.refreshed == 1 && mj.contains("\"n\":5") && mj.contains("\"z\":\"1\""), "refresh_keeps_non_string_meta_keys")

        let r24 = try Reconciler.apply([prop("ss2", "m4", kind: .summary, summary: "source")], connector: "rc", store: store,
                                       defaultGroup: "Personal", autoAdd: true)
        let r24b = try Reconciler.apply([prop("p4s", "m4", kind: .summary, summary: "By source key"),
                                         prop("ss2", "m4", kind: .summary, summary: "source")], connector: "rc", store: store,
                                        defaultGroup: "Personal", autoAdd: true)
        check(r24.summaries == 1 && r24b.summaries == 0 && rcard("rc", "m4")?.aiSummary == "By source key\n\nsource",
              "summary_dedupe_by_proposal_id_not_substring")

        let batchJSON = """
        [{"id":"ok1","kind":"task","source_key":{"message_id":"bk1","sent_at":"s"},"title":"Fine","provenance":{"model":"m","skill_version":"1","created":"c"}},
         {"id":"bad1","kind":"task","source_key":{"message_id":"bk2","sent_at":"s"},"title":"No skill","provenance":{"model":"m","created":"c"}},
         {"id":"bad2","kind":"withdraw","source_key":null,"provenance":{"model":"m","skill_version":"1","created":"c"}},
         {"kind":"task","source_key":{"message_id":"bk3","sent_at":"s"},"provenance":{"model":"m","skill_version":"1","created":"c"}},
         {"id":"ok2","kind":"learned","learned":"x","provenance":{"model":"m","skill_version":"1","created":"c"}}]
        """
        let decoded = try Reconciler.decodeBatch(Data(batchJSON.utf8), store: store)
        let warns = store.recentActivity(limit: 20).filter { $0.level == .warning && $0.message.hasPrefix("Proposal rejected") }
        check(decoded.map(\.id) == ["ok1", "ok2"] && warns.count == 3
              && store.trace("bad1").contains { $0.message.contains("skill_version") }
              && store.trace("bad2").contains { $0.message.contains("source_key") }
              && warns.contains { $0.message.contains("id") && $0.trace == nil }, "malformed_proposals_rejected_rest_applied")

        // card from before send dates (source_sent NULL) matched on connector + mid, sent date filled in
        if let legacy = store.card(externalID: "email:newmid") {
            let r13 = try Reconciler.apply([prop("pg", "newmid", "2026-10-05T08:00:00Z", title: "Mail refreshed")], connector: "email",
                                           store: store, defaultGroup: "Personal", autoAdd: true)
            let sent = (try? store.db.query("SELECT source_sent FROM cards WHERE id=?", [legacy.id]) { DB.text($0, 0) })?.first // try?-ok: failed query fails the check
            check(rcount("email", "newmid") == 1 && r13.added == 0 && sent == "2026-10-05T08:00:00Z"
                  && !store.isTouched(legacy.id) && store.card(legacy.id)?.title == "Mail refreshed", "legacy_card_matched_and_sent_filled")
        } else { check(false, "legacy_card_matched_and_sent_filled") }

        // exact summary for a mixed batch
        _ = try Reconciler.apply([prop("ma", "ma", title: "A"), prop("mb", "mb", title: "B"), prop("mc", "mc", title: "C"),
                                  prop("me", "me", title: "E")], connector: "mx", store: store, defaultGroup: "Personal", autoAdd: true)
        if let b = rcard("mx", "mb"), let e = rcard("mx", "me") { store.move(b, to: .doing); store.delete(e) }
        let ob0 = outboxCount()   // user moves/deletes above legitimately queued rows; reconciling must add none
        let mixed = try Reconciler.apply([
            prop("x1", "ma", title: "A2"), prop("x2", "mb", title: "B2"), prop("x3", "mc", kind: .withdraw),
            prop("x4", "md", title: "D"), prop("x5", "me", title: "E2"),
            prop("x6", nil, kind: .summary, summary: "s", taskRef: "card:\(rcard("mx", "ma")?.id ?? 0)"),
            prop("x7", nil, kind: .learned, learned: "L"), prop("x8", "ma", kind: .correction, why: "missed_action", summary: "n"),
        ], connector: "mx", store: store, defaultGroup: "Personal", autoAdd: true)
        check(mixed == ReconcileSummary(added: 1, refreshed: 1, withdrawn: 1, keptTouched: 1, skippedExisting: 1,
                                        summaries: 1, learnedUpdates: 1, corrections: 1), "summary_counts_match")
        check(outboxCount() == ob0, "reconciler_queues_no_outbox_rows")

        // atomic: a failure rolls back the whole batch and is logged
        let bad = [prop("z1", "z1m"), prop("zl", nil, kind: .learned, learned: "ZZ-rolled-back"), prop("z2", "z2m")]
        try store.db.run("CREATE TRIGGER fail_z2 BEFORE INSERT ON cards WHEN NEW.source_mid='z2m' BEGIN SELECT RAISE(ABORT,'boom'); END")
        var threw = false
        do { _ = try Reconciler.apply(bad, connector: "rz", store: store, defaultGroup: "Personal", autoAdd: true) } catch { threw = true }
        try store.db.run("DROP TRIGGER fail_z2")
        check(threw && rcount("rz", "z1m") == 0 && store.recentActivity(limit: 5).contains { $0.component == "reconciler" && $0.level == .error },
              "reconciler_failure_rolls_back_and_logs")
        let ghost = store.recentActivity(limit: 50).contains { $0.message.hasPrefix("Added:") && $0.trace == "z1" || $0.message.hasPrefix("Learned:") && $0.detail == "ZZ-rolled-back" }
        check(!ghost && store.learned(connector: "rz").isEmpty, "rollback_discards_success_rows")
    } catch { check(false, "reconciler checks: \(error)") }

    // Proposal JSON and due conversion
    let sample = """
    {"id":"p-9","kind":"task","source_key":{"message_id":"abc123","sent_at":"2026-11-02T10:15:00Z"},"title":"Send deck",
     "why":"Anna asked","due":"2026-11-12T14:00","has_time":true,"group":"Work","importance":2,"source_label":"Inbox: Anna",
     "link":"https://mail.example/abc123","summary":null,"task_ref":null,"learned":null,
     "provenance":{"model":"sonnet","skill_version":"3","created":"2026-11-02T10:16:00Z"}}
    """
    do {
        let p = try JSONDecoder().decode(Proposal.self, from: Data(sample.utf8))
        check(p.id == "p-9" && p.kind == .task && p.sourceKey == SourceKey(messageID: "abc123", sentAt: "2026-11-02T10:15:00Z")
              && p.hasTime && p.importance == 2 && p.sourceLabel == "Inbox: Anna" && p.provenance.skillVersion == "3"
              && p.summary == nil && p.taskRef == nil, "proposal_decodes_engine_json")
        let nul = try JSONDecoder().decode(Proposal.self, from: Data("""
            {"id":"w","kind":"learned","source_key":null,"title":"","why":"","due":null,"has_time":false,"group":null,
             "importance":1,"source_label":"","link":"","summary":null,"task_ref":null,"learned":"x",
             "provenance":{"model":"m","skill_version":"1","created":"c"}}
            """.utf8))
        check(nul.sourceKey == nil && nul.learned == "x" && nul.kind == .learned, "proposal_decodes_null_source_key")
    } catch { check(false, "proposal_decodes_engine_json: \(error)") }
    func utc(_ d: Date?) -> String {
        guard let d else { return "nil" }
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d)
    }
    let europe = TimeZone(identifier: "Europe/Berlin")!, tokyo = TimeZone(identifier: "Asia/Tokyo")!, newYork = TimeZone(identifier: "America/New_York")!
    check(utc(Reconciler.parseDue("2026-11-12", in: europe)) == "2026-11-11T23:00:00Z", "due_date_only_is_local_midnight_winter")
    check(utc(Reconciler.parseDue("2026-07-01", in: europe)) == "2026-06-30T22:00:00Z", "due_date_only_is_local_midnight_summer")
    check(utc(Reconciler.parseDue("2026-07-01T09:00", in: europe)) == "2026-07-01T07:00:00Z", "due_time_local_summer")
    check(utc(Reconciler.parseDue("2026-11-12T14:00", in: europe)) == "2026-11-12T13:00:00Z", "due_time_local_winter")
    check(utc(Reconciler.parseDue("2026-07-01T09:00", in: newYork)) == "2026-07-01T13:00:00Z", "due_time_other_zone")
    do { // the device's zone is whatever TZ says; switch it for one check, then restore it
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Tokyo", 1); tzset(); NSTimeZone.resetSystemTimeZone()
        check(TimeZone.current == tokyo && utc(Reconciler.parseDue("2026-07-01T09:00")) == "2026-07-01T00:00:00Z", "due_uses_current_time_zone")
        if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }
        tzset(); NSTimeZone.resetSystemTimeZone()
    }
    check(Reconciler.parseDue("garbage") == nil && Reconciler.parseDue("2026-02-30") == nil && Reconciler.parseDue("") == nil, "due_invalid_is_nil")

    // Activity log
    store.activity("checks", .info, "hello", detail: "d", trace: "t-1")
    store.activity("checks", .warning, "other", trace: "t-2")
    store.activity("checks", .info, "again", trace: "t-1")
    let recent = store.recentActivity(limit: 10)
    check(recent.first?.message == "again" && recent.contains { $0.message == "hello" && $0.detail == "d" && !$0.seen },
          "activity_row_written")
    check(store.trace("t-1").map(\.message) == ["hello", "again"], "trace_returns_rows_for_one_id")
    store.performForTest("BAD SQL")
    check(store.recentActivity(limit: 1).first.map { $0.level == .error && $0.component == "store" } ?? false,
          "store_error_logged")
    check(store.lastError != nil, "store_error_sets_last_error")
    do {
        try store.db.run("INSERT INTO activity(at,component,level,message,seen) VALUES(?,?,?,?,0)",
                         [Date().addingTimeInterval(-91 * 86400), "checks", "info", "ancient"])
        store.pruneActivity()
        check(!store.recentActivity(limit: 100).contains { $0.message == "ancient" }
              && store.recentActivity(limit: 100).contains { $0.message == "hello" }, "activity_pruned_after_90_days")
    } catch { check(false, "activity_pruned_after_90_days: \(error)") }
    store.activityMaintenanceFailed("Could not prune activity", DBError.sql("boom"))
    check(store.recentActivity(limit: 5).contains { $0.level == .warning && $0.component == "store"
          && $0.message == "Could not prune activity" && $0.detail == "boom" }, "activity_maintenance_failure_logged")
    store.markActivitySeen(upTo: Date())
    check(store.recentActivity(limit: 100).allSatisfy { $0.seen }, "activity_mark_seen")
}

check(GoogleAuthConfig.scopes == ["https://www.googleapis.com/auth/calendar.events", "openid", "email"]
      && !GoogleAuthConfig.scopes.contains { $0.contains("mail.google") || $0.lowercased().contains("gm" + "ail") }, "google_scopes_calendar_only")

await connectorChecks(sharedStore!)
await connectorsTabChecks(sharedStore!)
await connectorReplaceChecks(sharedStore!)
silentFailureChecks(sharedStore!)
await badStoredDataChecks(sharedStore!)
schemaChecks()
dataModelChecks()
await replyDraftChecks()
await healthChecks()
await recheckChecks()
await connectorEdgeCaseChecks()

print(failures.isEmpty ? "CHECKS OK" : "CHECKS FAILED: \(failures)")
exit(failures.isEmpty ? 0 : 1)
