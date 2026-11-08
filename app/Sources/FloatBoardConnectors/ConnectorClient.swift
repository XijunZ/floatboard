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

    public init(settingsVersion: Int = 0, schema: [SettingField] = [], needsAttention: [String] = [], waiting: Int = 0,
                lastRunOK: String? = nil, lastRunError: String? = nil, oldestUnprocessedEvent: String? = nil) {
        self.settingsVersion = settingsVersion; self.schema = schema; self.needsAttention = needsAttention
        self.waiting = waiting; self.lastRunOK = lastRunOK; self.lastRunError = lastRunError
        self.oldestUnprocessedEvent = oldestUnprocessedEvent
    }

    enum CodingKeys: String, CodingKey {
        case settingsVersion = "settings_version", schema, needsAttention = "needs_attention", waiting
        case lastRunOK = "last_run_ok", lastRunError = "last_run_error", oldestUnprocessedEvent = "oldest_unprocessed_event"
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
    }
}

public enum ConnectorError: Error, CustomStringConvertible, Equatable {
    case auth
    case http(Int, String)
    case staleSettings(engineVersion: Int?)
    case network(String)
    case badResponse(String)

    public var description: String {
        switch self {
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
    static let payloadKeys = ["source_mid", "source_sent", "item_id", "verdict", "detail", "at", "notes", "request_id"]

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
