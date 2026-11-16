import Foundation
import FloatBoardCore

/// How requests reach Google. Tests pass a fake; the app uses the default over `URLSession.shared`.
public typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum GoogleCalendarError: Error, Equatable {
    /// Google refused our access (not signed in, or the calendar permission is missing): the user has to sign in again.
    case needsReconnect(body: String)
    /// The saved sync bookmark is too old (HTTP 410): forget it and read the whole window again.
    case syncExpired
    /// Any other failure, with Google's answer so the cause shows in Activity.
    case http(status: Int, body: String)
    case badResponse(String)
}

/// A calendar in the user's Google calendar list, before it is tied to an account.
public struct CalCalendarInfo: Equatable {
    public var id: String
    public var name: String
    /// Google's colour, such as "#9fe1e7".
    public var color: String
    /// True when `accessRole == "owner"`.
    public var owned: Bool
    public var primary: Bool

    public init(id: String, name: String, color: String, owned: Bool, primary: Bool) {
        self.id = id; self.name = name; self.color = color; self.owned = owned; self.primary = primary
    }
}

/// Talks to the Google Calendar v3 API. No state: the token and the network are passed in.
public struct GoogleCalendarAPI: Sendable {
    public static let defaultHTTP: HTTPFetch = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GoogleCalendarError.badResponse("not an HTTP response") }
        return (data, http)
    }
    /// Gives an access token; `forceRefresh` true means "drop any saved one and get a new one" (used after a 401).
    let token: @Sendable (_ forceRefresh: Bool) async throws -> String
    let http: HTTPFetch

    public init(token: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String, http: @escaping HTTPFetch = GoogleCalendarAPI.defaultHTTP) {
        self.token = token; self.http = http
    }

    // MARK: Calendars

    public func listCalendars() async throws -> [CalCalendarInfo] {
        var out: [CalCalendarInfo] = []
        var pageToken: String?
        repeat {
            var q = [URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken { q.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let obj = try await json(try await send("GET", "/users/me/calendarList", query: q))
            for item in obj["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                out.append(CalCalendarInfo(id: id, name: (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? id,
                                           color: item["backgroundColor"] as? String ?? "", owned: item["accessRole"] as? String == "owner",
                                           primary: item["primary"] as? Bool ?? false))
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    // MARK: Events

    /// Reads changes for one calendar. With a `syncToken` Google returns only what changed since (and Google forbids a time
    /// window then, so none is sent); without one it returns the events inside `timeMin`...`timeMax`. Recurring events come
    /// as separate instances (`singleEvents=true`). Throws `.syncExpired` when Google says the token is too old.
    public func listEvents(calendarID: String, syncToken: String?, timeMin: Date, timeMax: Date)
        async throws -> (changes: [GoogleEventChange], nextToken: String) {
        var changes: [GoogleEventChange] = []
        var pageToken: String?
        while true {
            var q = [URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "showDeleted", value: "true"),
                     URLQueryItem(name: "maxResults", value: "250")]
            if let syncToken { q.append(URLQueryItem(name: "syncToken", value: syncToken)) }
            else {
                q.append(URLQueryItem(name: "timeMin", value: Self.rfc3339(timeMin)))
                q.append(URLQueryItem(name: "timeMax", value: Self.rfc3339(timeMax)))
            }
            if let pageToken { q.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let obj = try await json(try await send("GET", "/calendars/\(Self.pathID(calendarID))/events", query: q))
            for item in obj["items"] as? [[String: Any]] ?? [] {
                if let c = try Self.change(from: item) { changes.append(c) }
            }
            if let next = obj["nextPageToken"] as? String { pageToken = next; continue }
            guard let sync = obj["nextSyncToken"] as? String else { throw GoogleCalendarError.badResponse("events list had no nextSyncToken") }
            return (changes, sync)
        }
    }

    /// Creates an event. Returns Google's event id and the fields as Google stored them. The caller (outbox) gives it its
    /// E-n number by storing it through the calendar cache; this client never invents one.
    public func insert(calendarID: String, _ e: CalEventFields, cardID: Int64?, addMeet: Bool)
        async throws -> (eventID: String, fields: CalEventFields) {
        var body: [String: Any] = ["summary": e.title]
        if e.allDay, let s = e.startDay, let en = e.endDay { body["start"] = ["date": s]; body["end"] = ["date": en] }
        else { body["start"] = Self.timedJSON(e.start); body["end"] = Self.timedJSON(e.end) }
        if !e.location.isEmpty { body["location"] = e.location }
        if !e.description.isEmpty { body["description"] = e.description }
        if let cardID { body["extendedProperties"] = ["private": ["floatboard_card": String(cardID)]] }
        var q: [URLQueryItem] = []
        if addMeet {
            body["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
            q.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
        }
        return try await eventResult(try await send("POST", "/calendars/\(Self.pathID(calendarID))/events", query: q, body: body))
    }

    /// Changes only the fields given. `allDayStart` ("yyyy-MM-dd") makes it an all-day event starting that day; it ends the
    /// day of `end` (exclusive, as Google counts) when `end` is given, else the next day.
    public func patch(calendarID: String, eventID: String, title: String?, start: Date?, end: Date?, allDayStart: String?)
        async throws -> (eventID: String, fields: CalEventFields) {
        var body: [String: Any] = [:]
        if let title { body["summary"] = title }
        if let day = allDayStart {
            // Google's PATCH merges nested objects, so the timed form is cleared explicitly (null) when switching to all-day.
            body["start"] = ["date": day, "dateTime": NSNull(), "timeZone": NSNull()] as [String: Any]
            body["end"] = ["date": end.map { Self.dayString($0) } ?? Self.nextDay(day), "dateTime": NSNull(), "timeZone": NSNull()] as [String: Any]
        } else {
            // ...and the all-day form is cleared when switching to timed.
            if let start { body["start"] = Self.timedJSON(start).merging(["date": NSNull()]) { a, _ in a } }
            if let end { body["end"] = Self.timedJSON(end).merging(["date": NSNull()]) { a, _ in a } }
        }
        return try await eventResult(try await send("PATCH", "/calendars/\(Self.pathID(calendarID))/events/\(Self.pathID(eventID))", body: body))
    }

    /// Deletes an event. Already gone (404 or 410) counts as success.
    public func delete(calendarID: String, eventID: String) async throws {
        let (data, status) = try await raw("DELETE", "/calendars/\(Self.pathID(calendarID))/events/\(Self.pathID(eventID))")
        if status == 404 || status == 410 { return }
        _ = try Self.accept(data, status, mapGone: false)
    }

    // MARK: Parsing

    /// The first video-meeting link in `text` (Zoom, Teams or Meet), or "".
    public static func videoLink(in text: String) -> String {
        let hosts = ["zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com"]
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#) else { return "" } // try?-ok: constant pattern; "" means no link found
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let url = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if let host = URL(string: url)?.host?.lowercased(), hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return ""
    }

    /// One Google event as a change. All-day events keep Google's `date` values in `startDay`/`endDay`; Google's end date is
    /// EXCLUSIVE (a one-day event on the 23rd ends on the 24th) and it is kept exactly so.
    static func change(from item: [String: Any]) throws -> GoogleEventChange? {
        guard let id = item["id"] as? String else { return nil }
        if item["status"] as? String == "cancelled" { return GoogleEventChange(eventID: id, cancelled: true, fields: nil) }
        guard let s = item["start"] as? [String: Any], let en = item["end"] as? [String: Any] else {
            throw GoogleCalendarError.badResponse("event \(id) has no start or end")
        }
        var f: CalEventFields
        let updated = (item["updated"] as? String).flatMap(parseRFC3339) ?? Date(timeIntervalSince1970: 0)
        if let sd = s["date"] as? String, let ed = en["date"] as? String {
            guard let a = parseDay(sd), let b = parseDay(ed) else { throw GoogleCalendarError.badResponse("event \(id) has a bad date") }
            f = CalEventFields(start: a, end: b, allDay: true, startDay: sd, endDay: ed, title: "", googleUpdated: updated)
        } else if let sdt = (s["dateTime"] as? String).flatMap(parseRFC3339), let edt = (en["dateTime"] as? String).flatMap(parseRFC3339) {
            f = CalEventFields(start: sdt, end: edt, title: "", googleUpdated: updated)
        } else { throw GoogleCalendarError.badResponse("event \(id) has an unreadable start or end") }
        f.title = item["summary"] as? String ?? ""
        f.location = item["location"] as? String ?? ""
        f.description = item["description"] as? String ?? ""
        f.htmlLink = item["htmlLink"] as? String ?? ""
        f.recurringID = item["recurringEventId"] as? String
        let card = ((item["extendedProperties"] as? [String: Any])?["private"] as? [String: Any])?["floatboard_card"] as? String
        f.fbCard = card.flatMap { Int64($0) }
        f.videoLink = videoLink(item, location: f.location, description: f.description)
        return GoogleEventChange(eventID: id, cancelled: false, fields: f)
    }

    private static func videoLink(_ item: [String: Any], location: String, description: String) -> String {
        if let h = item["hangoutLink"] as? String, !h.isEmpty { return h }
        let points = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        if let uri = points.first(where: { $0["entryPointType"] as? String == "video" })?["uri"] as? String, !uri.isEmpty { return uri }
        let fromLocation = videoLink(in: location)
        return fromLocation.isEmpty ? videoLink(in: description) : fromLocation
    }

    // MARK: Dates

    static func parseRFC3339(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter(); withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
    static func rfc3339(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")!
        return f.string(from: d)
    }
    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        f.calendar = AppTime.calendar; f.timeZone = AppTime.zone
        return f
    }
    static func parseDay(_ s: String) -> Date? { dayFormatter().date(from: s) }
    static func dayString(_ d: Date) -> String { dayFormatter().string(from: d) }
    static func nextDay(_ s: String) -> String {
        guard let d = parseDay(s), let n = AppTime.calendar.date(byAdding: .day, value: 1, to: d) else { return s }
        return dayString(n)
    }
    private static func timedJSON(_ d: Date) -> [String: Any] {
        let f = ISO8601DateFormatter(); f.timeZone = AppTime.zone
        return ["dateTime": f.string(from: d), "timeZone": AppTime.zone.identifier]
    }

    // MARK: Transport

    /// Calendar and event ids can hold characters (like "#") that must be escaped inside a URL path.
    static func pathID(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")) ?? s
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> (Data, Int) {
        // `path` already has its ids escaped (pathID); `percentEncodedPath` keeps that escaping as it is.
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = "www.googleapis.com"
        comps.percentEncodedPath = "/calendar/v3" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GoogleCalendarError.badResponse("bad URL \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await token(false))", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await http(req)
        if resp.statusCode == 401 {
            // A saved token Google dropped early looks like a 401; try once with a fresh one before giving up.
            req.setValue("Bearer \(try await token(true))", forHTTPHeaderField: "Authorization")
            let (data2, resp2) = try await http(req)
            return (data2, resp2.statusCode)
        }
        return (data, resp.statusCode)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        let (data, status) = try await raw(method, path, query: query, body: body)
        return try Self.accept(data, status, mapGone: true)
    }

    static func accept(_ data: Data, _ status: Int, mapGone: Bool) throws -> Data {
        if (200..<300).contains(status) { return data }
        let body = String(decoding: data, as: UTF8.self)
        if status == 401 { throw GoogleCalendarError.needsReconnect(body: body) }
        if status == 403, body.contains("insufficientPermissions") || body.contains("PERMISSION_DENIED") { throw GoogleCalendarError.needsReconnect(body: body) }
        if status == 410, mapGone { throw GoogleCalendarError.syncExpired }
        throw GoogleCalendarError.http(status: status, body: body)
    }

    private func json(_ data: Data) async throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok: reported as badResponse just below
            throw GoogleCalendarError.badResponse("not a JSON object: " + String(decoding: data.prefix(200), as: UTF8.self))
        }
        return o
    }

    private func eventResult(_ data: Data) async throws -> (eventID: String, fields: CalEventFields) {
        guard let c = try Self.change(from: try await json(data)), let f = c.fields else {
            throw GoogleCalendarError.badResponse("event answer had no usable event")
        }
        return (c.eventID, f)
    }
}
