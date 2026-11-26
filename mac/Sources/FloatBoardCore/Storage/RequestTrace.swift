import Foundation

/// The technical side of one failed network request, written under a warning or error in Activity: which service and
/// endpoint, what came back (HTTP status, or the system's error domain and code), the network path, the request id the
/// server gave (Cloudflare's cf-ray for the engine), and how long it took. Never the key, the body sent, or query values.
public struct RequestTrace: Equatable, Sendable {
    public var service: String
    public var method: String
    public var host: String
    public var path: String
    public var queryKeys: [String]
    public var status: Int?
    public var error: String?
    public var networkPath: String?
    public var requestID: String?
    public var ms: Int

    public init(service: String, request: URLRequest, started: Date, response: HTTPURLResponse? = nil, error: Error? = nil,
                now: Date = Date()) {
        self.service = service
        method = request.httpMethod ?? "GET"
        let comps = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        host = comps?.host ?? "?"
        // A calendar id is often an email address: kept out of the log (and of diagnostics) as <email>.
        path = (comps?.percentEncodedPath ?? "?").split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.contains("@") || $0.lowercased().contains("%40") ? "<email>" : String($0) }.joined(separator: "/")
        queryKeys = (comps?.queryItems ?? []).map(\.name)
        status = response?.statusCode
        requestID = response.flatMap { r in
            ["cf-ray", "x-request-id", "x-guploader-uploadid"].lazy.compactMap { r.value(forHTTPHeaderField: $0) }.first
        }
        ms = max(0, Int((now.timeIntervalSince(started) * 1000).rounded()))
        if let error { (self.error, networkPath) = Self.describe(error) } else { self.error = nil; networkPath = nil }
    }

    /// One line, e.g. `engine GET floatboard-api.example/v2/proposals?after&limit · no answer · NSURLErrorDomain -1009
    /// (notConnectedToInternet) · network: unsatisfied (No network route) · 3 ms`.
    public var line: String {
        var parts = ["\(service) \(method) \(host)\(path)" + (queryKeys.isEmpty ? "" : "?" + queryKeys.joined(separator: "&"))]
        parts.append(status.map { "HTTP \($0)" } ?? "no answer")
        if let error { parts.append(error) }
        if let networkPath { parts.append("network: \(networkPath)") }
        if let requestID { parts.append("request id \(requestID)") }
        parts.append("\(ms) ms")
        return parts.joined(separator: " · ")
    }

    static let urlCodeNames: [Int: String] = [
        -1001: "timedOut", -1003: "cannotFindHost", -1004: "cannotConnectToHost", -1005: "networkConnectionLost",
        -1009: "notConnectedToInternet", -1011: "badServerResponse", -1020: "dataNotAllowed", -1200: "secureConnectionFailed",
        -1202: "serverCertificateUntrusted", -999: "cancelled", -1018: "internationalRoamingOff", -1019: "callIsActive",
    ]

    /// `NSURLErrorDomain -1009 (notConnectedToInternet)` and, where the system says, the network path at that moment.
    static func describe(_ error: Error) -> (String, String?) {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain || ns.domain == "kCFErrorDomainCFNetwork" else {
            return ("\(type(of: error)): \(String(describing: error).prefix(200))", nil)
        }
        let name = urlCodeNames[ns.code].map { " (\($0))" } ?? ""
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let path = (ns.userInfo["_NSURLErrorNWPathKey"] ?? underlying?.userInfo["_NSURLErrorNWPathKey"]).map { "\($0)" }
        return ("\(ns.domain) \(ns.code)\(name)", path)
    }
}

/// Holds recent request failures until the Activity row that reports them is written. A failure is matched to a row by
/// the error text the row quotes, so a trace is only ever attached to the row about that very error. Each sync binds
/// its own recorder (`RequestRecorder.$current`), so two syncs failing at once with the same text can't swap endpoints;
/// work outside a sync uses the shared one. Failures not reported within two minutes are dropped.
public final class RequestRecorder: @unchecked Sendable {
    public static let shared = RequestRecorder()
    @TaskLocal public static var current: RequestRecorder = shared

    private let lock = NSLock()
    private var failures: [(texts: [String], trace: RequestTrace, at: Date)] = []

    public init() {}

    /// `thrown` is the error the caller will see (the one an Activity row quotes); `texts` adds other ways it is written.
    public func failed(_ trace: RequestTrace, thrown: Error, now: Date = Date()) {
        var texts = ["\(thrown)", (thrown as NSError).localizedDescription]
        if let c = thrown as? CustomStringConvertible { texts.append(c.description) }
        let keep = texts.filter { $0.count >= 8 }
        lock.lock(); defer { lock.unlock() }
        failures.removeAll { now.timeIntervalSince($0.at) > 120 }
        failures.append((keep, trace, now))
        if failures.count > 16 { failures.removeFirst(failures.count - 16) }
    }

    /// The newest failure whose error text appears in `detail`, removed so it is attached once.
    public func take(matching detail: String, now: Date = Date()) -> RequestTrace? {
        lock.lock(); defer { lock.unlock() }
        failures.removeAll { now.timeIntervalSince($0.at) > 120 }
        guard let i = failures.lastIndex(where: { f in f.texts.contains { detail.contains($0) } }) else { return nil }
        return failures.remove(at: i).trace
    }
}
