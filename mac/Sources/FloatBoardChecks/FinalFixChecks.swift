import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Fixes from the final whole-branch review of the calendar feature: each section names the finding it covers.
@MainActor func finalFixChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-finalfix-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let acct = "me@example.com"
    func setup(_ name: String) throws -> (Store, CalendarCache, CalendarOutbox) {
        let store = Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true)])
        return (store, cache, CalendarOutbox(store: store))
    }
    let cal = AppTime.calendar
    let day = cal.date(byAdding: .day, value: 4, to: cal.startOfDay(for: Date()))!
    func at(_ h: Int, _ m: Int = 0, plusDays: Int = 0) -> Date {
        cal.date(byAdding: .day, value: plusDays, to: cal.date(bySettingHour: h, minute: m, second: 0, of: day)!)!
    }

    // 1. The event panel: opening and closing it changes nothing; an overnight event keeps its next-day end.
    do {
        let (store, cache, outbox) = try setup("panel")
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "night", cancelled: false,
            fields: CalEventFields(start: at(23), end: at(1, plusDays: 1), title: "Night shift ", googleUpdated: Date()))], nextToken: nil)
        guard let ev = cache.event(account: acct, calendarID: acct, eventID: "night") else { check(false, "panel setup: no event"); return }
        let opened = EventPanelEdit.Fields(ev)
        // The time fields as a time input leaves them: same hour and minute, another date underneath.
        var same = opened
        same.start = cal.date(byAdding: .day, value: -3, to: opened.start)!; same.end = cal.date(byAdding: .day, value: 2, to: opened.end)!
        let none = EventPanelEdit.changes(event: ev, opened: opened, now: same)
        if let m = none.move { store.moveCalendarEvent(ev, start: m.start, end: m.end) }
        check(none.title == nil && none.move == nil && outbox.rows(unsent: true).isEmpty, "panel_unchanged_overnight_event_queues_nothing")

        var later = opened; later.end = at(2)  // the end time typed as 02:00
        let c2 = EventPanelEdit.changes(event: ev, opened: opened, now: later)
        check(c2.move?.start == at(23) && c2.move?.end == at(2, plusDays: 1) && c2.title == nil, "panel_overnight_end_edit_stays_next_day")

        var earlier = opened; earlier.start = at(22)  // only the start: the length is kept, like a drag
        let c3 = EventPanelEdit.changes(event: ev, opened: opened, now: earlier)
        check(c3.move?.start == at(22) && c3.move?.end == at(0, plusDays: 1), "panel_start_edit_keeps_length")

        var renamed = opened; renamed.title = "Night shift (swap)"
        let c4 = EventPanelEdit.changes(event: ev, opened: opened, now: renamed)
        check(c4.title == "Night shift (swap)" && c4.move == nil, "panel_title_edit_only_renames")

        let sheet = EventPanelEdit.span(day: day, start: at(23), end: at(23).addingTimeInterval(3600))
        let sheet2 = EventPanelEdit.span(day: day, start: at(23), end: at(22))
        check(sheet.start == at(23) && sheet.end == at(0, plusDays: 1) && sheet2.end == at(22, plusDays: 1), "new_event_end_rolls_to_next_day")
    } catch { check(false, "panel checks: \(error)") }

    // 2. The calendar list is read again at the next pass after a failed read or a reconnect, not 6 hours later;
    //    calendars of a removed account are not read.
    do {
        let (store, cache, _) = try setup("relist")
        let who = "relist@example.com", removed = "removed@example.com"
        cache.upsertCalendars(account: removed, [CalCalendar(account: removed, calendarID: removed, name: "Old", color: "#000000", owned: true, shown: true)])
        let fake = FakeGoogle()
        var listOK = false
        fake.handler = { r in
            if r.url?.path.hasSuffix("/users/me/calendarList") == true {
                return listOK ? (##"{"items":[{"id":"relist@example.com","summary":"R","accessRole":"owner","primary":true,"backgroundColor":"#111111"}]}"##, 200)
                              : (#"{"error":"backendError"}"#, 500)
            }
            return (#"{"items":[],"nextSyncToken":"T"}"#, 200)
        }
        let sync = CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [who] })
        func lists() -> Int { fake.requests.filter { $0.url?.path.hasSuffix("/users/me/calendarList") == true }.count }
        await sync.tick()
        let afterFail = lists()
        listOK = true
        await sync.tick()   // the failed read is tried again at once
        check(afterFail == 1 && lists() == 2 && CalendarListAttempts.outcome(who) == .listed
              && cache.calendars().contains { $0.account == who }, "calendar_list_retried_next_pass_after_failure")
        await sync.tick()
        let steady = lists()
        CalendarListAttempts.forget(who)   // what a fresh sign-in (Reconnect) does
        await sync.tick()
        check(steady == 2 && lists() == 3, "calendar_list_read_next_pass_after_reconnect")
        check(!fake.requests.contains { $0.url?.path.contains(removed) == true }, "sync_skips_calendars_of_removed_accounts")
    } catch { check(false, "relist checks: \(error)") }

    // 3. The task pop-up saves only what the user changed in it: Google's rename and Meet link made meanwhile stay.
    do {
        let (store, cache, outbox) = try setup("popup")
        store.add(title: "Budget call", area: store.areas.first?.name ?? "Work", importance: .medium, due: at(10), dueHasTime: true)
        guard let id = store.cards.last?.id else { check(false, "popup setup: no card"); return }
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(acct)', gcal_event='b1', gcal_synced_at=\(Date().timeIntervalSince1970 - 3600) WHERE id=\(id)")
        store.reload()
        guard let opened = store.card(id) else { check(false, "popup setup: no card"); return }
        // While the pop-up is open, Google renames the event and adds a Meet call.
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "b1", cancelled: false,
            fields: CalEventFields(start: at(10), end: at(10, 30), title: "Budget call (moved room)", videoLink: "https://meet.google.com/abc-defg-hij",
                                   googleUpdated: Date(), fbCard: id))], nextToken: nil)
        TaskEventRules.reconcile(store: store, cache: cache, now: Date())
        guard let current = store.card(id) else { check(false, "popup setup: card gone"); return }
        var edited = opened; edited.notes = "Bring the numbers"
        let merged = Card.editorSave(opened: opened, edited: edited, current: current)
        if merged != current { store.update(merged) }
        let after = store.card(id)
        check(after?.title == "Budget call (moved room)" && after?.link == "https://meet.google.com/abc-defg-hij" && after?.notes == "Bring the numbers"
              && outbox.rows(unsent: true).isEmpty, "popup_keeps_googles_changes_made_while_open")
        var retitled = edited; retitled.title = "Budget call v2"
        let m2 = Card.editorSave(opened: opened, edited: retitled, current: store.card(id) ?? current)
        check(m2.title == "Budget call v2" && m2.link == "https://meet.google.com/abc-defg-hij" && m2.due == at(10), "popup_saves_fields_the_user_changed")
    } catch { check(false, "popup checks: \(error)") }

    // 4. Undo Delete takes back a delete that has not reached Google (the event keeps its guests and Meet link); only a delete
    //    already sent is followed by a new event. Board changes for Google ask the scheduler to send at once.
    do {
        let (store, cache, outbox) = try setup("undo")
        var nudges = 0
        CalendarOutbox.nudge = { nudges += 1 }
        defer { CalendarOutbox.nudge = nil }
        func linkedTask(_ title: String, event: String, due: Date?) -> Int64 {
            store.add(title: title, area: store.areas.first?.name ?? "Work", importance: .medium, due: due, dueHasTime: due != nil)
            let id = store.cards.last?.id ?? 0
            store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(acct)', gcal_event='\(event)' WHERE id=\(id)")
            cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: event, cancelled: false,
                fields: CalEventFields(start: due ?? at(9), end: (due ?? at(9)).addingTimeInterval(1800), title: title,
                                       videoLink: "https://meet.google.com/abc-defg-hij", googleUpdated: Date(), fbCard: id))], nextToken: nil)
            return id
        }
        func gcalEvent(_ id: Int64) -> String {
            ((try? store.db.query("SELECT gcal_event FROM cards WHERE id=?", [id]) { DB.text($0, 0) }) ?? []).first ?? "" // try?-ok: "" fails the check
        }
        func kinds() -> [String] { outbox.rows(unsent: true).compactMap { r in r.write.map { w in
            switch w { case .create: "create"; case .patch: "patch"; case .delete: "delete" } } } }

        let a = linkedTask("Team lunch", event: "u1", due: at(12))
        guard let ca = store.card(a) else { check(false, "undo setup: no card"); return }
        nudges = 0
        store.delete(ca)
        let deleteNudged = nudges > 0 && kinds() == ["delete"]
        store.undoDelete()
        check(deleteNudged && outbox.rows(unsent: true).isEmpty && gcalEvent(a) == "u1" && store.card(a) != nil,
              "undo_before_send_drops_the_delete_and_keeps_the_event")

        // Already sent: the event is gone in Google, so a new one is made (and the scheduler is asked to send it).
        guard let ca2 = store.card(a) else { check(false, "undo setup: card not back"); return }
        store.delete(ca2)
        for r in outbox.rows(unsent: true) { outbox.markSent(uuid: r.uuid, result: nil) }
        nudges = 0
        store.undoDelete()
        check(kinds() == ["create"] && nudges > 0, "undo_after_send_recreates_the_event")
        for r in outbox.rows(unsent: true) { outbox.markSent(uuid: r.uuid, result: nil) }

        // While the delete is on its way to Google it can't be taken back: a new event follows.
        let b = linkedTask("Dentist", event: "u2", due: at(15))
        guard let cb = store.card(b) else { check(false, "undo setup: no card b"); return }
        store.delete(cb)
        let inFlight = outbox.rows(unsent: true).first?.uuid ?? ""
        outbox.setInFlight(inFlight, true)
        store.undoDelete()
        outbox.setInFlight(inFlight, false)
        check(Set(kinds()) == ["delete", "create"], "undo_while_delete_in_flight_recreates")
        for r in outbox.rows(unsent: true) { outbox.markSent(uuid: r.uuid, result: nil) }

        // No due: the event can't be made again; one Activity line says so.
        let c = linkedTask("Someday idea", event: "u3", due: at(16))
        store.performForTest("UPDATE cards SET due=NULL, due_day=NULL, due_has_time=0 WHERE id=\(c)")
        guard let cc = store.card(c) else { check(false, "undo setup: no card c"); return }
        store.delete(cc)
        for r in outbox.rows(unsent: true) { outbox.markSent(uuid: r.uuid, result: nil) }
        store.undoDelete()
        let lines = store.recentActivity(limit: 50).filter { $0.message.contains("can't be made again") }.count
        check(outbox.rows(unsent: true).isEmpty && lines == 1, "undo_without_due_logs_that_the_event_cant_be_remade")

        // A board edit of a task on the calendar asks for a send at once.
        let d = linkedTask("Board review", event: "u4", due: at(17))
        nudges = 0
        if var cd = store.card(d) { cd.title = "Board review (Q4)"; store.update(cd) }
        check(nudges > 0 && kinds() == ["patch"], "board_edit_of_calendar_task_nudges_the_scheduler")
    } catch { check(false, "undo checks: \(error)") }

    await outboxFailureChecks(setup: setup, at: { at($0, $1, plusDays: $2) })
}

/// 5. Google's answers that can never succeed end a change for good (one Activity error, no more retries); only a missing
///    permission asks to reconnect; nothing is sent offline; a repeating warning is written once.
@MainActor private func outboxFailureChecks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date) async {
    let acct = "me@example.com"
    func reject(_ status: Int, _ body: String, _ call: (GoogleCalendarAPI) async throws -> Void) async -> GoogleCalendarError? {
        let fake = FakeGoogle(); fake.handler = { _ in (body, status) }
        do { try await call(fake.api()); return nil } catch { return error as? GoogleCalendarError }
    }
    let scope = #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
    let forbidden = #"{"error":{"code":403,"status":"PERMISSION_DENIED","errors":[{"reason":"forbidden","message":"Forbidden"}]}}"#
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var scopeIsReconnect = false
    if case .needsReconnect? = await reject(403, scope, { _ = try await $0.listCalendars() }) { scopeIsReconnect = true }
    let forbiddenErr = await reject(403, forbidden, { _ = try await $0.patch(calendarID: "c", eventID: "e", title: "x", start: nil, end: nil, allDayStart: nil) })
    check(scopeIsReconnect && forbiddenErr == .http(status: 403, body: forbidden), "only_scope_errors_ask_to_reconnect")
    let patchGone = await reject(410, #"{"error":{"code":410}}"#, { _ = try await $0.patch(calendarID: "c", eventID: "e", title: "x", start: nil, end: nil, allDayStart: nil) })
    let listGone = await reject(410, #"{"error":{"code":410}}"#, { _ = try await $0.listEvents(calendarID: "c", syncToken: "old", timeMin: t0, timeMax: t0) })
    check(patchGone == .http(status: 410, body: #"{"error":{"code":410}}"#) && listGone == .syncExpired, "410_means_sync_expired_only_for_event_lists")

    // A malformed event is skipped (and reported), not the whole page.
    let mixed = FakeGoogle()
    mixed.handler = { _ in (#"{"items":[{"id":"bad1","status":"confirmed","summary":"No times"},{"id":"ok1","status":"confirmed","summary":"Fine","start":{"dateTime":"2026-11-20T10:00:00Z"},"end":{"dateTime":"2026-11-20T11:00:00Z"},"updated":"2026-11-16T10:00:00Z"}],"nextSyncToken":"S"}"#, 200) }
    do {
        let r = try await mixed.api().listEvents(calendarID: "c", syncToken: nil, timeMin: t0, timeMax: t0)
        check(r.changes.map(\.eventID) == ["ok1"] && r.skipped.count == 1 && r.skipped[0].contains("bad1"), "malformed_event_is_skipped_not_the_page")
    } catch { check(false, "malformed_event_is_skipped_not_the_page: \(error)") }
    do {
        let (store, cache, _) = try setup("malformed")
        let sync = CalendarSync(store: store, apiFor: { _ in mixed.api() }, accounts: { [acct] })
        await sync.syncOnce()
        let logged = store.recentActivity(limit: 50).filter { ($0.detail ?? "").contains("bad1") }.count
        check(cache.event(account: acct, calendarID: acct, eventID: "ok1") != nil && logged == 1, "malformed_event_is_logged_once")
    } catch { check(false, "malformed sync: \(error)") }

    func sender(_ store: Store, _ fake: FakeGoogle, online: @escaping () -> Bool = { true }) -> CalendarSender {
        CalendarSender(store: store, apiFor: { _ in fake.api() }, isOnline: online)
    }
    let fields = CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: "Planning", googleUpdated: t0)
    do {
        // Permanent answers: the row is dead after one try, with one Activity error.
        for (name, status, body, write) in [
            ("patch_404", 404, #"{"error":{"code":404,"message":"Not Found"}}"#, CalWrite.patch(eventID: "e1", title: "x", start: nil, end: nil, allDayStart: nil)),
            ("patch_410", 410, #"{"error":{"code":410,"message":"Deleted"}}"#, CalWrite.patch(eventID: "e1", title: "x", start: nil, end: nil, allDayStart: nil)),
            ("create_400", 400, #"{"error":{"code":400,"message":"Bad Request"}}"#, CalWrite.create(fields, cardID: nil, addMeet: false)),
            ("create_403", 403, forbidden, CalWrite.create(fields, cardID: nil, addMeet: false)),
            ("delete_403", 403, forbidden, CalWrite.delete(eventID: "e1")),
        ] {
            let (store, _, outbox) = try setup("dead-\(name)")
            let fake = FakeGoogle(); fake.handler = { _ in (body, status) }
            let s = sender(store, fake)
            let uuid = outbox.enqueue(write, account: acct, calendarID: acct)
            await s.drain()
            for r in outbox.rows(unsent: true) { outbox.markFailed(uuid: r.uuid, error: r.lastError, now: Date(timeIntervalSinceNow: -7200)) }
            await s.drain()
            let row = outbox.rows(unsent: true).first { $0.uuid == uuid }
            let errors = store.recentActivity(limit: 50).filter { $0.level == .error && $0.message.contains("refused") }.count
            check(fake.requests.count == 1 && row?.failedAt != nil && outbox.due(now: Date().addingTimeInterval(86400)).isEmpty && errors == 1,
                  "sender_\(name)_is_permanent")
        }

        // A rate limit is not permanent.
        let (rs, _, ro) = try setup("ratelimit")
        let rf = FakeGoogle(); rf.handler = { _ in (#"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#, 403) }
        ro.enqueue(.delete(eventID: "e1"), account: acct, calendarID: acct)
        await sender(rs, rf).drain()
        check(ro.rows(unsent: true).first?.failedAt == nil && ro.rows(unsent: true).first?.attempts == 1, "sender_403_rate_limit_is_retried")

        // A dead new event shows as a failed placeholder until discarded.
        let (ns, _, no) = try setup("discard")
        let nf = FakeGoogle(); nf.handler = { _ in (#"{"error":{"code":400}}"#, 400) }
        let nu = no.enqueue(.create(fields, cardID: nil, addMeet: false), account: acct, calendarID: acct)
        await sender(ns, nf).drain()
        let shown = no.pendingNewEvents(from: at(0, 0, 0), to: at(23, 0, 0))
        let failed = no.failedNewEvents()
        let eid = CalendarOutbox.googleEventID(forUUID: nu)
        let hadFailure = shown.count == 1 && failed[eid]?.uuid == nu && failed[eid]?.error.contains("400") == true
        no.discard(uuid: nu)
        check(hadFailure && no.pendingNewEvents(from: at(0, 0, 0), to: at(23, 0, 0)).isEmpty && no.rows(unsent: true).isEmpty, "dead_new_event_shows_failed_until_discarded")

        // Offline: nothing is sent and nothing backs off.
        let (os, _, oo) = try setup("offline")
        let of = FakeGoogle()
        oo.enqueue(.delete(eventID: "e1"), account: acct, calendarID: acct)
        await sender(os, of, online: { false }).drain()
        check(of.requests.isEmpty && oo.rows(unsent: true).first?.attempts == 0, "sender_skips_drain_offline")

        // The same transient failure is written once per change.
        let (ws, _, wo) = try setup("warnonce")
        let wf = FakeGoogle(); wf.handler = { _ in (#"{"error":"backendError"}"#, 500) }
        wo.enqueue(.delete(eventID: "e1"), account: acct, calendarID: acct)
        let ws1 = sender(ws, wf)
        for _ in 0..<3 {
            await ws1.drain()
            for r in wo.rows(unsent: true) { wo.markFailed(uuid: r.uuid, error: r.lastError, now: Date(timeIntervalSinceNow: -7200)) }
        }
        let warnings = ws.recentActivity(limit: 50).filter { $0.message.contains("Could not send") }.count
        check(wf.requests.count == 3 && warnings == 1, "sender_transient_warning_written_once_per_row")

        // A dead change does not hold back the task: Google's newer title still comes in, and a refused edit is not re-sent forever.
        let (ds, dc, dout) = try setup("deadtask")
        ds.add(title: "Quarterly plan", area: ds.areas.first?.name ?? "Work", importance: .medium, due: at(9, 0, 0), dueHasTime: true)
        guard let id = ds.cards.last?.id else { check(false, "dead task setup"); return }
        ds.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(acct)', gcal_event='q1' WHERE id=\(id)")
        dc.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "q1", cancelled: false,
            fields: CalEventFields(start: at(9, 0, 0), end: at(9, 30, 0), title: "Quarterly plan", googleUpdated: Date().addingTimeInterval(-7200), fbCard: id))], nextToken: nil)
        if var c = ds.card(id) { c.title = "Quarterly plan (draft)"; ds.update(c) }   // the board edit: Google will refuse it
        let df = FakeGoogle(); df.handler = { _ in (forbidden, 403) }
        await sender(ds, df).drain()
        TaskEventRules.reconcile(store: ds, cache: dc, now: Date())
        let requeued = dout.rows(unsent: true).filter { $0.failedAt == nil }.count
        dc.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: "q1", cancelled: false,
            fields: CalEventFields(start: at(9, 0, 0), end: at(9, 30, 0), title: "Quarterly plan (final)", googleUpdated: Date().addingTimeInterval(60), fbCard: id))], nextToken: nil)
        TaskEventRules.reconcile(store: ds, cache: dc, now: Date().addingTimeInterval(61))
        check(requeued == 0 && ds.card(id)?.title == "Quarterly plan (final)", "dead_row_neither_blocks_nor_loops_reconcile")
    } catch { check(false, "outbox failure checks: \(error)") }
}

/// A fake Google for the checks: records requests and answers with `handler` (body, status).
final class FakeGoogle: @unchecked Sendable {
    var requests: [URLRequest] = []
    var handler: (URLRequest) -> (String, Int) = { _ in ("{}", 200) }
    func api() -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { [self] req in
            requests.append(req)
            let (body, status) = handler(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}
