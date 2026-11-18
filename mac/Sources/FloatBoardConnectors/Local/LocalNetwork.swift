import Foundation

/// The engine on this Mac reaches the network through the app (LocalEngine's fetch bridge), so unlike the online engine it
/// can reach the home network. Fetches the engine marks "public only" (Circle's feeds) are checked here: the name is resolved
/// and every answer must be a public address; a literal private IP is refused without resolving. A "manual" redirect is
/// handed back to the engine, which checks the next hop itself (at most 3).
public enum PublicAddress {
    /// False for loopback, private, link-local, shared (CGNAT), benchmarking, multicast, unspecified and reserved addresses,
    /// IPv6 unique-local and link-local, and IPv4 inside IPv6 (mapped, NAT64) when the IPv4 is one of those.
    public static func isPublic(_ ip: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return publicV4(withUnsafeBytes(of: v4.s_addr) { Array($0) }) }
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }   // :: and ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return publicV4(Array(b[12..<16])) }   // ::ffff:a.b.c.d
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return publicV4(Array(b[12..<16])) }        // 64:ff9b::/96
        if b[0..<10].allSatisfy({ $0 == 0 }) { return false }   // the rest of ::/80 (old IPv4-compatible form): not public
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4] == 0 && b[5] == 1 { return false }    // 64:ff9b:1::/48 (NAT64 local use)
        if b[0] == 0x20 && b[1] == 0x02 { return false }                                                                // 2002::/16 (6to4)
        if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return false }                                                       // fec0::/10 (site-local)
        if (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || b[0] == 0xff { return false }           // fc00::/7, fe80::/10, ff00::/8
        return true
    }

    static func publicV4(_ a: [UInt8]) -> Bool {
        let (x, y) = (a[0], a[1])
        return !(x == 0 || x == 10 || x == 127 || (x == 169 && y == 254) || (x == 172 && (16...31).contains(y)) || (x == 192 && y == 168)
                 || (x == 100 && (64...127).contains(y)) || (x == 192 && y == 0 && a[2] == 0) || (x == 198 && (y == 18 || y == 19)) || x >= 224)
    }

    /// Every address the name resolves to (empty when it doesn't resolve). Blocking: call off the main thread.
    public static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(), res: UnsafeMutablePointer<addrinfo>?
        hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}

/// A session that never follows redirects: the 3xx answer itself comes back (for the engine's "manual" redirects).
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Keeps the remote address of every network connection a fetch used (cache loads have none and count as unknown).
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        return URLSession(configuration: c)
    }()
    let manual: Bool
    private let lock = NSLock()
    private var seen: [String?] = []
    init(manual: Bool) { self.manual = manual }
    var addresses: [String?] { lock.lock(); defer { lock.unlock() }; return seen }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let found = metrics.transactionMetrics.map { $0.resourceFetchType == .networkLoad ? $0.remoteAddress : nil }
        lock.lock(); seen = found; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(manual ? nil : request) }
}

public enum LocalNetworkError: Error, CustomStringConvertible {
    case notPublic(String)
    public var description: String {
        switch self { case .notPublic(let h): return "\(h) is not a public internet address; FloatBoard doesn't fetch it" }
    }
}

extension LocalEngine {
    nonisolated static let manualKey = "fb.manualRedirect"
    nonisolated static let publicOnlyKey = "fb.publicOnly"

    /// A network that also says the remote address of every connection a fetch used (nil when unknown).
    public typealias ConnectedTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse, [String?])

    /// The request the bridge sends for the engine's fetch payload. "public only": the host (a literal IP, or every address
    /// its name resolves to through `resolve`) must be public, else it throws. "manual" redirect: marked so the network
    /// hands back redirects instead of following them.
    nonisolated public static func request(from p: [String: Any], resolve: (String) -> [String] = PublicAddress.resolve) throws -> URLRequest {
        guard let url = URL(string: p["url"] as? String ?? ""), let host = url.host else { throw URLError(.badURL) }
        if p["publicOnly"] as? Bool == true {
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var probe4 = in_addr(), probe6 = in6_addr()
            let literal = inet_pton(AF_INET, bare, &probe4) == 1 || inet_pton(AF_INET6, bare, &probe6) == 1
            let answers = literal ? [bare] : resolve(bare)
            guard !answers.isEmpty, answers.allSatisfy(PublicAddress.isPublic) else { throw LocalNetworkError.notPublic(host) }
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = p["method"] as? String ?? "GET"
        for pair in p["headers"] as? [[String]] ?? [] where pair.count == 2 { req.addValue(pair[1], forHTTPHeaderField: pair[0]) }
        if let b = p["body"] as? String { req.httpBody = Data(base64Encoded: b) }
        if p["redirect"] as? String == "manual" || p["publicOnly"] as? Bool == true, let m = (req as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
            if p["redirect"] as? String == "manual" { URLProtocol.setProperty(true, forKey: manualKey, in: m) }
            if p["publicOnly"] as? Bool == true { URLProtocol.setProperty(true, forKey: publicOnlyKey, in: m) }
            req = m as URLRequest
        }
        return req
    }

    /// True for a fetch the engine marked "public only".
    nonisolated public static func isPublicOnly(_ req: URLRequest) -> Bool {
        URLProtocol.property(forKey: publicOnlyKey, in: req) as? Bool == true
    }

    /// True when the engine asked to see redirects itself.
    nonisolated public static func wantsManualRedirect(_ req: URLRequest) -> Bool {
        URLProtocol.property(forKey: manualKey, in: req) as? Bool == true
    }

    /// The app's own network for the engine: redirects followed unless the engine asked for them back. A "public only" fetch
    /// is checked again after it ran: the name was resolved for the check, but the connection resolves it again, so a name
    /// that switched to a private address in between (DNS rebinding) would reach it. Every connection's remote address
    /// (URLSessionTaskMetrics) must be public, or the answer is thrown away unread.
    nonisolated public static func liveNetwork(_ req: URLRequest) async throws -> (Data, URLResponse) {
        // A public-only GET (a feed) goes to the address checked before connecting (PinnedHTTP), so nothing is ever sent to
        // a home-network address; anything else public-only keeps the after-the-fact check.
        if isPublicOnly(req) {
            let pinnable = (req.httpMethod ?? "GET") == "GET" && req.httpBody == nil
            return try await network(req, transport: pinnable ? pinnedTransport : metricsTransport)
        }
        return try await (wantsManualRedirect(req) ? NoRedirect.session : URLSession.shared).data(for: req)
    }

    /// The check itself, with the network passed in (checks use a stand-in).
    nonisolated public static func network(_ req: URLRequest, transport: ConnectedTransport) async throws -> (Data, URLResponse) {
        let (data, response, connected) = try await transport(req)
        if isPublicOnly(req) {
            guard !connected.isEmpty, connected.allSatisfy({ $0.map(PublicAddress.isPublic) ?? false }) else {
                throw LocalNetworkError.notPublic(req.url?.host ?? "this address")
            }
        }
        return (data, response)
    }

    /// Resolves the name once (off the main thread), refuses unless every answer is public, then connects to a checked
    /// address itself; tries the next one when a connection can't be made.
    nonisolated static let pinnedTransport: ConnectedTransport = { req in
        guard let host = req.url?.host else { throw URLError(.badURL) }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var probe4 = in_addr(), probe6 = in6_addr()
        let literal = inet_pton(AF_INET, bare, &probe4) == 1 || inet_pton(AF_INET6, bare, &probe6) == 1
        let answers = literal ? [bare] : await Task.detached { PublicAddress.resolve(bare) }.value
        guard !answers.isEmpty, answers.allSatisfy(PublicAddress.isPublic) else { throw LocalNetworkError.notPublic(host) }
        var last: Error = LocalNetworkError.notPublic(host)
        for ip in answers {
            do {
                let (data, response) = try await PinnedHTTP.get(req, ip: ip)
                return (data, response, [ip])
            } catch { last = error }
        }
        throw last
    }

    /// URLSession with the connection metrics collected (no cache: every answer comes from a connection it can name).
    nonisolated static let metricsTransport: ConnectedTransport = { req in
        let collector = MetricsCollector(manual: wantsManualRedirect(req))
        var r = req
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await MetricsCollector.session.data(for: r, delegate: collector)
        return (data, response, collector.addresses)
    }
}
