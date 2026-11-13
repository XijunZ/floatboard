import FloatBoardCore
import Foundation

/// A JSON value for settings: string, number, bool, list of strings, or nested object.
public enum JSONValue: Codable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool), strings([String]), dict([String: JSONValue])

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) } // try?-ok: trying each JSON shape in turn
        else if let v = try? c.decode(Int.self) { self = .int(v) } // try?-ok: trying each JSON shape in turn
        else if let v = try? c.decode(Double.self) { self = .double(v) } // try?-ok: trying each JSON shape in turn
        else if let v = try? c.decode(String.self) { self = .string(v) } // try?-ok: trying each JSON shape in turn
        else if let v = try? c.decode([String].self) { self = .strings(v) } // try?-ok: trying each JSON shape in turn
        else { self = .dict(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .strings(let v): try c.encode(v)
        case .dict(let v): try c.encode(v)
        }
    }

    /// From JSONSerialization output; nil for shapes settings never hold (null, mixed arrays).
    public static func from(any: Any) -> JSONValue? {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15 ? .int(n.intValue) : .double(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [String]: return .strings(a)
        case let d as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in d { if let j = from(any: v) { out[k] = j } }
            return .dict(out)
        default: return nil
        }
    }
}

public struct SettingField: Codable, Equatable {
    public var key: String
    public var label: String
    /// text | longtext | list | bool | int | choice | groupNotes
    public var kind: String
    public var help: String?
    public var options: [String]?
}

public struct ConnectorStatus: Codable, Equatable {
    public var settingsVersion: Int
    public var schema: [SettingField]
    public var needsAttention: [String]
    public var waiting: Int
    public var lastRunOK: String?
    public var lastRunError: String?
    public var oldestUnprocessedEvent: String?
    /// The engine's whole database size in bytes (all its users); nil when the engine doesn't say (older engines).
    public var dbSizeBytes: Int?

    public init(settingsVersion: Int = 0, schema: [SettingField] = [], needsAttention: [String] = [], waiting: Int = 0,
                lastRunOK: String? = nil, lastRunError: String? = nil, oldestUnprocessedEvent: String? = nil, dbSizeBytes: Int? = nil) {
        self.settingsVersion = settingsVersion; self.schema = schema; self.needsAttention = needsAttention
        self.waiting = waiting; self.lastRunOK = lastRunOK; self.lastRunError = lastRunError
        self.oldestUnprocessedEvent = oldestUnprocessedEvent; self.dbSizeBytes = dbSizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case settingsVersion = "settings_version", schema, needsAttention = "needs_attention", waiting
        case lastRunOK = "last_run_ok", lastRunError = "last_run_error", oldestUnprocessedEvent = "oldest_unprocessed_event"
        case dbSizeBytes = "db_size_bytes"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        settingsVersion = try c.decode(Int.self, forKey: .settingsVersion)
        schema = try c.decodeIfPresent([SettingField].self, forKey: .schema) ?? []
        needsAttention = try c.decodeIfPresent([String].self, forKey: .needsAttention) ?? []
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
        lastRunOK = try c.decodeIfPresent(String.self, forKey: .lastRunOK)
        lastRunError = try c.decodeIfPresent(String.self, forKey: .lastRunError)
        oldestUnprocessedEvent = try c.decodeIfPresent(String.self, forKey: .oldestUnprocessedEvent)
        dbSizeBytes = try c.decodeIfPresent(Int.self, forKey: .dbSizeBytes)
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    case auth
    case http(Int, String)
    case staleSettings(engineVersion: Int?)
    case network(String)
    case badResponse(String)
    /// The engine answered 404 on a phone app route: it has no phone app (an older engine). Callers skip quietly.
    case noPhoneApp
    /// The engine answered 404 on the email search: it is older than "Link an email".
    case noEmailSearch

    public var description: String {
        switch self {
        case .noPhoneApp: return "This engine doesn't have the phone app yet. Update the engine to pair a phone."
        case .noEmailSearch: return "This engine can't search email yet. Update the engine first."
        case .auth: return "The engine didn't accept this connection's key."
        case .http(400, let b): return "The engine rejected the request as malformed. \(b)"
        case .http(let c, let b): return "The engine answered \(c). \(b)"
        case .staleSettings(let v): return "The engine has newer settings (version \(v.map(String.init) ?? "unknown"))."
        case .network(let m): return "Could not reach the engine: \(m)"
        case .badResponse(let m): return "The engine's answer could not be read: \(m)"
        }
    }
}

/// Talks the engine's /v2 contract. Knows nothing about the database.
public struct ConnectorClient {
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    let baseURL: URL
    let key: String
    let transport: Transport

    public static let live: Transport = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public init(baseURL: URL, key: String, transport: @escaping Transport = ConnectorClient.live) {
        self.baseURL = baseURL; self.key = key; self.transport = transport
    }

    /// Only these travel to the engine; the rest of an outbox payload is bookkeeping for collapsing changes.
    /// `account` and `gmail_id` name the inbox and message of an email the user linked to a task.
    public static let payloadKeys = ["source_mid", "source_sent", "item_id", "verdict", "detail", "at", "notes", "request_id", "account", "gmail_id"]

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw ConnectorError.badResponse("bad address") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await transport(req) } catch { throw ConnectorError.network("\(error.localizedDescription)") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ConnectorError.auth
        default: throw ConnectorError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// One page as the engine sent it: the raw `items` array (for `Reconciler.decodeBatch`) and the next cursor.
    public func proposalsPage(after cursor: String?) async throws -> (items: Data, cursor: String?) {
        var q = [URLQueryItem(name: "limit", value: "100")]
        if let cursor, !cursor.isEmpty { q.insert(URLQueryItem(name: "after", value: cursor), at: 0) }
        let data = try await call("GET", "/v2/proposals", query: q)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok: reported as badResponse below
              let items = obj["items"] as? [Any] else { throw ConnectorError.badResponse("no items list") }
        do {
            return (try JSONSerialization.data(withJSONObject: items), obj["cursor"] as? String)
        } catch { throw ConnectorError.badResponse("\(error)") }
    }

    /// Convenience that keeps the proposals that decode and skips the rest (the sync loop uses `proposalsPage`
    /// so rejected ones are logged by `Reconciler.decodeBatch`).
    public func proposals(after cursor: String?) async throws -> (items: [Proposal], cursor: String?) {
        let page = try await proposalsPage(after: cursor)
        let raw = (try? JSONSerialization.jsonObject(with: page.items) as? [Any]) ?? [] // try?-ok: produced by proposalsPage just above
        let items = raw.compactMap { one -> Proposal? in
            guard let d = try? JSONSerialization.data(withJSONObject: one) else { return nil } // try?-ok: untrusted item, skipped
            return try? JSONDecoder().decode(Proposal.self, from: d) // try?-ok: untrusted item, skipped
        }
        return (items, page.cursor)
    }

    /// Returns the uuids the engine acknowledged. Anything not in the answer is NOT delivered.
    public func send(_ events: [OutboxItem]) async throws -> [String] {
        let list: [[String: Any]] = events.map { e in
            ["uuid": e.uuid, "connector": e.connector, "kind": e.kind.rawValue,
             "payload": e.payload.filter { Self.payloadKeys.contains($0.key) },
             "created": e.created.timeIntervalSince1970, "attempts": e.attempts,
             "next_try": e.nextTry.timeIntervalSince1970, "last_error": e.lastError.map { $0 as Any } ?? NSNull()]
        }
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: ["events": list]) } catch { throw ConnectorError.badResponse("\(error)") }
        let data = try await call("POST", "/v2/events", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok: reported as badResponse
              let acked = obj["acked"] as? [String] else { throw ConnectorError.badResponse("no acked list") }
        let sent = Set(events.map(\.uuid))
        return acked.filter { sent.contains($0) }
    }

    public func putSettings(values: [String: JSONValue], version: Int) async throws {
        struct Body: Encodable { let version: Int; let values: [String: JSONValue] }
        let body: Data
        do { body = try JSONEncoder().encode(Body(version: version, values: values)) } catch { throw ConnectorError.badResponse("\(error)") }
        do { _ = try await call("PUT", "/v2/settings", body: body) } catch ConnectorError.http(409, let text) {
            let v = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["settings_version"] as? Int // try?-ok: unreadable version is reported as nil and logged by the caller
            throw ConnectorError.staleSettings(engineVersion: v)
        }
    }

    public func status() async throws -> ConnectorStatus {
        let data = try await call("GET", "/v2/status")
        do { return try JSONDecoder().decode(ConnectorStatus.self, from: data) } catch { throw ConnectorError.badResponse("\(error)") }
    }

    public func recheck(days: Int) async throws {
        _ = try await call("POST", "/v2/recheck", query: [URLQueryItem(name: "days", value: String(days))])
    }

    /// Asks the engine to work on (at most) one waiting reply draft now; it answers when that is done.
    public func runDrafts() async throws {
        _ = try await call("POST", "/v2/drafts/run")
    }

    // MARK: Phone app

    /// The engine's address, for telling one engine's board copy from another's.
    public var engineAddress: String { baseURL.absoluteString }

    /// Calls a phone app route; a 404 means this engine has no phone app (`ConnectorError.noPhoneApp`).
    private func phoneCall(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        do { return try await call(method, path, body: body) } catch ConnectorError.http(404, _) { throw ConnectorError.noPhoneApp }
    }

    /// A one-time pairing address (valid 10 minutes) for the QR code, and when it expires.
    public func pairPhone() async throws -> (url: URL, expires: Date) {
        let data = try await phoneCall("POST", "/v2/app/pair")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], // try?-ok: reported as badResponse below
              let raw = obj["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw ConnectorError.badResponse("pairing answer needs a web address")
        }
        let expires = (obj["expires"] as? String).flatMap(Self.parseISO) ?? Date().addingTimeInterval(600)
        return (url, expires)
    }

    /// A phone paired with this engine (the setup page lists the same ones).
    public struct PairedPhone: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let created: Date?
        public let lastSeen: Date?
        /// Other paired devices that use the same passkey.
        public let sharesPasskey: Int
    }

    public func phones() async throws -> [PairedPhone] {
        let data = try await phoneCall("GET", "/v2/app/phones")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], // try?-ok: reported as badResponse below
              let rows = obj["phones"] as? [[String: Any]] else { throw ConnectorError.badResponse("phone list needs phones") }
        return rows.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return PairedPhone(id: id, name: r["name"] as? String ?? "Phone", created: (r["created"] as? String).flatMap(Self.parseISO),
                               lastSeen: (r["last_seen"] as? String).flatMap(Self.parseISO), sharesPasskey: r["shares_passkey"] as? Int ?? 0)
        }
    }

    /// Signs one phone out and stops its notifications. Returns its name.
    @discardableResult
    public func removePhone(id: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["device_id": id])
        let data = try await call("POST", "/v2/app/phones/remove", body: body)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["name"] as? String ?? "Phone" // try?-ok: name is only for display
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Replaces the engine's copy of the board shown on the phone. `sent_at` is this Mac's clock at send time, so the
    /// engine can correct each card's `status_at` for a wrong Mac clock.
    public func putBoard(_ cards: [BoardCard], sentAt: Date = Date()) async throws {
        let body: Data
        do { body = try PhoneBoard.body(cards, sentAt: sentAt) } catch { throw ConnectorError.badResponse("\(error)") }
        _ = try await phoneCall("PUT", "/v2/board", body: body)
    }

    /// Changes made on the phone that the Mac hasn't applied yet, oldest first, plus how far the engine's clock is
    /// ahead of this Mac's (`server_time` minus this Mac's time when the answer arrived; 0 when the engine did not say).
    public func phoneActions() async throws -> (actions: [PhoneAction], engineAhead: TimeInterval) {
        let data = try await phoneCall("GET", "/v2/phone-actions")
        let arrived = Date()
        struct Answer: Decodable {
            let actions: [PhoneAction]; let serverTime: String?
            enum CodingKeys: String, CodingKey { case actions, serverTime = "server_time" }
        }
        do {
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            let ahead = answer.serverTime.flatMap(PhoneBoard.parseISO).map { $0.timeIntervalSince(arrived) } ?? 0
            return (answer.actions, ahead)
        } catch { throw ConnectorError.badResponse("phone actions: \(error)") }
    }

    /// Tells the engine which phone actions were applied and which were not (with the reason), at most 200 of each
    /// per call.
    public func ackPhoneActions(_ ids: [String], skipped: [PhoneSkip] = []) async throws {
        var rest = ids[...], restSkipped = skipped[...]
        while !rest.isEmpty || !restSkipped.isEmpty {
            let chunk = Array(rest.prefix(200)); rest = rest.dropFirst(200)
            let skipChunk = Array(restSkipped.prefix(200)); restSkipped = restSkipped.dropFirst(200)
            var obj: [String: Any] = [:]
            if !chunk.isEmpty { obj["ids"] = chunk }
            if !skipChunk.isEmpty { obj["skipped"] = skipChunk.map { ["id": $0.id, "reason": $0.reason] } }
            let body: Data
            do { body = try JSONSerialization.data(withJSONObject: obj) } catch { throw ConnectorError.badResponse("\(error)") }
            _ = try await phoneCall("POST", "/v2/phone-actions/ack", body: body)
        }
    }

    // MARK: Link an email

    /// Searches the user's connected Gmail (Gmail's own search, at most 100 characters): the newest 10 per inbox, newest
    /// first, with subject, sender and date only; an inbox that failed is listed in `errors`.
    public func searchEmails(_ q: String) async throws -> EmailSearch {
        let text = String(q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let data: Data
        do { data = try await call("GET", "/v2/emails/search", query: [URLQueryItem(name: "q", value: text)]) }
        catch ConnectorError.http(404, _) { throw ConnectorError.noEmailSearch }
        do { return try JSONDecoder().decode(EmailSearch.self, from: data) } catch { throw ConnectorError.badResponse("email search: \(error)") }
    }

    // MARK: Archive old data to this Mac

    /// One page of this user's old engine rows (`before` is the cut-off, ISO), each as the engine sent it, board log first;
    /// `cursor` is nil after the run's last page.
    public func archivePage(before: String, cursor: String?) async throws -> (rows: [(table: String, row: [String: Any])], cursor: String?) {
        var q = [URLQueryItem(name: "before", value: before)]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await call("GET", "/v2/archive", query: q)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], // try?-ok: reported as badResponse below
              let rows = obj["rows"] as? [String: Any],
              let log = rows["board_log"] as? [[String: Any]], let items = rows["items"] as? [[String: Any]] else {
            throw ConnectorError.badResponse("archive page needs rows.board_log and rows.items")
        }
        return (log.map { (table: "board_log", row: $0) } + items.map { (table: "items", row: $0) }, obj["cursor"] as? String)
    }

    /// Asks the engine to delete the run it just handed over; it does only when the counts and the hash match (409 otherwise).
    public func confirmArchive(before: String, boardLog: Int, items: Int, sha256: String) async throws {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: ["before": before, "counts": ["board_log": boardLog, "items": items], "sha256": sha256])
        } catch { throw ConnectorError.badResponse("\(error)") }
        _ = try await call("POST", "/v2/archive/confirm", body: body)
    }

    /// Asks the engine to run a check for this user now. `done` is false while more email is still waiting.
    public func run() async throws -> (processed: Int, done: Bool) {
        let data = try await call("POST", "/v2/run")
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], // try?-ok: reported as badResponse below
              let processed = obj["processed"] as? Int, let done = obj["done"] as? Bool else {
            throw ConnectorError.badResponse("run answer needs processed and done")
        }
        return (processed, done)
    }
}

/// One email found by `searchEmails`: ids, the inbox, and what to show (never the email's text).
public struct EmailHit: Decodable, Equatable, Identifiable {
    public var account: String
    public var gmailID: String
    public var messageID: String
    public var subject: String
    public var from: String
    public var date: String
    public var sentAt: String?
    public var id: String { account + "/" + gmailID }
    enum CodingKeys: String, CodingKey {
        case account, gmailID = "gmail_id", messageID = "message_id", subject, from, date, sentAt = "sent_at"
    }
    /// What linking it stores on the task.
    public var linked: LinkedEmail {
        LinkedEmail(account: account, gmailID: gmailID, messageID: messageID, sentAt: sentAt, subject: subject, from: from)
    }
}

/// The answer to an email search: results newest first, and the inboxes that could not be searched.
public struct EmailSearch: Decodable, Equatable {
    public struct Problem: Decodable, Equatable { public var account: String; public var error: String }
    public var results: [EmailHit]
    public var errors: [Problem]
}
