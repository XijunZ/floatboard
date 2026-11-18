import Foundation
import Network

/// A plain HTTP/1.1 GET to one address chosen before connecting (Network framework), for the engine's "public only"
/// fetches (Circle's blog and news feeds) on this Mac. URLSession resolves the name again when it connects, so a name
/// that switches to a home-network address in between (DNS rebinding) would get the request; here the name is resolved
/// once, every answer must be public, and the connection goes to that checked address. For https the certificate is
/// still checked against the name (SNI and validation use the host name). Small answers only (feeds): at most 5 MB.
public enum PinnedHTTP {
    static let maxBytes = 5_000_000

    struct Failed: Error, CustomStringConvertible { let description: String }

    /// GET `url` at `ip`. Returns the body, the response and the address used.
    public static func get(_ req: URLRequest, ip: String, timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        guard let url = req.url, let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw Failed(description: "not a web address")
        }
        let tls = scheme == "https"
        let port = url.port ?? (tls ? 443 : 80)
        let params: NWParameters
        if tls {
            let o = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(o.securityProtocolOptions, host)
            sec_protocol_options_add_tls_application_protocol(o.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: o)
        } else {
            params = .tcp
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw Failed(description: "bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
        defer { conn.cancel() }
        let raw = try await withThrowingTaskGroup(of: Data.self) { group -> Data in
            group.addTask { try await exchange(conn, request: requestBytes(req, url: url, host: host, port: port, tls: tls)) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failed(description: "timed out")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let (status, headers, body) = try parse(raw)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw Failed(description: "bad answer")
        }
        return (body, response)
    }

    static func requestBytes(_ req: URLRequest, url: URL, host: String, port: Int, tls: Bool) -> Data {
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        let hostHeader = (port == (tls ? 443 : 80)) ? host : "\(host):\(port)"
        var lines = ["GET \(path) HTTP/1.1", "Host: \(hostHeader)", "Accept-Encoding: identity", "Connection: close"]
        let skip: Set<String> = ["host", "accept-encoding", "connection", "content-length", "transfer-encoding"]
        for (k, v) in req.allHTTPHeaderFields ?? [:] where !skip.contains(k.lowercased()) { lines.append("\(k): \(v)") }
        if req.value(forHTTPHeaderField: "User-Agent") == nil { lines.append("User-Agent: FloatBoard") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Connects, sends the request, and reads until the server closes (Connection: close) or the cap.
    private static func exchange(_ conn: NWConnection, request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                case .waiting(let e): once.run { cont.resume(throwing: e) }   // no route: fail now rather than wait
                case .cancelled: once.run { cont.resume(throwing: Failed(description: "cancelled")) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: request, completion: .contentProcessed { e in if let e { cont.resume(throwing: e) } else { cont.resume() } })
        }
        var out = Data()
        while true {
            let (chunk, done): (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, complete)) }
                }
            }
            if let chunk { out.append(chunk) }
            if out.count > maxBytes { throw Failed(description: "answer too large") }
            if done || chunk == nil || chunk?.isEmpty == true { break }
        }
        return out
    }

    /// The status, headers and body of a whole HTTP/1.1 answer (chunked or not).
    public static func parse(_ raw: Data) throws -> (Int, [String: String], Data) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw Failed(description: "no headers") }
        let head = String(decoding: raw[raw.startIndex..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = (head.first ?? "").split(separator: " ")
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else { throw Failed(description: "bad status line") }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<c]).trimmingCharacters(in: .whitespaces), v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }
        var body = Data(raw[split.upperBound...])
        let value = { (name: String) in headers.first { $0.key.lowercased() == name }?.value }
        if value("transfer-encoding")?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
            headers = headers.filter { $0.key.lowercased() != "transfer-encoding" }
        } else if let n = value("content-length").flatMap(Int.init), n <= body.count {
            body = body.prefix(n)
        }
        return (status, headers, body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var out = Data(), i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { throw Failed(description: "bad chunk") }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw Failed(description: "bad chunk size") }
            if size == 0 { return out }
            let start = lineEnd.upperBound, end = start + size
            guard end <= data.endIndex else { throw Failed(description: "short chunk") }
            out.append(data[start..<end])
            i = min(end + 2, data.endIndex)
        }
        return out
    }

    /// Resumes a continuation once (state updates can repeat).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }
}
