import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// Fixes from the Codex adversarial review of the calendar branch (F1-F8): each section names the finding it covers.
@MainActor func codexFixChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-codexfix-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) // try?-ok: a failure shows up as failed checks below
    defer { try? FileManager.default.removeItem(at: root) } // try?-ok: scratch folder cleanup
    let acct = "me@example.com"
    func setup(_ name: String) throws -> (Store, CalendarCache, CalendarOutbox) {
        let store = Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true, primary: true)])
        return (store, cache, CalendarOutbox(store: store))
    }
    let cal = AppTime.calendar
    let day = cal.date(byAdding: .day, value: 4, to: cal.startOfDay(for: Date()))!
    func at(_ h: Int, _ m: Int = 0, plusDays: Int = 0) -> Date {
        cal.date(byAdding: .day, value: plusDays, to: cal.date(bySettingHour: h, minute: m, second: 0, of: day)!)!
    }
    func newTask(_ store: Store, _ title: String, due: Date?, hasTime: Bool = true) -> Int64 {
        store.add(title: title, area: store.areas.first?.name ?? "Work", importance: .medium, due: due, dueHasTime: hasTime && due != nil)
        return store.cards.last { $0.title == title }?.id ?? 0
    }
    func linkTask(_ store: Store, _ id: Int64, event: String, calendar: String = "me@example.com", synced: Bool = true) {
        let syncedAt = synced ? "\(Date().timeIntervalSince1970 - 3600)" : "NULL"
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='\(calendar)', gcal_event='\(event)', gcal_synced_at=\(syncedAt) WHERE id=\(id)")
        store.reload()
    }
    func cacheEvent(_ cache: CalendarCache, _ id: String, _ title: String, _ s: Date, _ e: Date, updated: Date, fb: Int64? = nil) {
        cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: id, cancelled: false,
            fields: CalEventFields(start: s, end: e, title: title, googleUpdated: updated, fbCard: fb))], nextToken: nil)
    }
    func methods(_ reqs: [URLRequest]) -> [String] { reqs.compactMap(\.httpMethod).filter { $0 != "GET" } }

    // F1. Per event, only the earliest unsent change may go: a later one waits while an earlier one is backing off.
    do {
        let (store, _, outbox) = try setup("f1-create-delete")
        let fake = FakeGoogle()
        var googleUp = false
        fake.handler = { r in
            guard googleUp else { return (#"{"error":"backendError"}"#, 500) }
            if r.httpMethod == "DELETE" { return ("", 204) }
            let body = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] // try?-ok: an empty body fails the check
            return (eventJSON(id: body["id"] as? String ?? "x", title: "Call", start: "2030-01-01T10:00:00Z", end: "2030-01-01T10:30:00Z", updated: "2020-01-01T00:00:00Z"), 200)
        }
        let sender = CalendarSender(store: store, apiFor: { _ in fake.api() }, isOnline: { true })
        let id = newTask(store, "Call the bank", due: at(10))
        if let c = store.card(id) { store.addToCalendar(c, account: acct, addMeet: false) }
        await sender.drain()                         // the create fails and backs off
        if let c = store.card(id) { store.delete(c) } // the task goes: its event (not made yet) is to be deleted
        store.performForTest("UPDATE cal_outbox SET next_try=0 WHERE kind='delete'")   // the Undo window is over
        await sender.drain()
        let early = methods(fake.requests)
        googleUp = true
        store.performForTest("UPDATE cal_outbox SET next_try=0")
        await sender.drain()
        await sender.drain()
        check(early == ["POST"] && methods(fake.requests) == ["POST", "POST", "DELETE"] && outbox.rows(unsent: true).isEmpty,
              "f1_delete_waits_for_the_failed_create_of_its_event")
    } catch { check(false, "f1 create/delete: \(error)") }
    do {
        let (store, cache, outbox) = try setup("f1-patch-patch")
        let old = Date().addingTimeInterval(-86400)
        cacheEvent(cache, "pa", "Review", at(9), at(10), updated: old)
        let fake = FakeGoogle()
        fake.handler = { r in
            let body = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] // try?-ok: an empty body fails the check
            if r.httpMethod == "PATCH", body["summary"] as? String == "Review A" { return (#"{"error":"backendError"}"#, 500) }
            return (eventJSON(id: "pa", title: body["summary"] as? String ?? "Review", start: GoogleTimes.rfc(at(9)), end: GoogleTimes.rfc(at(10)),
                              updated: GoogleTimes.rfc(old)), 200)
        }
        outbox.enqueue(.patch(eventID: "pa", title: "Review A", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct,
                       now: Date().addingTimeInterval(-2))
        outbox.enqueue(.patch(eventID: "pa", title: "Review B", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct,
                       now: Date().addingTimeInterval(-1))
        let sender = CalendarSender(store: store, apiFor: { _ in fake.api() }, isOnline: { true })
        await sender.drain()
        let patches = fake.requests.filter { $0.httpMethod == "PATCH" }
        check(patches.count == 1 && outbox.rows(unsent: true).count == 2, "f1_newer_patch_waits_for_the_failed_older_one")
    } catch { check(false, "f1 patch/patch: \(error)") }

    // F2. A delete Undo took back while another change was on the wire is not sent: each row is read again just before sending.
    do {
        let (store, cache, outbox) = try setup("f2-undo")
        let old = Date().addingTimeInterval(-86400)
        let id = newTask(store, "Dentist", due: at(15))
        linkTask(store, id, event: "y1")
        cacheEvent(cache, "y1", "Dentist", at(15), at(15, 30), updated: old, fb: id)
        cacheEvent(cache, "x1", "Standup", at(9), at(9, 15), updated: old)
        outbox.enqueue(.patch(eventID: "x1", title: "Standup (moved)", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct,
                       now: Date().addingTimeInterval(-5))
        if let c = store.card(id) { store.delete(c) }
        store.performForTest("UPDATE cal_outbox SET next_try=0 WHERE kind='delete'")   // the delete is due, behind the slow patch
        let gated = GatedGoogle()
        gated.handler = { r in
            if r.httpMethod == "DELETE" { return ("", 204) }
            return (eventJSON(id: "x1", title: "Standup (moved)", start: GoogleTimes.rfc(at(9)), end: GoogleTimes.rfc(at(9, 15)), updated: GoogleTimes.rfc(old)), 200)
        }
        gated.holdFirst = { $0.url?.path.hasSuffix("/x1") == true }
        let sender = CalendarSender(store: store, apiFor: { _ in gated.api() }, isOnline: { true })
        let run = Task { await sender.drain() }
        var waited = 0
        while !gated.held && waited < 300 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        let wasHeld = gated.held
        store.undoDelete()                            // Undo while the patch is on the wire
        gated.release()
        await run.value
        let linked = ((try? store.db.query("SELECT gcal_event FROM cards WHERE id=?", [id]) { DB.text($0, 0) }) ?? []).first // try?-ok: nil fails the check
        check(wasHeld && !gated.requests.contains { $0.httpMethod == "DELETE" } && store.card(id) != nil && linked == "y1"
              && outbox.rows(unsent: true).isEmpty, "f2_undo_during_a_slow_send_keeps_the_event")
    } catch { check(false, "f2 undo race: \(error)") }

    // F3. Tasks linked to an event by an earlier version: the first sync after the upgrade changes neither side; it notes the
    //     difference once. From then on the side that changes wins.
    do {
        let (store, cache, outbox) = try setup("f3-legacy")
        let long = Date().addingTimeInterval(-2 * 86400)
        let id = newTask(store, "Renamed task", due: at(10))
        // As version 10 left it: the link without a calendar or sync time, and the edit recorded only as "edited".
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='', gcal_event='lg1', gcal_synced_at=NULL WHERE id=\(id)")
        store.performForTest("DELETE FROM events WHERE card_id=\(id) AND kind<>'created'")
        store.performForTest("INSERT INTO events(card_id, at, kind, actor, uuid) VALUES(\(id), \(Date().timeIntervalSince1970 - 3600), 'edited', 'user', 'legacy-edit-\(id)')")
        let cleared = newTask(store, "Cleared due", due: nil)
        store.performForTest("UPDATE cards SET gcal_account='\(acct)', gcal_calendar='', gcal_event='lg2', gcal_synced_at=NULL WHERE id=\(cleared)")
        store.reload()
        cacheEvent(cache, "lg1", "Old title", at(9), at(9, 30), updated: long, fb: id)
        cacheEvent(cache, "lg2", "Cleared due", at(11), at(11, 30), updated: long, fb: cleared)
        TaskEventRules.reconcile(store: store, cache: cache, now: Date())
        TaskEventRules.reconcile(store: store, cache: cache, now: Date().addingTimeInterval(60))
        let a = store.card(id), b = store.card(cleared)
        let notes = store.recentActivity(limit: 50).filter { $0.message.contains("differ; kept both") }
        check(a?.title == "Renamed task" && a?.due == at(10) && b?.due == nil && outbox.rows(unsent: true).isEmpty,
              "f3_first_sync_after_upgrade_changes_neither_side")
        check(notes.count == 2 && notes.contains { $0.message.hasPrefix("T-\(id) ") } && notes.allSatisfy { $0.level == .info },
              "f3_difference_noted_once_per_task")
        // Google renames the event later: that newer change wins, and the task keeps its own time.
        cacheEvent(cache, "lg1", "Google title", at(9), at(9, 30), updated: Date().addingTimeInterval(120), fb: id)
        TaskEventRules.reconcile(store: store, cache: cache, now: Date().addingTimeInterval(180))
        check(store.card(id)?.title == "Google title" && store.card(id)?.due == at(10) && outbox.rows(unsent: true).isEmpty,
              "f3_later_google_change_wins")
        // The board moves the task later: that newer change goes to Google.
        if var c = store.card(id) { c.due = at(14); store.update(c, now: Date().addingTimeInterval(240)) }
        var moved = false
        if case .patch(_, _, let s?, _, _)? = outbox.rows(unsent: true).first?.write { moved = s == at(14) }
        check(moved, "f3_later_board_change_wins")
    } catch { check(false, "f3 legacy: \(error)") }

    // F4. A change queued offline does not overwrite a newer change made in Google meanwhile: the event is read first, Google's
    //     newer fields are kept (dropped from the change), the rest is sent only if the event is still as read (If-Match).
    do {
        let (store, cache, outbox) = try setup("f4-offline")
        let long = Date().addingTimeInterval(-86400), t1 = Date().addingTimeInterval(-600), t2 = Date().addingTimeInterval(-60)
        let id = newTask(store, "Plan", due: at(9))
        linkTask(store, id, event: "f4a")
        cacheEvent(cache, "f4a", "Plan", at(9), at(10), updated: long, fb: id)
        if var c = store.card(id) { c.title = "Plan (mine)"; store.update(c, now: t1) }   // edited offline at t1
        let fake = FakeGoogle()
        fake.handler = { r in
            if r.httpMethod == "GET" {   // Google renamed it at t2, after the board's edit
                return (eventJSON(id: "f4a", title: "Plan (theirs)", start: GoogleTimes.rfc(at(9)), end: GoogleTimes.rfc(at(10)),
                                  updated: GoogleTimes.rfc(t2), etag: "\"e2\""), 200)
            }
            return (eventJSON(id: "f4a", title: "Plan (mine)", start: GoogleTimes.rfc(at(9)), end: GoogleTimes.rfc(at(10)), updated: GoogleTimes.rfc(Date())), 200)
        }
        let sender = CalendarSender(store: store, apiFor: { _ in fake.api() }, isOnline: { true })
        await sender.drain()
        TaskEventRules.reconcile(store: store, cache: cache, now: Date())
        check(!fake.requests.contains { $0.httpMethod == "PATCH" } && outbox.rows(unsent: true).isEmpty
              && cache.event(account: acct, calendarID: acct, eventID: "f4a")?.title == "Plan (theirs)" && store.card(id)?.title == "Plan (theirs)",
              "f4_newer_google_title_beats_an_older_offline_rename")

        // Title and time queued; Google changed only the title: the time goes, without the title, on condition of the read ETag.
        cacheEvent(cache, "f4b", "Sync", at(11), at(12), updated: long)
        outbox.enqueue(.patch(eventID: "f4b", title: "Sync (mine)", start: at(13), end: at(14), allDayStart: nil), account: acct, calendarID: acct, now: t1)
        let fake2 = FakeGoogle()
        fake2.handler = { r in
            if r.httpMethod == "GET" {
                return (eventJSON(id: "f4b", title: "Sync (theirs)", start: GoogleTimes.rfc(at(11)), end: GoogleTimes.rfc(at(12)),
                                  updated: GoogleTimes.rfc(t2), etag: "\"e7\""), 200)
            }
            return (eventJSON(id: "f4b", title: "Sync (theirs)", start: GoogleTimes.rfc(at(13)), end: GoogleTimes.rfc(at(14)), updated: GoogleTimes.rfc(Date())), 200)
        }
        await CalendarSender(store: store, apiFor: { _ in fake2.api() }, isOnline: { true }).drain()
        let patch = fake2.requests.first { $0.httpMethod == "PATCH" }
        let body = (patch?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] // try?-ok: empty fails the check
        check(patch != nil && body["summary"] == nil && body["start"] != nil && body["end"] != nil
              && patch?.value(forHTTPHeaderField: "If-Match") == "\"e7\"" && outbox.rows(unsent: true).isEmpty, "f4_patch_drops_googles_newer_fields_and_sends_if_match")

        // Changed in Google between the read and the send (412): read again next run, not an error.
        cacheEvent(cache, "f4c", "Lunch", at(12), at(13), updated: long)
        outbox.enqueue(.patch(eventID: "f4c", title: "Lunch (mine)", start: nil, end: nil, allDayStart: nil), account: acct, calendarID: acct, now: t1)
        let fake3 = FakeGoogle()
        fake3.handler = { r in
            if r.httpMethod == "PATCH" { return (#"{"error":{"code":412,"message":"Precondition Failed"}}"#, 412) }
            return (eventJSON(id: "f4c", title: "Lunch", start: GoogleTimes.rfc(at(12)), end: GoogleTimes.rfc(at(13)), updated: GoogleTimes.rfc(long)), 200)
        }
        let before = store.recentActivity(limit: 200).filter { $0.level != .info }.count
        await CalendarSender(store: store, apiFor: { _ in fake3.api() }, isOnline: { true }).drain()
        let row = outbox.rows(unsent: true).first
        check(fake3.requests.contains { $0.httpMethod == "PATCH" } && row?.failedAt == nil && row?.attempts == 0
              && outbox.due(now: Date().addingTimeInterval(1)).count == 1
              && store.recentActivity(limit: 200).filter { $0.level != .info }.count == before, "f4_precondition_failed_is_retried_quietly")
    } catch { check(false, "f4 offline: \(error)") }

    // F5. Moving a date-only task keeps its all-day event's length in days (a 3-day event stays 3 days), from a board edit
    //     and from the sync.
    do {
        let (store, cache, outbox) = try setup("f5-multiday")
        let long = Date().addingTimeInterval(-86400)
        func days(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day)! }
        func allDay(_ id: String, _ title: String, from: Int, count: Int, fb: Int64) {
            cache.apply(account: acct, calendarID: acct, changes: [GoogleEventChange(eventID: id, cancelled: false,
                fields: CalEventFields(start: days(from), end: days(from + count), allDay: true, startDay: Due.dayString(days(from)),
                                       endDay: Due.dayString(days(from + count)), title: title, googleUpdated: long, fbCard: fb))], nextToken: nil)
        }
        func patchedSpan(_ eventID: String) -> (String?, Date?)? {
            for r in outbox.rows(unsent: true) { if case .patch(let id, _, _, let e, let d)? = r.write, id == eventID { return (d, e) } }
            return nil
        }
        let a = newTask(store, "Conference", due: day, hasTime: false)
        linkTask(store, a, event: "md1")
        allDay("md1", "Conference", from: 0, count: 3, fb: a)
        if var c = store.card(a) { c.due = days(5); store.update(c) }
        let board = patchedSpan("md1")
        check(board?.0 == Due.dayString(days(5)) && board?.1 == days(8), "f5_board_move_keeps_a_3_day_event_3_days")

        let b = newTask(store, "Offsite", due: day, hasTime: false)
        linkTask(store, b, event: "md2")
        allDay("md2", "Offsite", from: 0, count: 3, fb: b)
        // The board's newer date, not yet sent (as after a failed send that Google later refused): the sync queues it.
        store.performForTest("UPDATE cards SET due=\(days(2).timeIntervalSince1970), due_day='\(Due.dayString(days(2)))', due_has_time=0 WHERE id=\(b)")
        store.performForTest("INSERT INTO events(card_id, at, kind, actor, uuid) VALUES(\(b), \(Date().timeIntervalSince1970), 'due: moved', 'user', 'f5-\(b)')")
        store.reload()
        TaskEventRules.reconcile(store: store, cache: cache, now: Date())
        let synced = patchedSpan("md2")
        check(synced?.0 == Due.dayString(days(2)) && synced?.1 == days(5), "f5_sync_move_keeps_a_3_day_event_3_days")
    } catch { check(false, "f5 multiday: \(error)") }

    // F6. The event panel saves only the fields the user changed since it opened, on top of the event as it is now.
    do {
        let (store, cache, outbox) = try setup("f6-panel")
        cacheEvent(cache, "p6", "Design review", at(10), at(11), updated: Date().addingTimeInterval(-3600))
        guard let openedEvent = cache.event(account: acct, calendarID: acct, eventID: "p6") else { check(false, "f6 setup"); return }
        let opened = EventPanelEdit.Fields(openedEvent)
        // While the panel is open, Google moves the event to 12:00-13:00.
        cacheEvent(cache, "p6", "Design review", at(12), at(13), updated: Date())
        guard let current = cache.event(account: acct, calendarID: acct, eventID: "p6") else { check(false, "f6 setup 2"); return }
        var endOnly = opened; endOnly.end = at(14)
        let c1 = EventPanelEdit.changes(event: current, opened: opened, now: endOnly)
        if let m = c1.move { store.moveCalendarEvent(current, start: m.start, end: m.end) }
        var sent: (Date?, Date?)?
        if case .patch(_, nil, let st, let en, nil)? = outbox.rows(unsent: true).first?.write { sent = (st, en) }
        check(c1.move?.start == at(12) && c1.move?.end == at(14) && sent != nil && sent?.0 == nil && sent?.1 == at(14),
              "f6_end_only_edit_keeps_googles_new_start_and_sends_only_the_end")
        // Google moves it to the next day; the user changes only the start time: the new day stays.
        cacheEvent(cache, "p6", "Design review", at(10, plusDays: 1), at(11, plusDays: 1), updated: Date())
        guard let moved = cache.event(account: acct, calendarID: acct, eventID: "p6") else { check(false, "f6 setup 3"); return }
        var startOnly = opened; startOnly.start = at(9)
        let c2 = EventPanelEdit.changes(event: moved, opened: opened, now: startOnly)
        check(c2.move?.start == at(9, plusDays: 1) && c2.move?.end == at(10, plusDays: 1), "f6_clock_only_edit_keeps_googles_new_day")
    } catch { check(false, "f6 panel: \(error)") }

    // F7. New events go to the calendar Google flags as the account's main one, never to another owned calendar; without the
    //     calendar list the main calendar is addressed as "primary", and is renamed to its real id once the list comes.
    do {
        let (store, cache, outbox) = try setup("f7-primary")
        let who = "person@example.com"
        let listed = FakeGoogle()
        listed.handler = { r in
            if r.url?.path.hasSuffix("/users/me/calendarList") == true {
                return (##"{"items":[{"id":"alpha-team-id","summary":"Alpha team","accessRole":"owner","backgroundColor":"#111111"},{"id":"main-id-123","summary":"Me","accessRole":"owner","primary":true,"backgroundColor":"#222222"}]}"##, 200)
            }
            return (#"{"items":[],"nextSyncToken":"T"}"#, 200)
        }
        await CalendarSync(store: store, apiFor: { _ in listed.api() }, accounts: { [who] }).tick()
        let id = newTask(store, "Write report", due: at(10))
        if let c = store.card(id) { store.addToCalendar(c, account: who, addMeet: false) }
        let target = outbox.rows(unsent: true).first { $0.account == who }?.calendarID
        check(store.newEventCalendar(account: who)?.calendarID == "main-id-123" && target == "main-id-123", "f7_new_events_use_googles_flagged_primary")
        _ = cache
        CalendarListAttempts.forget(who)
    } catch { check(false, "f7 primary: \(error)") }
    do {
        let (store, cache, outbox) = try setup("f7-alias")
        let who = "fallback@example.com"
        let fake = FakeGoogle()
        var listOK = false
        fake.handler = { r in
            if r.url?.path.hasSuffix("/users/me/calendarList") == true {
                return listOK ? (##"{"items":[{"id":"real-main-id","summary":"Main","accessRole":"owner","primary":true,"backgroundColor":"#333333"}]}"##, 200)
                              : (##"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions"}]}}"##, 403)
            }
            return (#"{"items":[{"id":"ev9","status":"confirmed","summary":"Check-in","start":{"dateTime":"2030-01-01T10:00:00Z"},"end":{"dateTime":"2030-01-01T10:30:00Z"},"updated":"2026-11-16T10:00:00Z"}],"nextSyncToken":"T"}"#, 200)
        }
        let sync = CalendarSync(store: store, apiFor: { _ in fake.api() }, accounts: { [who] })
        await sync.tick()
        let before = cache.calendars().filter { $0.account == who }.map(\.calendarID)
        let readPrimary = fake.requests.contains { $0.url?.path.contains("/calendars/primary/events") == true }
        let shortID = cache.event(account: who, calendarID: "primary", eventID: "ev9")?.shortID
        let id = newTask(store, "Check-in", due: at(10))
        store.performForTest("UPDATE cards SET gcal_account='\(who)', gcal_calendar='primary', gcal_event='ev9' WHERE id=\(id)")
        outbox.enqueue(.patch(eventID: "ev9", title: "Check-in (moved)", start: nil, end: nil, allDayStart: nil), account: who, calendarID: "primary")
        check(before == ["primary"] && readPrimary && shortID != nil && store.newEventCalendar(account: who)?.calendarID == "primary",
              "f7_without_the_list_the_main_calendar_is_addressed_as_primary")
        CalendarListAttempts.forget(who)   // a new sign-in with the list permission
        listOK = true
        await sync.tick()
        let after = cache.calendars().filter { $0.account == who }
        let cardCal = ((try? store.db.query("SELECT gcal_calendar FROM cards WHERE id=?", [id]) { DB.text($0, 0) }) ?? []).first // try?-ok: nil fails the check
        let evs = (try? store.db.query("SELECT calendar_id, short_id FROM cal_events WHERE account=? AND event_id='ev9'", [who]) { (DB.text($0, 0), DB.int($0, 1)) }) ?? [] // try?-ok: empty fails the check
        check(after.map(\.calendarID) == ["real-main-id"] && after.first?.primary == true && after.first?.syncToken != nil
              && evs.count == 1 && evs.first?.0 == "real-main-id" && evs.first?.1 == shortID && cardCal == "real-main-id"
              && outbox.rows(unsent: true).first { $0.account == who }?.calendarID == "real-main-id"
              && store.newEventCalendar(account: who)?.calendarID == "real-main-id", "f7_primary_alias_rekeyed_to_the_real_id_without_duplicates")
        CalendarListAttempts.forget(who)
    } catch { check(false, "f7 alias: \(error)") }

    // F8. What a sign-in connects follows the permissions Google says were granted (people can untick some): Calendar only
    //     with calendar.events, Gmail only with gmail.modify, and the message says exactly what got connected.
    do {
        let gm = "https://www.googleapis.com/auth/gmail.modify", ev = "https://www.googleapis.com/auth/calendar.events"
        let ls = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
        var all = true
        for gmailAsked in [true, false] {
            for g in [true, false] { for e in [true, false] { for l in [true, false] {
                if !gmailAsked && g { continue }
                let scope = (["openid", "https://www.googleapis.com/auth/userinfo.email"] + (g ? [gm] : []) + (e ? [ev] : []) + (l ? [ls] : [])).joined(separator: " ")
                let d = GoogleAuthConfig.granted(scope: scope, gmailAsked: gmailAsked)
                let m = GoogleAuthConfig.connectedMessage(email: "a@example.com", granted: d, gmailAsked: gmailAsked)
                let ok = d.calendar == e && d.gmail == (gmailAsked && g) && d.calendarList == (e && l)
                    && m.contains("a@example.com")
                    && (e ? m.contains("Calendar") && !m.contains("Calendar was not allowed") : m.contains("not") && m.contains("Calendar"))
                    && (!gmailAsked || (g ? m.contains("Gmail") && !m.contains("Gmail was not allowed") : m.contains("Gmail was not allowed") || m.contains("Gmail or Calendar")))
                    && (!e || l || m.contains("main calendar only"))
                if !ok { all = false; print("  f8 combination gmailAsked=\(gmailAsked) gmail=\(g) events=\(e) list=\(l): \(d) \"\(m)\"") }
            } } }
        }
        let none = GoogleAuthConfig.granted(scope: nil, gmailAsked: true)
        check(all && !none.calendar && !none.gmail, "f8_every_partial_consent_connects_only_what_was_granted")
    }

    await codexRound2Checks(setup: setup, at: { at($0, $1, plusDays: $2) }, newTask: newTask, linkTask: { linkTask($0, $1, event: $2) })
}

/// A Google event as the API returns it.
func eventJSON(id: String, title: String, start: String, end: String, updated: String, etag: String = "\"e1\"") -> String {
    let obj: [String: Any] = ["id": id, "summary": title, "status": "confirmed", "etag": etag, "updated": updated,
                              "start": ["dateTime": start], "end": ["dateTime": end]]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), as: UTF8.self) // try?-ok: constant shapes; "" fails the check
}

enum GoogleTimes {
    static func rfc(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")!
        return f.string(from: d)
    }
}

/// A fake Google that can hold one request until `release()`, to play a slow network.
final class GatedGoogle: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private var _held = false
    private var released = false
    var handler: (URLRequest) -> (String, Int) = { _ in ("{}", 200) }
    /// The first request this says yes to is held.
    var holdFirst: (URLRequest) -> Bool = { _ in false }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var held: Bool { lock.withLock { _held } }

    func release() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { released = true; let c = waiting; waiting = nil; return c }
        c?.resume()
    }

    func api() -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { [self] req in
            let hold: Bool = lock.withLock {
                _requests.append(req)
                if !_held && !released && holdFirst(req) { _held = true; return true }
                return false
            }
            if hold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let now: Bool = lock.withLock { if released { return true }; waiting = c; return false }
                    if now { c.resume() }
                }
            }
            let (body, status) = handler(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}

/// Round 2 of the Codex review (N1-N4).
@MainActor private func codexRound2Checks(setup: (String) throws -> (Store, CalendarCache, CalendarOutbox), at: (Int, Int, Int) -> Date,
                                          newTask: (Store, String, Date?, Bool) -> Int64, linkTask: (Store, Int64, String) -> Void) async {
    let acct = "me@example.com"
    let old = Date().addingTimeInterval(-86400)
    func cacheEvent(_ cache: CalendarCache, _ id: String, _ title: String, _ s: Date, _ e: Date, updated: Date, fb: Int64? = nil, calendar: String = "me@example.com") {
        cache.apply(account: acct, calendarID: calendar, changes: [GoogleEventChange(eventID: id, cancelled: false,
            fields: CalEventFields(start: s, end: e, title: title, googleUpdated: updated, fbCard: fb))], nextToken: nil)
    }

    // N1. Two board edits of the same field queued before a send: sending the first must not make the second look older than
    //     Google (Google's newer time there is FloatBoard's own write). The fake keeps the event and moves `updated` on PATCH.
    do {
        let (store, cache, outbox) = try setup("n1-stateful")
        let id = newTask(store, "Draft", at(9, 0, 0), true)
        linkTask(store, id, "s1")
        cacheEvent(cache, "s1", "Draft", at(9, 0, 0), at(9, 30, 0), updated: old, fb: id)
        let server = StatefulEvent(id: "s1", title: "Draft", start: at(9, 0, 0), end: at(9, 30, 0), updated: old)
        if var c = store.card(id) { c.title = "Draft A"; store.update(c, now: Date().addingTimeInterval(-2)) }
        if var c = store.card(id) { c.title = "Draft B"; store.update(c, now: Date().addingTimeInterval(-1)) }
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        TaskEventRules.reconcile(store: store, cache: cache, now: Date())
        check(server.title == "Draft B" && outbox.rows(unsent: true).isEmpty && store.card(id)?.title == "Draft B"
              && cache.event(account: acct, calendarID: acct, eventID: "s1")?.title == "Draft B", "n1_second_queued_edit_is_not_dropped_after_the_first_is_sent")
        // A real change in Google after FloatBoard's own write still wins over an older queued edit.
        if var c = store.card(id) { c.title = "Draft C"; store.update(c, now: Date().addingTimeInterval(-1)) }
        server.externalEdit(title: "Draft (theirs)")
        await CalendarSender(store: store, apiFor: { _ in server.api() }, isOnline: { true }).drain()
        check(server.title == "Draft (theirs)" && outbox.rows(unsent: true).isEmpty, "n1_external_change_after_own_write_still_wins")
    } catch { check(false, "n1: \(error)") }

    // N2. Google changed only the end; the board moved the start: the board's start goes, with Google's new length.
    do {
        let base = CalPatchBase(title: "Call", start: at(10, 0, 0), end: at(11, 0, 0), allDay: false)
        let current = CalEventFields(start: at(10, 0, 0), end: at(12, 0, 0), title: "Call", googleUpdated: Date())
        let w = CalendarOutbox.withoutNewerGoogleFields(.patch(eventID: "c", title: nil, start: at(14, 0, 0), end: at(14, 30, 0), allDayStart: nil),
                                                        queuedAt: Date().addingTimeInterval(-60), base: base, current: current)
        var kept = false
        if case .patch(_, nil, let st?, let en, nil)? = w { kept = st == at(14, 0, 0) && en == at(16, 0, 0) }
        // Google changed only the start; the board changed only the end: the end goes.
        let current2 = CalEventFields(start: at(9, 30, 0), end: at(11, 0, 0), title: "Call", googleUpdated: Date())
        let w2 = CalendarOutbox.withoutNewerGoogleFields(.patch(eventID: "c", title: nil, start: nil, end: at(11, 30, 0), allDayStart: nil),
                                                         queuedAt: Date().addingTimeInterval(-60), base: base, current: current2)
        // Turning a timed event all-day while Google changed its time: Google's newer time is kept whole.
        let w3 = CalendarOutbox.withoutNewerGoogleFields(.patch(eventID: "c", title: nil, start: nil, end: nil, allDayStart: "2030-01-02"),
                                                         queuedAt: Date().addingTimeInterval(-60), base: base, current: current)
        check(kept && w2 == .patch(eventID: "c", title: nil, start: nil, end: at(11, 30, 0), allDayStart: nil) && w3 == nil,
              "n2_start_and_end_are_merged_independently")
    }

    // N3. Re-keying the "primary" stand-in when the same event is already kept under the real id: links to the stand-in's
    //     E-n move to the surviving one.
    do {
        let (store, cache, _) = try setup("n3-links")
        let who = "dup@example.com"
        cache.upsertCalendars(account: who, [CalCalendar(account: who, calendarID: CalendarCache.primaryAlias, name: "Main calendar",
                                                         color: "#9aa0a6", owned: true, shown: true, primary: true)])
        func put(_ cal: String, _ id: String) {
            cache.apply(account: who, calendarID: cal, changes: [GoogleEventChange(eventID: id, cancelled: false,
                fields: CalEventFields(start: at(10, 0, 0), end: at(11, 0, 0), title: id, googleUpdated: old))], nextToken: nil)
        }
        put(CalendarCache.primaryAlias, "dupev"); put("real-id", "dupev"); put(CalendarCache.primaryAlias, "other")
        guard let alias = cache.event(account: who, calendarID: CalendarCache.primaryAlias, eventID: "dupev"),
              let real = cache.event(account: who, calendarID: "real-id", eventID: "dupev"),
              let other = cache.event(account: who, calendarID: CalendarCache.primaryAlias, eventID: "other") else { check(false, "n3 setup"); return }
        let task = newTask(store, "Prep", nil, false)
        store.link(alias.id, ShortID(kind: .task, number: task), actor: .user)
        store.link(alias.id, other.id, actor: .user)
        store.link(alias.id, real.id, actor: .user)   // becomes a link to itself: dropped
        cache.upsertCalendars(account: who, [CalCalendar(account: who, calendarID: "real-id", name: "Main", color: "#111111", owned: true, shown: true, primary: true)])
        let survivors = Set(store.links(of: real.id))
        check(store.links(of: alias.id).isEmpty && survivors == [ShortID(kind: .task, number: task), other.id]
              && store.links(of: other.id) == [real.id], "n3_rekey_collision_moves_links_to_the_surviving_event")
    } catch { check(false, "n3: \(error)") }

}

/// A fake Google holding one event: GET returns it, PATCH changes it and moves `updated` on (as Google does).
final class StatefulEvent: @unchecked Sendable {
    let id: String
    var title: String, start: Date, end: Date, updated: Date
    private var version = 1
    init(id: String, title: String, start: Date, end: Date, updated: Date) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.updated = updated
    }
    private func tick() { updated = max(Date(), updated.addingTimeInterval(1)); version += 1 }
    func externalEdit(title: String) { self.title = title; tick() }
    func api() -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { [self] req in
            var status = 200
            if req.httpMethod == "PATCH" {
                if let m = req.value(forHTTPHeaderField: "If-Match"), m != "\"v\(version)\"" { status = 412 } else {
                    let body = (req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] // try?-ok: an empty body changes nothing
                    if let t = body["summary"] as? String { title = t }
                    if let s = (body["start"] as? [String: Any])?["dateTime"] as? String, let d = ISO8601DateFormatter().date(from: s) { start = d }
                    if let e = (body["end"] as? [String: Any])?["dateTime"] as? String, let d = ISO8601DateFormatter().date(from: e) { end = d }
                    tick()
                }
            }
            let json = status == 412 ? #"{"error":{"code":412}}"# : eventJSON(id: id, title: title, start: GoogleTimes.rfc(start), end: GoogleTimes.rfc(end),
                                                                            updated: GoogleTimes.rfc(updated), etag: "\"v\(version)\"")
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
}
