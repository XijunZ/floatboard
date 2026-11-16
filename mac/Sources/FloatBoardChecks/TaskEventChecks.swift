import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Tasks and their Google events staying in step (D4, D7-D11, C1, C3, C4), plus the sync loop against a fake Google.
@MainActor func taskEventChecks() async {
    let acct = "me@example.com", cal = "me@example.com"
    let t = Date()
    func ago(_ s: TimeInterval) -> Date { t.addingTimeInterval(-s) }
    func at(_ day: String, _ h: Int, _ m: Int = 0) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return AppTime.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h, minute: m)) ?? t
    }
    // Days a little ahead of "now" so they sit inside the sync window.
    let d1 = Due.dayString(t.addingTimeInterval(5 * 86400)), d2 = Due.dayString(t.addingTimeInterval(7 * 86400))
    let long = ago(7200)   // when the board "made" its changes, well before Google's later ones

    func setup(_ name: String) throws -> (Store, CalendarCache, CalendarOutbox) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-taskevent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cal, name: "Me", color: "#112233", owned: true, shown: true)])
        return (store, cache, CalendarOutbox(store: store))
    }
    func newCard(_ store: Store, _ title: String, due: Date? = nil, hasTime: Bool = false) -> Int64 {
        store.add(title: title, area: store.areas.first?.name ?? "Work", importance: .medium, due: due, dueHasTime: hasTime)
        return store.cards.last { $0.title == title }?.id ?? 0
    }
    func link(_ store: Store, _ id: Int64) -> (account: String, calendar: String, event: String) {
        let r = (try? store.db.query("SELECT gcal_account, gcal_calendar, gcal_event FROM cards WHERE id=?", [id]) { (DB.text($0, 0), DB.text($0, 1), DB.text($0, 2)) })?.first // try?-ok: empty fails the checks
        return r ?? ("", "", "")
    }
    func unsent(_ o: CalendarOutbox) -> [CalOutboxRow] { o.rows(unsent: true) }
    func isCreate(_ r: CalOutboxRow) -> Bool { if case .create? = r.write { return true } else { return false } }
    /// Plays the sender: the oldest unsent create is accepted by "Google" under `eventID`.
    func sendCreate(_ o: CalendarOutbox, as eventID: String, updated: Date) {
        guard let row = unsent(o).first(where: isCreate), case .create(var f, _, _)? = row.write else { return }
        f.googleUpdated = updated
        o.markSent(uuid: row.uuid, result: (eventID, f), now: updated)
    }
    func drop(_ o: CalendarOutbox) { for r in unsent(o) { o.markSent(uuid: r.uuid, result: nil) } }
    func historyActors(_ s: Store, _ id: Int64, like: String) -> [String] {
        ((try? s.db.query("SELECT actor FROM events WHERE card_id=? AND kind LIKE ?", [id, like]) { DB.text($0, 0) }) ?? []) // try?-ok: empty fails the checks
    }
    func googleChange(_ cache: CalendarCache, _ id: String, _ title: String, start: Date, updated: Date, allDayStart: String? = nil, fb: Int64? = nil) {
        var f = CalEventFields(start: start, end: start.addingTimeInterval(1800), title: title, googleUpdated: updated, fbCard: fb)
        if let d = allDayStart {
            f.allDay = true; f.startDay = d
            f.endDay = Due.dayString((Due.startOfDay(d) ?? start).addingTimeInterval(36 * 3600))
        }
        cache.apply(account: acct, calendarID: cal, changes: [GoogleEventChange(eventID: id, cancelled: false, fields: f)], nextToken: nil, now: updated)
    }

    do {
        // Drag: due gets the time, one create goes to the outbox (default account from settings), 30 minutes (C1, D7).
        let (store, _, outbox) = try setup("drag")
        store.performForTest("INSERT OR REPLACE INTO meta(key,value) VALUES('calendar_default_account','\(acct)')")
        let id = newCard(store, "Plan trip")
        let start = at(d1, 15)
        store.placeOnCalendar(cardID: id, start: start, account: nil)
        let c = store.card(id)
        let rows = unsent(outbox)
        var created: CalEventFields?
        if case .create(let f, let cid, let meet)? = rows.first?.write, cid == id, !meet { created = f }
        check(c?.due == start && c?.dueHasTime == true && rows.count == 1 && rows[0].account == acct && rows[0].calendarID == cal
              && created?.start == start && created?.end == start.addingTimeInterval(1800) && created?.title == "Plan trip"
              && created?.fbCard == id && created?.allDay == false, "drag_sets_due_and_creates_event")

        // Dragged again before the create was sent: a patch aimed at the same event, not a second create.
        store.placeOnCalendar(cardID: id, start: at(d1, 16), account: nil)
        let creates = unsent(outbox).filter(isCreate).count
        let evID = CalendarOutbox.googleEventID(forUUID: unsent(outbox)[0].uuid)
        var patchedEarly = false
        if case .patch(let eid, _, let s, let e, _)? = unsent(outbox).last?.write { patchedEarly = eid == evID && s == at(d1, 16) && e == at(d1, 16, 30) }
        // Once linked, another drag patches the linked event.
        drop(outbox)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(cal)', gcal_event='ev1' WHERE id=\(id)")
        store.placeOnCalendar(cardID: id, start: at(d1, 17), account: nil)
        let after = unsent(outbox)
        var patched = false
        if after.count == 1, case .patch(let eid, _, let s, let e, _)? = after[0].write { patched = eid == "ev1" && s == at(d1, 17) && e == at(d1, 17, 30) }
        check(creates == 1 && patchedEarly && patched && store.card(id)?.due == at(d1, 17), "drag_again_patches_not_duplicates")
    } catch { check(false, "drag setup: \(error)") }

    do {
        // Default account: unset means the first connected account; a chosen one wins.
        let (store, cache, outbox) = try setup("acct")
        cache.upsertCalendars(account: "other@example.com", [CalCalendar(account: "other@example.com", calendarID: "other@example.com", name: "O", color: "#000000", owned: true, shown: true)])
        let id = newCard(store, "A"), id2 = newCard(store, "B")
        store.placeOnCalendar(cardID: id, start: at(d1, 9), account: nil)
        store.placeOnCalendar(cardID: id2, start: at(d1, 10), account: "other@example.com")
        check(unsent(outbox).map(\.account) == [acct, "other@example.com"], "drag_account_default_and_chosen")
    } catch { check(false, "acct setup: \(error)") }

    do {
        // Google moves the event: the task's due follows; renaming renames the task. Applied from Google, nothing goes back.
        let (store, cache, outbox) = try setup("move")
        let id = newCard(store, "Review deck")
        store.placeOnCalendar(cardID: id, start: at(d1, 15), account: acct, now: long)
        sendCreate(outbox, as: "g1", updated: ago(600))
        check(link(store, id).event == "g1", "setup_linked")
        googleChange(cache, "g1", "Review deck", start: at(d1, 17), updated: ago(300), fb: id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(store.card(id)?.due == at(d1, 17) && store.card(id)?.dueHasTime == true && unsent(outbox).isEmpty
              && historyActors(store, id, like: "due:%").contains("connector:calendar"), "google_move_moves_task_due")
        googleChange(cache, "g1", "Review the deck", start: at(d1, 17), updated: ago(200), fb: id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        let before = store.card(id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(store.card(id)?.title == "Review the deck" && unsent(outbox).isEmpty && store.card(id) == before
              && historyActors(store, id, like: "title:%").contains("connector:calendar"), "google_rename_renames_task")
    } catch { check(false, "move setup: \(error)") }

    do {
        // Google deletes the event: the task stays, keeps its date, loses its time and its link (D4).
        let (store, cache, outbox) = try setup("gdel")
        let id = newCard(store, "Dentist")
        store.placeOnCalendar(cardID: id, start: at(d1, 9, 30), account: acct, now: long)
        sendCreate(outbox, as: "g1", updated: ago(600))
        cache.apply(account: acct, calendarID: cal, changes: [GoogleEventChange(eventID: "g1", cancelled: true, fields: nil)], nextToken: nil)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        let c = store.card(id)
        check(c != nil && c?.dueHasTime == false && c.map { Due.dayString($0.due!) } == d1 && link(store, id).event == ""
              && link(store, id).account == "" && unsent(outbox).isEmpty && !store.cards.isEmpty, "google_delete_keeps_task_drops_time")

        // An event that fell out of the window (a full re-read hides everything first) is not taken as deleted.
        let far = newCard(store, "Far off")
        let farStart = at(Due.dayString(t.addingTimeInterval(200 * 86400)), 10)
        store.placeOnCalendar(cardID: far, start: farStart, account: acct, now: long)
        sendCreate(outbox, as: "gfar", updated: ago(600))
        cache.resetSync(account: acct, calendarID: cal)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(link(store, far).event == "gfar" && store.card(far)?.dueHasTime == true, "reset_outside_window_is_not_a_delete")
        // Time passes: the hidden event is still not a deletion when the window reaches it, nor is any other reset-hidden one.
        TaskEventRules.reconcile(store: store, cache: cache, now: t.addingTimeInterval(120 * 86400))
        check(link(store, far).event == "gfar" && store.card(far)?.dueHasTime == true && cache.event(account: acct, calendarID: cal, eventID: "gfar")?.cancelled == false,
              "reset_then_time_passes_keeps_link")
        // A real cancellation after that still drops it.
        cache.apply(account: acct, calendarID: cal, changes: [GoogleEventChange(eventID: "gfar", cancelled: true, fields: nil)], nextToken: nil)
        TaskEventRules.reconcile(store: store, cache: cache, now: t.addingTimeInterval(120 * 86400))
        check(link(store, far).event == "" && cache.event(account: acct, calendarID: cal, eventID: "gfar")?.cancelled == true, "cancellation_after_reset_still_drops_link")
    } catch { check(false, "gdel setup: \(error)") }

    do {
        // Deleting a task deletes only the event FloatBoard made for it (D8); undo recreates it.
        let (store, cache, outbox) = try setup("tdel")
        let a = newCard(store, "Made here")
        store.placeOnCalendar(cardID: a, start: at(d1, 11), account: acct, now: long)
        sendCreate(outbox, as: "ga", updated: ago(600))
        googleChange(cache, "ga", "Made here", start: at(d1, 11), updated: ago(590), fb: a)   // as Google reports it, marked as ours
        let b = newCard(store, "Linked to a Google meeting", due: at(d1, 12), hasTime: true)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(cal)', gcal_event='gb' WHERE id=\(b)")
        googleChange(cache, "gb", "Team sync", start: at(d1, 12), updated: ago(500), fb: 9999)   // marked as made for another task
        let c = newCard(store, "Never cached", due: at(d1, 13), hasTime: true)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(cal)', gcal_event='gc' WHERE id=\(c)")
        store.delete(store.card(a)!)
        let rowsA = unsent(outbox)
        var delA = false, delUUID = ""
        if rowsA.count == 1, case .delete(let eid)? = rowsA[0].write { delA = eid == "ga"; delUUID = rowsA[0].uuid }
        store.undoDelete()
        let afterUndo = unsent(outbox)
        var recreated = false
        if afterUndo.count == 2, case .create(let f, let cid, _)? = afterUndo[1].write {
            recreated = cid == a && f.fbCard == a && f.title == "Made here" && f.start == at(d1, 11) && afterUndo[1].uuid != delUUID
        }
        drop(outbox)
        store.delete(store.card(b)!)
        let afterB = unsent(outbox).count
        store.delete(store.card(c)!)
        var delC = false
        if unsent(outbox).count == 1, case .delete(let eid)? = unsent(outbox)[0].write { delC = eid == "gc" }
        check(delA && afterB == 0 && delC, "task_delete_deletes_only_fb_event")
        check(recreated, "undo_delete_recreates_event")
    } catch { check(false, "tdel setup: \(error)") }

    do {
        // Tasks added to the calendar by the first version: account and event saved, no calendar, event unmarked.
        let (store, cache, outbox) = try setup("oldpath")
        let id = newCard(store, "Old style", due: at(d1, 10), hasTime: true)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_event='old1' WHERE id=\(id)")
        let id2 = newCard(store, "Old style 2", due: at(d1, 12), hasTime: true)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_event='old2' WHERE id=\(id2)")
        googleChange(cache, "old1", "Old style", start: at(d1, 10), updated: ago(900))
        googleChange(cache, "old2", "Old style 2", start: at(d1, 12), updated: ago(900))
        let meetingBefore = cache.nextMeeting(after: at(d1, 9))?.eventID
        googleChange(cache, "old1", "Old style", start: at(d1, 15), updated: ago(60))
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(link(store, id).calendar == cal && store.card(id)?.due == at(d1, 15) && unsent(outbox).isEmpty, "old_card_reconciled_after_backfill")
        check(meetingBefore == nil && cache.nextMeeting(after: at(d1, 9)) == nil, "old_card_event_is_not_a_bar_meeting")
        store.performForTest("UPDATE cards SET gcal_calendar='' WHERE id=\(id2)")   // deleted before any reconcile has filled it in
        store.delete(store.card(id2)!)
        var del = false
        if unsent(outbox).count == 1, case .delete(let eid)? = unsent(outbox)[0].write { del = eid == "old2" && unsent(outbox)[0].calendarID == cal }
        check(del, "deleting_old_card_enqueues_event_delete")
    } catch { check(false, "oldpath setup: \(error)") }

    do {
        // Clearing the due leaves the event and its link (D8); done leaves the event (C3).
        let (store, cache, outbox) = try setup("clear")
        let id = newCard(store, "Keep event")
        store.placeOnCalendar(cardID: id, start: at(d1, 14), account: acct, now: long)
        sendCreate(outbox, as: "g1", updated: ago(600))
        googleChange(cache, "g1", "Keep event", start: at(d1, 14), updated: ago(590), fb: id)
        var card = store.card(id)!
        card.due = nil; card.dueHasTime = false
        store.update(card, now: ago(60))
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(unsent(outbox).isEmpty && link(store, id).event == "g1" && store.card(id)?.due == nil, "clear_due_leaves_event_linked")
        store.move(store.card(id)!, to: .done)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(unsent(outbox).isEmpty && link(store, id).event == "g1" && store.card(id)?.status == .done, "done_leaves_event")
    } catch { check(false, "clear setup: \(error)") }

    do {
        // Per field, the newer change wins (C4): Google's newer time beats the older board time; the board's newer title beats Google's older one.
        let (store, cache, outbox) = try setup("perfield")
        let id = newCard(store, "Old title")
        store.placeOnCalendar(cardID: id, start: at(d1, 9), account: acct, now: ago(5000))
        sendCreate(outbox, as: "g1", updated: ago(3600))
        googleChange(cache, "g1", "Old title", start: at(d1, 9), updated: ago(3600), fb: id)
        drop(outbox)
        // The board renamed at -2000 s and moved the time at -1000 s; Google changed both at -1500 s (its title is newer than the
        // rename, its time older than the move). Both patches are dropped so reconcile has to decide for itself.
        var card = store.card(id)!
        card.title = "Board title"
        store.update(card, now: ago(2000))
        card = store.card(id)!
        card.due = at(d1, 11)
        store.update(card, now: ago(1000))
        let queued = unsent(outbox).count
        drop(outbox)
        googleChange(cache, "g1", "Google title", start: at(d1, 13), updated: ago(1500), fb: id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        let c = store.card(id)
        var patchedTime = false
        if unsent(outbox).count == 1, case .patch(let eid, let title, let s, let e, _)? = unsent(outbox)[0].write {
            patchedTime = eid == "g1" && title == nil && s == at(d1, 11) && e == at(d1, 11, 30)
        }
        check(queued == 2 && c?.title == "Google title" && c?.due == at(d1, 11) && patchedTime, "per_field_newer_wins")
        // Running it again changes nothing and queues nothing more (no loops).
        let snapshot = store.card(id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(store.card(id) == snapshot && unsent(outbox).count == 1, "reconcile_is_stable_no_loop")
    } catch { check(false, "perfield setup: \(error)") }

    do {
        // Events made in Google never create or change tasks (D9).
        let (store, cache, outbox) = try setup("mirror")
        let id = newCard(store, "Standup", due: at(d1, 9), hasTime: true)   // same name and time as the event, but not linked
        let before = store.cards
        googleChange(cache, "gx", "Standup", start: at(d1, 9), updated: ago(100))
        googleChange(cache, "gy", "Lunch", start: at(d1, 12), updated: ago(100))
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        googleChange(cache, "gx", "Standup moved", start: at(d1, 10), updated: ago(50))
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        check(store.cards == before && store.card(id)?.due == at(d1, 9) && unsent(outbox).isEmpty, "google_made_event_never_touches_tasks")
    } catch { check(false, "mirror setup: \(error)") }

    do {
        // D11: "Add to calendar" on a date-only task makes an all-day event; moving it in Google moves the task's date.
        let (store, cache, outbox) = try setup("allday")
        let id = newCard(store, "Submit form", due: Due.startOfDay(d1), hasTime: false)
        let queued = store.addToCalendar(store.card(id)!, account: acct, addMeet: true)
        var allDay = false, meet = false
        if case .create(let f, let cid, let m)? = unsent(outbox).first?.write {
            allDay = f.allDay && f.startDay == d1 && f.endDay == Due.dayString((Due.startOfDay(d1) ?? t).addingTimeInterval(36 * 3600)) && cid == id && f.fbCard == id
            meet = m
        }
        check(queued && allDay && meet && unsent(outbox).count == 1, "add_to_calendar_date_only_makes_all_day_event")
        sendCreate(outbox, as: "g1", updated: ago(600))
        googleChange(cache, "g1", "Submit form", start: Due.startOfDay(d2) ?? t, updated: ago(300), allDayStart: d2, fb: id)
        TaskEventRules.reconcile(store: store, cache: cache, now: t)
        let c = store.card(id)
        check(c?.dueHasTime == false && c.map { Due.dayString($0.due!) } == d2 && unsent(outbox).isEmpty,
              "date_only_add_to_calendar_makes_all_day_and_google_date_move_moves_task")
        // Adding a task that is already on the calendar does not make a second event.
        check(!store.addToCalendar(store.card(id)!, account: acct, addMeet: false) && unsent(outbox).isEmpty, "add_to_calendar_twice_is_a_no_op")
    } catch { check(false, "allday setup: \(error)") }

    do {
        // Watchdog: a shown calendar not synced for 30 minutes while online is a problem; offline, hidden or recent is not.
        let (store, cache, _) = try setup("watch")
        store.performForTest("UPDATE cal_calendars SET synced_at=\(t.timeIntervalSince1970 - 31 * 60)")
        let stale = Health.evaluate(store: store, backups: nil, now: t, online: true, launchedAt: .distantPast).map(\.id)
        let offline = Health.evaluate(store: store, backups: nil, now: t, online: false, launchedAt: .distantPast).map(\.id)
        let justLaunched = Health.evaluate(store: store, backups: nil, now: t, online: true, launchedAt: ago(60)).map(\.id)
        store.performForTest("UPDATE cal_calendars SET synced_at=\(t.timeIntervalSince1970 - 20 * 60)")
        let recent = Health.evaluate(store: store, backups: nil, now: t, online: true, launchedAt: .distantPast).map(\.id)
        store.performForTest("UPDATE cal_calendars SET synced_at=\(t.timeIntervalSince1970 - 31 * 60)")
        cache.setShown(account: acct, calendarID: cal, false)
        let hidden = Health.evaluate(store: store, backups: nil, now: t, online: true, launchedAt: .distantPast).map(\.id)
        check(stale.count == 1 && stale[0].hasPrefix("calendar-stale:") && offline.isEmpty && justLaunched.isEmpty && recent.isEmpty && hidden.isEmpty,
              "watchdog_warns_calendar_stale_30_min")
    } catch { check(false, "watch setup: \(error)") }

    // The sync loop against a fake Google.
    final class Fake: @unchecked Sendable {
        var requests: [URLRequest] = []
        var handler: (URLRequest) -> (String, Int) = { _ in ("{}", 200) }
    }
    func api(_ fake: Fake) -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { req in
            fake.requests.append(req)
            let (body, status) = fake.handler(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
    func query(_ r: URLRequest, _ name: String) -> String? {
        URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    do {
        let (store, cache, outbox) = try setup("sync")
        let id = newCard(store, "Synced task")
        store.placeOnCalendar(cardID: id, start: at(d1, 15), account: acct, now: long)
        sendCreate(outbox, as: "g1", updated: ago(600))
        let fake = Fake()
        let iso = ISO8601DateFormatter()
        let s18 = iso.string(from: at(d1, 18)), e18 = iso.string(from: at(d1, 18, 30)), upd = iso.string(from: ago(10))
        let page1 = #"{"items":[{"id":"g1","status":"confirmed","summary":"Synced task","start":{"dateTime":"\#(s18)"},"end":{"dateTime":"\#(e18)"},"updated":"\#(upd)","extendedProperties":{"private":{"floatboard_card":"\#(id)"}}}],"nextSyncToken":"T1"}"#
        fake.handler = { _ in (page1, 200) }
        let sync = CalendarSync(store: store, apiFor: { _ in api(fake) }, accounts: { [acct] }, now: { t })
        await sync.syncOnce()
        let first = fake.requests.first
        check(first.flatMap { query($0, "syncToken") } == nil && first.flatMap { query($0, "timeMin") } != nil && first.flatMap { query($0, "timeMax") } != nil
              && cache.calendars().first?.syncToken == "T1" && store.card(id)?.due == at(d1, 18), "sync_first_reads_window_then_reconciles")
        let minDate = iso.date(from: first.flatMap { query($0, "timeMin") } ?? ""), maxDate = iso.date(from: first.flatMap { query($0, "timeMax") } ?? "")
        check(abs((minDate?.timeIntervalSince(t) ?? 0) + 30 * 86400) < 2 && abs((maxDate?.timeIntervalSince(t) ?? 0) - 90 * 86400) < 2, "sync_window_30_back_90_ahead")

        fake.handler = { _ in (#"{"items":[],"nextSyncToken":"T2"}"#, 200) }
        await sync.syncOnce()
        check(query(fake.requests.last!, "syncToken") == "T1" && query(fake.requests.last!, "timeMin") == nil
              && cache.calendars().first?.syncToken == "T2", "sync_uses_stored_token")

        // 410: reset, then a full window read.
        let before = fake.requests.count
        let page3 = page1.replacingOccurrences(of: "\"nextSyncToken\":\"T1\"", with: "\"nextSyncToken\":\"T3\"")
        fake.handler = { r in
            if query(r, "syncToken") != nil { return (#"{"error":{"code":410}}"#, 410) }
            return (page3, 200)
        }
        await sync.syncOnce()
        let reqs = Array(fake.requests[before...])
        check(reqs.count == 2 && query(reqs[0], "syncToken") == "T2" && query(reqs[1], "syncToken") == nil && query(reqs[1], "timeMin") != nil
              && cache.calendars().first?.syncToken == "T3" && cache.event(account: acct, calendarID: cal, eventID: "g1")?.gone == false,
              "sync_410_resets_and_reads_full_window")

        // A 410 whose full re-read then fails: the task keeps its time and link.
        fake.handler = { r in query(r, "syncToken") != nil ? (#"{"error":{"code":410}}"#, 410) : (#"{"error":"backendError"}"#, 500) }
        await sync.syncOnce()
        check(link(store, id).event == "g1" && store.card(id)?.dueHasTime == true && cache.calendars().first?.syncToken == nil,
              "sync_reset_then_failed_reread_keeps_link")
        fake.handler = { _ in (page3, 200) }
        await sync.syncOnce()

        // 401 twice: flagged, and the next good sync clears the flag.
        fake.handler = { _ in (#"{"error":"unauthorized"}"#, 401) }
        await sync.syncOnce()
        let flagged = cache.calendars().first?.needsReconnect == true
        fake.handler = { _ in (#"{"items":[],"nextSyncToken":"T4"}"#, 200) }
        await sync.syncOnce()
        check(flagged && cache.calendars().first?.needsReconnect == false, "sync_needs_reconnect_flagged_and_cleared")

        // Signed out: flagged without a network call.
        let signedOut = CalendarSync(store: store, apiFor: { _ in GoogleCalendarAPI(token: { _ in throw GoogleCalendarError.notConnected(account: acct) }, http: { _ in throw GoogleCalendarError.badResponse("no") }) },
                                     accounts: { [acct] }, now: { t })
        await signedOut.syncOnce()
        check(cache.calendars().first?.needsReconnect == true, "sync_not_connected_flags_reconnect")

        // Listing calendars: owned and primary ones are shown, others start hidden.
        let fake2 = Fake()
        fake2.handler = { _ in (##"{"items":[{"id":"me@example.com","summary":"Me","accessRole":"owner","primary":true,"backgroundColor":"#111111"},{"id":"team","summary":"Team","accessRole":"reader","backgroundColor":"#222222"}]}"##, 200) }
        let lister = CalendarSync(store: store, apiFor: { _ in api(fake2) }, accounts: { [acct] }, now: { t })
        await lister.refreshCalendars()
        let cals = cache.calendars()
        check(cals.count == 2 && cals.first { $0.calendarID == "team" }?.shown == false && cals.first { $0.calendarID == cal }?.shown == true,
              "sync_lists_calendars_with_sensible_defaults")
    } catch { check(false, "sync setup: \(error)") }
}
