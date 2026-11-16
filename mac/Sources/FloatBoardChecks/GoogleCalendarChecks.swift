import Foundation
import FloatBoardCore
import FloatBoardConnectors

/// The Google Calendar client, fed saved Google responses through a fake HTTP layer (no network).
func googleCalendarChecks() async {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures")
    func raw(_ name: String) -> [String: Any] {
        guard let d = try? Data(contentsOf: fixtures.appendingPathComponent(name)), // try?-ok: a missing fixture fails the checks below
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] } // try?-ok: same
        return o
    }
    func data(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() } // try?-ok: empty data fails the checks below
    func resp(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    final class Log: @unchecked Sendable { var requests: [URLRequest] = [] }
    func api(_ log: Log = Log(), _ handler: @escaping @Sendable (URLRequest) -> (Data, Int)) -> GoogleCalendarAPI {
        GoogleCalendarAPI(token: { _ in "tok" }, http: { req in
            log.requests.append(req)
            let (d, s) = handler(req)
            return (d, resp(req.url!, s))
        })
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Calendar list.
    let list = api { _ in (data(raw("gcal-calendarlist.json")), 200) }
    if let cals = try? await list.listCalendars() { // try?-ok: nil fails the check
        check(cals.count == 3 && cals[0].id == "alex@example.com" && cals[0].primary && cals[0].owned
              && cals[0].color == "#9fe1e7" && cals[0].name == "Alex Example"
              && !cals[1].owned && !cals[1].primary && !cals[2].owned, "parse_calendar_list")
    } else { check(false, "parse_calendar_list") }

    // 403 insufficient scope.
    let denied = api { _ in (data(raw("gcal-403-scope.json")), 403) }
    do { _ = try await denied.listCalendars(); check(false, "calendar_list_403_marks_needs_reconnect") }
    catch let e as GoogleCalendarError { if case .needsReconnect(let b) = e { check(b.contains("insufficientPermissions"), "calendar_list_403_marks_needs_reconnect") }
        else { check(false, "calendar_list_403_marks_needs_reconnect") } }
    catch { check(false, "calendar_list_403_marks_needs_reconnect: \(error)") }
    let other403 = api { _ in (Data(#"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded"}]}}"#.utf8), 403) }
    do { _ = try await other403.listCalendars(); check(false, "other_403_is_http_error_with_body") }
    catch let e as GoogleCalendarError {
        if case .http(let s, let b) = e { check(s == 403 && b.contains("rateLimitExceeded"), "other_403_is_http_error_with_body") }
        else { check(false, "other_403_is_http_error_with_body") }
    } catch { check(false, "other_403_is_http_error_with_body") }

    // Events with paging.
    let pages = raw("gcal-events-page.json")
    let log = Log()
    let events = api(log) { req in
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let token = q.first { $0.name == "pageToken" }?.value
        return (data(token == "PageTokenExample2" ? pages["page2"]! : pages["page1"]!), 200)
    }
    do {
        let r = try await events.listEvents(calendarID: "alex@example.com", syncToken: nil,
                                            timeMin: t0, timeMax: t0.addingTimeInterval(86400 * 60))
        check(r.changes.count == 5 && r.nextToken == "SyncTokenExample1" && log.requests.count == 2, "parse_events_page_with_paging")
        let q = URLComponents(url: log.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(q.contains { $0.name == "singleEvents" && $0.value == "true" } && q.contains { $0.name == "timeMin" }
              && q.contains { $0.name == "timeMax" } && !q.contains { $0.name == "syncToken" }
              && log.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok", "events_request_shape")
        let timed = r.changes[0].fields
        check(r.changes[0].eventID == "evt1example" && timed?.title == "Design review" && timed?.allDay == false
              && timed?.start == Date(timeIntervalSince1970: 1_795_168_800) && timed?.end == Date(timeIntervalSince1970: 1_795_172_400)
              && timed?.location == "Room 4" && timed?.videoLink == "https://meet.google.com/abc-defg-hij" && timed?.fbCard == 42
              && timed?.htmlLink.contains("evt1example") == true, "timed_event_fields_mapped")
        let allDay = r.changes[1].fields
        check(allDay?.allDay == true && allDay?.startDay == "2026-11-23" && allDay?.endDay == "2026-11-25", "all_day_event_mapped")
        let rec = r.changes[2].fields
        check(rec?.recurringID == "evt3weekly", "recurring_instance_mapped")
        check(rec?.start == ISO8601DateFormatter().date(from: "2026-11-24T08:00:00Z"), "offset_datetime_parsed")
        check(timed?.googleUpdated == ISO8601DateFormatter().date(from: "2026-11-10T09:30:00Z")!.addingTimeInterval(0.123)
              || abs((timed?.googleUpdated.timeIntervalSince1970 ?? 0) - (ISO8601DateFormatter().date(from: "2026-11-10T09:30:00Z")!.timeIntervalSince1970 + 0.123)) < 0.01,
              "fractional_updated_parsed")
        check(r.changes[3].fields?.videoLink == "https://teams.example.com/meet/123"
              && r.changes[4].fields?.videoLink == "https://example.zoom.us/j/123456789?pwd=abc", "video_link_found_in_conference_and_description")
    } catch { check(false, "parse_events_page_with_paging: \(error)") }

    // Incremental sync: cancelled event, no time window sent with a sync token.
    let log2 = Log()
    let inc = api(log2) { _ in (data(raw("gcal-events-cancelled.json")), 200) }
    do {
        let r = try await inc.listEvents(calendarID: "primary", syncToken: "old", timeMin: t0, timeMax: t0.addingTimeInterval(86400))
        check(r.changes.count == 2 && r.changes[0].cancelled && r.changes[0].fields == nil && r.changes[0].eventID == "evt1example"
              && !r.changes[1].cancelled && r.changes[1].fields?.title == "Moved lunch" && r.nextToken == "SyncTokenExample2", "parse_cancelled_event")
        let q = URLComponents(url: log2.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(q.contains { $0.name == "syncToken" && $0.value == "old" } && !q.contains { $0.name == "timeMin" || $0.name == "timeMax" }
              && q.contains { $0.name == "showDeleted" && $0.value == "true" }, "sync_token_request_has_no_window")
    } catch { check(false, "parse_cancelled_event: \(error)") }

    // 410.
    let gone = api { _ in (data(raw("gcal-410.json")), 410) }
    do { _ = try await gone.listEvents(calendarID: "primary", syncToken: "old", timeMin: t0, timeMax: t0); check(false, "events_410_throws_sync_expired") }
    catch let e as GoogleCalendarError { check(e == .syncExpired, "events_410_throws_sync_expired") }
    catch { check(false, "events_410_throws_sync_expired: \(error)") }

    // Insert sets the card property, and a Meet request when asked.
    let log3 = Log()
    let ins = api(log3) { _ in (Data(#"{"id":"new1","status":"confirmed","summary":"Plan","start":{"dateTime":"2026-11-20T10:00:00Z"},"end":{"dateTime":"2026-11-20T11:00:00Z"},"updated":"2026-11-16T10:00:00Z","hangoutLink":"https://meet.google.com/zzz-yyyy-xxx","extendedProperties":{"private":{"floatboard_card":"7"}}}"#.utf8), 200) }
    do {
        let f = CalEventFields(start: t0, end: t0.addingTimeInterval(3600), title: "Plan", googleUpdated: t0)
        let r = try await ins.insert(calendarID: "primary", f, cardID: 7, addMeet: true)
        let body = (try? JSONSerialization.jsonObject(with: log3.requests[0].httpBody ?? Data()) as? [String: Any]) ?? [:] // try?-ok: empty body fails the checks below
        let priv = (body["extendedProperties"] as? [String: Any])?["private"] as? [String: Any]
        check(priv?["floatboard_card"] as? String == "7" && body["summary"] as? String == "Plan"
              && body["conferenceData"] != nil && log3.requests[0].httpMethod == "POST"
              && log3.requests[0].url?.query?.contains("conferenceDataVersion=1") == true
              && r.eventID == "new1" && r.fields.fbCard == 7 && r.fields.videoLink.contains("meet.google.com"), "insert_sets_floatboard_card_property")
        let bodyAD = CalEventFields(start: t0, end: t0, allDay: true, startDay: "2026-12-01", endDay: "2026-12-02", title: "Day", googleUpdated: t0)
        _ = try await ins.insert(calendarID: "primary", bodyAD, cardID: nil, addMeet: false)
        let b2 = (try? JSONSerialization.jsonObject(with: log3.requests[1].httpBody ?? Data()) as? [String: Any]) ?? [:] // try?-ok: same
        check((b2["start"] as? [String: Any])?["date"] as? String == "2026-12-01" && (b2["end"] as? [String: Any])?["date"] as? String == "2026-12-02"
              && b2["extendedProperties"] == nil && b2["conferenceData"] == nil, "insert_all_day_uses_dates")
    } catch { check(false, "insert_sets_floatboard_card_property: \(error)") }

    // A fixed event id is sent when given; get reads one event.
    do {
        let log5 = Log()
        let a5 = api(log5) { _ in (Data(#"{"id":"abc123","status":"confirmed","summary":"Plan","start":{"dateTime":"2026-11-20T10:00:00Z"},"end":{"dateTime":"2026-11-20T11:00:00Z"},"updated":"2026-11-16T10:00:00Z"}"#.utf8), 200) }
        let f = CalEventFields(start: t0, end: t0.addingTimeInterval(3600), title: "Plan", googleUpdated: t0)
        _ = try await a5.insert(calendarID: "primary", f, cardID: nil, addMeet: false, eventID: "abc123")
        let b = (try? JSONSerialization.jsonObject(with: log5.requests[0].httpBody ?? Data()) as? [String: Any]) ?? [:] // try?-ok: empty body fails the check
        let got = try await a5.get(calendarID: "primary", eventID: "abc123")
        check(b["id"] as? String == "abc123" && log5.requests[1].httpMethod == "GET"
              && log5.requests[1].url?.path.hasSuffix("/calendars/primary/events/abc123") == true && got.eventID == "abc123" && got.fields.title == "Plan",
              "insert_sends_fixed_event_id_and_get_reads_one")
    } catch { check(false, "insert_sends_fixed_event_id_and_get_reads_one: \(error)") }

    // Patch.
    let log4 = Log()
    let pat = api(log4) { _ in (Data(#"{"id":"e9","status":"confirmed","summary":"Renamed","start":{"date":"2026-12-03"},"end":{"date":"2026-12-04"},"updated":"2026-11-16T10:00:00Z"}"#.utf8), 200) }
    do {
        let r = try await pat.patch(calendarID: "primary", eventID: "e9", title: "Renamed", start: nil, end: nil, allDayStart: "2026-12-03")
        let b = (try? JSONSerialization.jsonObject(with: log4.requests[0].httpBody ?? Data()) as? [String: Any]) ?? [:] // try?-ok: same
        check(log4.requests[0].httpMethod == "PATCH" && b["summary"] as? String == "Renamed"
              && (b["start"] as? [String: Any])?["date"] as? String == "2026-12-03"
              && (b["end"] as? [String: Any])?["date"] as? String == "2026-12-04" && r.fields.allDay, "patch_sends_only_changed_fields")
        let bs = b["start"] as? [String: Any] ?? [:], be = b["end"] as? [String: Any] ?? [:]
        check(bs["dateTime"] is NSNull && bs["timeZone"] is NSNull && be["dateTime"] is NSNull && be["timeZone"] is NSNull,
              "patch_all_day_nulls_timed_form")
        _ = try await pat.patch(calendarID: "primary", eventID: "e9", title: nil, start: t0, end: t0.addingTimeInterval(3600), allDayStart: nil)
        let bt = (try? JSONSerialization.jsonObject(with: log4.requests[1].httpBody ?? Data()) as? [String: Any]) ?? [:] // try?-ok: same
        let ts = bt["start"] as? [String: Any] ?? [:], te = bt["end"] as? [String: Any] ?? [:]
        check(ts["date"] is NSNull && te["date"] is NSNull && ts["dateTime"] is String && te["dateTime"] is String && bt["summary"] == nil,
              "patch_timed_nulls_all_day_form")
    } catch { check(false, "patch_sends_only_changed_fields: \(error)") }

    // Delete.
    for (status, name) in [(404, "delete_404_is_success"), (410, "delete_410_is_success"), (204, "delete_204_is_success")] {
        let del = api { _ in (Data(), status) }
        do { try await del.delete(calendarID: "primary", eventID: "x"); check(true, name) } catch { check(false, "\(name): \(error)") }
    }
    let delBad = api { _ in (Data("nope".utf8), 500) }
    do { try await delBad.delete(calendarID: "primary", eventID: "x"); check(false, "delete_500_throws_with_body") }
    catch let e as GoogleCalendarError { check(e == .http(status: 500, body: "nope"), "delete_500_throws_with_body") }
    catch { check(false, "delete_500_throws_with_body") }

    // 401: a stale saved token gets exactly one forced refresh; a second 401 means reconnect.
    final class Refresh: @unchecked Sendable { var forced = 0, calls = 0 }
    let rf = Refresh()
    let stale = GoogleCalendarAPI(token: { force in if force { rf.forced += 1 }; return force ? "fresh" : "old" }, http: { req in
        rf.calls += 1
        let ok = req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
        return (ok ? data(raw("gcal-calendarlist.json")) : Data("expired".utf8), resp(req.url!, ok ? 200 : 401))
    })
    do {
        let cals = try await stale.listCalendars()
        check(cals.count == 3 && rf.forced == 1 && rf.calls == 2, "401_then_200_retries_once_with_fresh_token")
    } catch { check(false, "401_then_200_retries_once_with_fresh_token: \(error)") }
    let rf2 = Refresh()
    let revoked = GoogleCalendarAPI(token: { force in if force { rf2.forced += 1 }; return "t" }, http: { req in
        rf2.calls += 1
        return (Data("revoked".utf8), resp(req.url!, 401))
    })
    do { _ = try await revoked.listCalendars(); check(false, "401_twice_needs_reconnect") }
    catch let e as GoogleCalendarError { check(e == .needsReconnect(body: "revoked") && rf2.forced == 1 && rf2.calls == 2, "401_twice_needs_reconnect") }
    catch { check(false, "401_twice_needs_reconnect: \(error)") }

    // Scopes.
    check(GoogleAuthConfig.scopes.contains("https://www.googleapis.com/auth/calendar.calendarlist.readonly")
          && GoogleAuthConfig.scopes.contains("https://www.googleapis.com/auth/calendar.events"), "scopes_include_calendarlist_readonly")
}
