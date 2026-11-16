import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// The calendar sender against a fake Google (no network): success, failure, retry safety, lost sign-in.
@MainActor func calendarSenderChecks() async {
    final class Fake: @unchecked Sendable {
        var requests: [URLRequest] = []
        var handler: (URLRequest) -> (String, Int) = { _ in ("{}", 200) }
        var gate: (() async -> Void)?
    }
    let eventJSON = #"{"id":"EID","status":"confirmed","summary":"Plan","start":{"dateTime":"2026-11-20T10:00:00Z"},"end":{"dateTime":"2026-11-20T11:00:00Z"},"updated":"2026-11-16T10:00:00Z","htmlLink":"https://cal.example/x"}"#
    let acct = "me@example.com", cal = "primary"
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func fields(_ t: String) -> CalEventFields { CalEventFields(start: base, end: base.addingTimeInterval(1800), title: t, googleUpdated: base) }
    func makeAPI(_ fake: Fake) -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { req in
            fake.requests.append(req)
            await fake.gate?()
            let (body, status) = fake.handler(req)
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
    func setup(_ name: String, _ fake: Fake, connected: @escaping (String) -> Bool = { _ in true },
               signedOutWhenNotConnected: Bool = false) throws -> (Store, CalendarOutbox, CalendarCache, CalendarSender) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fb-calsender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(db: try DB(url: root.appendingPathComponent("\(name).sqlite")))
        let cache = CalendarCache(store: store)
        cache.upsertCalendars(account: acct, [CalCalendar(account: acct, calendarID: cal, name: "Me", color: "#112233", owned: true, shown: true)])
        let api = makeAPI(fake)
        let sender = CalendarSender(store: store, apiFor: { _ in
            signedOutWhenNotConnected && !connected(acct) ? GoogleCalendarAPI(token: { _ in throw GoogleCalendarError.notConnected(account: acct) }, http: { _ in throw GoogleCalendarError.badResponse("no") }) : api
        }, isConnected: connected)
        return (store, CalendarOutbox(store: store), cache, sender)
    }
    func idOf(_ r: URLRequest) -> String? { ((try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:])["id"] as? String } // try?-ok: nil fails the checks

    do {
        // 200 marks sent, creating with the fixed id from the outbox uuid.
        let fake = Fake()
        fake.handler = { _ in (eventJSON.replacingOccurrences(of: "EID", with: "g1"), 200) }
        let (_, outbox, cache, sender) = try setup("ok", fake)
        let u = outbox.enqueue(.create(fields("Plan"), cardID: nil, addMeet: false), account: acct, calendarID: cal)
        await sender.drain()
        check(outbox.rows(unsent: true).isEmpty && cache.event(account: acct, calendarID: cal, eventID: "g1") != nil
              && fake.requests.count == 1 && idOf(fake.requests[0]) == CalendarOutbox.googleEventID(forUUID: u)
              && idOf(fake.requests[0])?.count == 32 && idOf(fake.requests[0])?.contains("-") == false, "sender_200_marks_sent_with_fixed_id")

        // 500: kept, Google's body in last_error, backed off.
        let f2 = Fake(); f2.handler = { _ in (#"{"error":"backendError"}"#, 500) }
        let (s2, o2, _, sd2) = try setup("fail", f2)
        o2.enqueue(.delete(eventID: "x"), account: acct, calendarID: cal)
        await sd2.drain()
        let r2 = o2.rows(unsent: true).first
        let warned = s2.recentActivity(limit: 100).contains { $0.message.contains("Could not send") && ($0.detail ?? "").contains("backendError") }
        check(r2?.attempts == 1 && r2?.lastError.contains("backendError") == true && (r2?.nextTry.timeIntervalSinceNow ?? 0) > 30
              && o2.due(now: Date()).isEmpty && warned, "sender_500_backs_off_with_googles_body")

        // 401 twice: needs reconnect.
        let f3 = Fake(); f3.handler = { _ in (#"{"error":"unauthorized"}"#, 401) }
        let (_, o3, c3, sd3) = try setup("401", f3)
        o3.enqueue(.delete(eventID: "x"), account: acct, calendarID: cal)
        await sd3.drain()
        check(f3.requests.count == 2 && c3.calendars().first?.needsReconnect == true && o3.rows(unsent: true).first?.attempts == 1,
              "sender_401_twice_marks_calendar_needs_reconnect")

        // Unreadable row backs off.
        let f4 = Fake()
        let (s4, o4, _, sd4) = try setup("bad", f4)
        s4.performForTest("INSERT INTO cal_outbox(uuid,kind,account,calendar_id,payload_json,created,next_try) VALUES('bad','create','\(acct)','\(cal)','not json',1,1)")
        await sd4.drain()
        let r4 = o4.rows(unsent: true).first
        check(f4.requests.isEmpty && r4?.attempts == 1 && (r4?.nextTry.timeIntervalSinceNow ?? 0) > 30, "sender_unreadable_row_backs_off")

        // A second drain while one runs is skipped.
        let f5 = Fake(); f5.handler = { _ in (eventJSON.replacingOccurrences(of: "EID", with: "g5"), 200) }
        final class Gate: @unchecked Sendable { var cont: CheckedContinuation<Void, Never>?; var entered = false }
        let gate = Gate()
        f5.gate = { gate.entered = true; await withCheckedContinuation { gate.cont = $0 } }
        let (_, o5, _, sd5) = try setup("twice", f5)
        o5.enqueue(.create(fields("A"), cardID: nil, addMeet: false), account: acct, calendarID: cal)
        let first = Task { @MainActor in await sd5.drain() }
        while !gate.entered { await Task.yield() }
        await sd5.drain() // returns at once: one is already running
        let during = f5.requests.count
        f5.gate = nil
        gate.cont?.resume()
        await first.value
        check(during == 1 && f5.requests.count == 1 && o5.rows(unsent: true).isEmpty, "sender_second_drain_while_running_is_skipped")

        // Lost answer: Google already has the event (409) -> fetched and marked sent, no second event.
        let f6 = Fake()
        f6.handler = { r in r.httpMethod == "POST" ? (#"{"error":{"code":409,"message":"The requested identifier already exists."}}"#, 409)
                                                    : (eventJSON.replacingOccurrences(of: "EID", with: "g6"), 200) }
        let (_, o6, c6, sd6) = try setup("dup", f6)
        o6.enqueue(.create(fields("Plan"), cardID: nil, addMeet: false), account: acct, calendarID: cal)
        await sd6.drain()
        check(o6.rows(unsent: true).isEmpty && c6.event(account: acct, calendarID: cal, eventID: "g6") != nil
              && f6.requests.map { $0.httpMethod ?? "" } == ["POST", "GET"], "sender_409_fetches_existing_event_and_marks_sent")

        // The local save fails after Google accepted: the row stays unsent, backs off, and the retry reuses the same id (no second event).
        let f7 = Fake(); f7.handler = { _ in (eventJSON.replacingOccurrences(of: "EID", with: "g7"), 200) }
        let (s7, o7, _, sd7) = try setup("savefail", f7)
        o7.enqueue(.create(fields("Plan"), cardID: nil, addMeet: false), account: acct, calendarID: cal)
        s7.performForTest("CREATE TRIGGER block_sent BEFORE UPDATE OF sent ON cal_outbox BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        await sd7.drain()
        let stuck = o7.rows(unsent: true).first
        let firstID = idOf(f7.requests[0])
        s7.performForTest("DROP TRIGGER block_sent")
        f7.handler = { r in r.httpMethod == "POST" ? ("{}", 409) : (eventJSON.replacingOccurrences(of: "EID", with: "g7"), 200) }
        for r in o7.rows(unsent: true) { o7.markFailed(uuid: r.uuid, error: "", now: Date(timeIntervalSinceNow: -7200)) } // make it due again
        await sd7.drain()
        check(stuck != nil && stuck?.attempts == 1 && f7.requests.count == 3 && idOf(f7.requests[1]) == firstID && o7.rows(unsent: true).isEmpty,
              "sender_failed_local_save_stays_unsent_and_retry_is_safe")

        // Signed out: parked quietly (one Activity line, calendars flagged), resumes once connected.
        let f8 = Fake(); f8.handler = { _ in (eventJSON.replacingOccurrences(of: "EID", with: "g8"), 200) }
        var connected = false
        let (s8, o8, c8, sd8) = try setup("signedout", f8, connected: { _ in connected }, signedOutWhenNotConnected: true)
        o8.enqueue(.create(fields("Plan"), cardID: nil, addMeet: false), account: acct, calendarID: cal)
        await sd8.drain(); await sd8.drain(); await sd8.drain()
        let parkedLines = s8.recentActivity(limit: 100).filter { $0.message.contains("not connected any more") }.count
        check(c8.calendars().first?.needsReconnect == true && parkedLines == 1 && o8.rows(unsent: true).first?.attempts == 0,
              "sender_signed_out_account_is_parked_quietly")
        connected = true
        await sd8.drain()
        check(c8.calendars().first?.needsReconnect == false, "sender_parked_account_resumes_when_connected")
    } catch { check(false, "calendar sender checks: \(error)") }
}
