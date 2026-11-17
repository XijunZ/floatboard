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
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: acct, name: "Me", color: "#112233", owned: true, shown: true)])
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
