import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Delete on the phone (sync v2 `delete` / `restore`): applied exactly as a delete on the Mac (connector told, a "teach"
/// reason recorded, the task's calendar event follows the Mac's rules), once, newest change wins, and restore brings it back.
@MainActor func phoneDeleteChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-phonedel-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let store: Store
    do { store = Store(db: try DB(url: root.appendingPathComponent("del.sqlite"))) } catch { check(false, "phone delete setup: \(error)"); return }
    func count(_ sql: String) -> Int64 { ((try? store.db.query(sql) { DB.int($0, 0) }) ?? []).first ?? -1 } // try?-ok: -1 fails the check
    let now = Date()
    store.performForTest("INSERT OR IGNORE INTO connectors(id,name,settings_json) VALUES('email','email','{}')")

    // A task the email sorting made: teach choices; the phone's reason is recorded like the Mac's.
    store.seedCard(title: "PD sorted", importance: .medium, source: "email", externalID: "email:pd1")
    guard let sorted = store.card(externalID: "email:pd1") else { check(false, "phone delete seed"); return }
    store.performForTest("UPDATE cards SET connector='email', source_mid='pd1mid', source_sent='2026-11-01T10:00:00Z' WHERE id=\(sorted.id)")
    store.reload()
    let teachCard = PhoneBoard.payload(store: store, now: now).first { $0.id == sorted.id }
    check(store.card(sorted.id)?.teachOnDelete == true && teachCard?.teachOnDelete == true, "board_copy_says_which_tasks_teach_on_delete")
    let del = PhoneAction(id: "d1", clientID: "pd-del-1", cardID: sorted.id, action: "delete", madeAt: now, teach: "not_action")
    var r = store.applyPhoneActions([del], connector: "ph", now: now)
    let corr = count("SELECT count(*) FROM corrections WHERE source_mid='pd1mid' AND verdict='not_action'")
    let told = count("SELECT count(*) FROM outbox WHERE kind='deleted' AND payload_json LIKE '%pd1mid%'")
    check(r.applied == ["d1"] && store.card(sorted.id) == nil && corr == 1 && told == 1, "phone_delete_applied_with_teach_reason")
    r = store.applyPhoneActions([del], connector: "ph", now: now)
    check(r.applied == ["d1"] && count("SELECT count(*) FROM corrections WHERE source_mid='pd1mid'") == 1
          && count("SELECT count(*) FROM events WHERE card_id=\(sorted.id) AND kind='deleted'") == 1, "phone_delete_applied_once")
    check(store.lastDeleted?.id == sorted.id && store.lastDeleted?.barShown == false, "phone_delete_does_not_show_the_macs_undo_bar")

    // Undo after the delete reached the Mac: restore brings the task back and takes back the unsent connector delete.
    r = store.applyPhoneActions([PhoneAction(id: "r1", clientID: "pd-restore-1", cardID: sorted.id, action: "restore", madeAt: now.addingTimeInterval(1))],
                                connector: "ph", now: now.addingTimeInterval(1))
    check(r.applied == ["r1"] && store.card(sorted.id) != nil && count("SELECT count(*) FROM corrections WHERE source_mid='pd1mid'") == 0
          && count("SELECT count(*) FROM outbox WHERE kind='deleted' AND payload_json LIKE '%pd1mid%'") == 0, "phone_restore_brings_the_task_back")

    // A plain task: a teach reason is ignored (nothing to learn), and a phone delete older than a change on the Mac loses.
    store.add(title: "PD plain", area: "Work", importance: .medium, due: nil)
    guard let plain = store.cards.last(where: { $0.title == "PD plain" }) else { check(false, "phone delete plain seed"); return }
    store.move(plain, to: .doing, now: now.addingTimeInterval(10))
    r = store.applyPhoneActions([PhoneAction(id: "d2", clientID: "pd-del-2", cardID: plain.id, action: "delete", madeAt: now.addingTimeInterval(5))],
                                connector: "ph", now: now.addingTimeInterval(20))
    check(r.skipped.map { $0.reason } == ["superseded"] && store.card(plain.id) != nil, "phone_delete_older_than_a_mac_change_loses")
    r = store.applyPhoneActions([PhoneAction(id: "d3", clientID: "pd-del-3", cardID: plain.id, action: "delete", madeAt: now.addingTimeInterval(30),
                                             teach: "duplicate")], connector: "ph", now: now.addingTimeInterval(31))
    check(r.applied == ["d3"] && store.card(plain.id) == nil && count("SELECT count(*) FROM corrections WHERE verdict='duplicate'") == 0,
          "phone_delete_of_a_plain_task_is_a_plain_delete")
    // Restore after another delete on the Mac (the phone's task is no longer the last deleted) still brings it back.
    store.add(title: "PD other", area: "Work", importance: .medium, due: nil)
    if let other = store.cards.last(where: { $0.title == "PD other" }) { store.delete(other) }
    r = store.applyPhoneActions([PhoneAction(id: "r2", clientID: "pd-restore-2", cardID: plain.id, action: "restore", madeAt: now.addingTimeInterval(40))],
                                connector: "ph", now: now.addingTimeInterval(41))
    check(r.applied == ["r2"] && store.card(plain.id) != nil, "phone_restore_works_when_not_the_last_delete")

    // Round 5. A phone delete's Google event delete waits for the phone's Undo to arrive (the Mac polls the phone every
    // 120 s), so a phone Undo keeps the event; a late phone restore never brings back a task deleted later on the Mac.
    let acct = "me@example.com"
    let cache = CalendarCache(store: store)
    let outbox = CalendarOutbox(store: store)
    cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
    func onCalendar(_ title: String, event: String) -> Int64 {
        store.add(title: title, area: "Work", importance: .medium, due: now.addingTimeInterval(86400), dueHasTime: true)
        let id = store.cards.last { $0.title == title }?.id ?? 0
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(acct)', gcal_event='\(event)' WHERE id=\(id)")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: event, cancelled: false, fields: CalEventFields(
            start: now.addingTimeInterval(86400), end: now.addingTimeInterval(88200), title: title, googleUpdated: now, fbCard: id))], nextToken: nil)
        store.reload()
        return id
    }
    func calKinds() -> [String] { outbox.rows(unsent: true).compactMap { r in r.write.map { w in
        switch w { case .create: "create"; case .patch: "patch"; case .delete: "delete" } } } }
    let t = now.addingTimeInterval(1000)
    let ev = onCalendar("PD meeting prep", event: "pdev1")
    r = store.applyPhoneActions([PhoneAction(id: "d5", clientID: "pd-del-5", cardID: ev, action: "delete", madeAt: t)], connector: "ph", now: t)
    let held = r.applied == ["d5"] && calKinds() == ["delete"] && outbox.due(now: t.addingTimeInterval(130)).isEmpty
        && outbox.due(now: t.addingTimeInterval(Store.phoneCalendarDeleteDelay + 1)).count == 1
    check(held && Store.phoneCalendarDeleteDelay >= ConnectorSync.phonePollInterval + Store.undoBarSeconds + 5, "phone_delete_holds_the_google_delete_for_the_phone_undo")
    r = store.applyPhoneActions([PhoneAction(id: "r5", clientID: "pd-restore-5", cardID: ev, action: "restore", madeAt: t.addingTimeInterval(5))],
                                connector: "ph", now: t.addingTimeInterval(125))
    check(r.applied == ["r5"] && store.card(ev) != nil && calKinds().isEmpty, "phone_undo_within_the_window_keeps_the_event")

    let late = onCalendar("PD offsite", event: "pdev2")
    let t2 = now.addingTimeInterval(2000)
    if let c = store.card(late) { store.deleteCard(c, verdict: nil, now: t2.addingTimeInterval(10)) }   // the owner deletes it on the Mac
    let before = calKinds()
    r = store.applyPhoneActions([PhoneAction(id: "d6", clientID: "pd-del-6", cardID: late, action: "delete", madeAt: t2),
                                 PhoneAction(id: "r6", clientID: "pd-restore-6", cardID: late, action: "restore", madeAt: t2.addingTimeInterval(5))],
                                connector: "ph", now: t2.addingTimeInterval(200))
    check(r.skipped.first { $0.id == "r6" }?.reason == "superseded" && store.card(late) == nil && calKinds() == before && !before.contains("create"),
          "late_phone_restore_never_undoes_a_mac_delete")
}
