import CryptoKit
import FloatBoardCore
import Foundation
import JavaScriptCore
import Security
import SQLite3

public enum LocalEngineError: Error, CustomStringConvertible {
    case script(String), database(String), noScript
    public var description: String {
        switch self {
        case .script(let m): return "The engine on this Mac stopped with an error: \(m)"
        case .database(let m): return "The engine's database on this Mac can't be used: \(m)"
        case .noScript: return "This FloatBoard build doesn't include the engine for Mac only mode (engine.js)."
        }
    }
}

/// The engine, running inside this app (Mac only mode, docs/architecture.md, Edition 2, C2): the same engine code as
/// online (`mac/Resources/engine.js`, built from `engine/`), run by JavaScriptCore. This class is its platform:
/// network through `transport`, a local SQLite file for its database (`screening.sqlite`, never the board), timers,
/// randomness and the few cryptographic operations it uses. Everything runs on the main actor.
@MainActor
public final class LocalEngine {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let context: JSContext
    private let api: JSValue
    private var db: OpaquePointer?
    private let transport: Transport
    private let secrets: [String: String]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 1
    private var lastException: String?
    /// Engine log lines go here (and to Activity through the caller).
    public var log: (String, String) -> Void = { _, _ in }

    /// `secrets`: ENC_KEY and ADMIN_KEY for this Mac's engine.
    public init(script: String, databaseURL: URL, secrets: [String: String], transport: @escaping Transport) throws {
        self.transport = transport
        self.secrets = secrets
        var handle: OpaquePointer?
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw LocalEngineError.database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open")
        }
        db = handle
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;", nil, nil, nil)
        guard let ctx = JSContext() else { throw LocalEngineError.script("JavaScriptCore is not available") }
        context = ctx
        api = JSValue(newObjectIn: ctx)
        ctx.exceptionHandler = { [weak self] _, ex in self?.lastException = ex?.toString() ?? "unknown error" }
        installHost()
        ctx.evaluateScript(script)
        if let e = lastException { throw LocalEngineError.script(e) }
        guard let engine = ctx.objectForKeyedSubscript("FloatBoardEngine"), !engine.isUndefined else {
            throw LocalEngineError.script("the engine script didn't start")
        }
        _ = engine
        let applied = try callSync("migrate")
        if applied.toInt32() > 0 { log("info", "Engine on this Mac: \(applied.toInt32()) database update(s) applied") }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// The bundled engine script: in the app's Resources, else `mac/Resources/engine.js` next to the sources (checks).
    public static func bundledScript() throws -> String {
        let candidates = [Bundle.main.url(forResource: "engine", withExtension: "js"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/engine.js")]
        for case let u? in candidates where FileManager.default.fileExists(atPath: u.path) {
            return try String(contentsOf: u, encoding: .utf8)
        }
        throw LocalEngineError.noScript
    }

    // MARK: Requests and the schedule

    /// One request to the engine, as the network would deliver it to the online engine.
    public func handle(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let headers = (req.allHTTPHeaderFields ?? [:]).map { [$0.key, $0.value] }
        let payload: [String: Any] = ["url": req.url?.absoluteString ?? "http://floatboard.local/", "method": req.httpMethod ?? "GET",
                                      "headers": headers, "body": req.httpBody.map { $0.base64EncodedString() } ?? NSNull()]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let out = try await callAsync("handle", [json])
        guard let data = out.toString()?.data(using: .utf8),
              let r = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = r["status"] as? Int else { throw LocalEngineError.script("unreadable response") }
        var h: [String: String] = [:]
        for pair in r["headers"] as? [[String]] ?? [] where pair.count == 2 { h[pair[0]] = h[pair[0]].map { $0 + ", " + pair[1] } ?? pair[1] }
        let body = (r["body"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let url = req.url ?? URL(string: "http://floatboard.local/")!
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!)
    }

    /// One schedule tick (the online engine's cron), then waits for its work to finish.
    public func scheduled(cron: String, at: Date = Date()) async throws {
        _ = try await callAsync("scheduled", [cron, at.timeIntervalSince1970 * 1000])
    }

    /// Waits until background work started by requests has finished.
    public func idle() async throws { _ = try await callAsync("idle", []) }

    private func callSync(_ name: String, _ args: [Any] = []) throws -> JSValue {
        lastException = nil
        let v = context.objectForKeyedSubscript("FloatBoardEngine").invokeMethod(name, withArguments: args)
        if let e = lastException { throw LocalEngineError.script(e) }
        return v ?? JSValue(undefinedIn: context)
    }

    private func callAsync(_ name: String, _ args: [Any]) async throws -> JSValue {
        let promise = try callSync(name, args)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSValue, Error>) in
            var done = false
            let ok: @convention(block) (JSValue) -> Void = { v in if !done { done = true; cont.resume(returning: v) } }
            let fail: @convention(block) (JSValue) -> Void = { e in
                if !done {
                    done = true
                    let msg = e.objectForKeyedSubscript("stack")?.toString().flatMap { $0 == "undefined" ? nil : $0 }
                    cont.resume(throwing: LocalEngineError.script((e.toString() ?? "error") + (msg.map { "\n" + $0 } ?? "")))
                }
            }
            promise.invokeMethod("then", withArguments: [JSValue(object: ok, in: context)!, JSValue(object: fail, in: context)!])
        }
    }

    // MARK: Host functions (`__fb`)

    private func installHost() {
        let fb = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: Any) { fb.setObject(block, forKeyedSubscript: name as NSString) }

        let log: @convention(block) (String, String) -> Void = { [weak self] level, msg in self?.log(level, msg) }
        set("log", log)

        let secret: @convention(block) (String) -> String = { [weak self] k in self?.secrets[k] ?? "" }
        set("secret", secret)

        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in
            guard let self else { return 0 }
            let id = self.nextTimer; self.nextTimer += 1
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                    fn.call(withArguments: [])
                }
            }
            self.timers[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000, execute: item)
            return id
        }
        set("setTimeout", setTimeout)
        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        set("clearTimeout", clearTimeout)

        let random: @convention(block) (Int) -> String = { n in
            var b = [UInt8](repeating: 0, count: max(0, n))
            _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
            return Data(b).base64EncodedString()
        }
        set("random", random)
        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        set("uuid", uuid)

        let digest: @convention(block) (String, String) -> String = { alg, b64 in
            let d = Data(base64Encoded: b64) ?? Data()
            switch alg {
            case "SHA-1": return Data(Insecure.SHA1.hash(data: d)).base64EncodedString()
            case "SHA-384": return Data(SHA384.hash(data: d)).base64EncodedString()
            case "SHA-512": return Data(SHA512.hash(data: d)).base64EncodedString()
            default: return Data(SHA256.hash(data: d)).base64EncodedString()
            }
        }
        set("digest", digest)

        let hmac: @convention(block) (String, String, String) -> String = { alg, keyB64, dataB64 in
            let key = SymmetricKey(data: Data(base64Encoded: keyB64) ?? Data()), d = Data(base64Encoded: dataB64) ?? Data()
            switch alg {
            case "SHA-1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: d, using: key)).base64EncodedString()
            case "SHA-384": return Data(HMAC<SHA384>.authenticationCode(for: d, using: key)).base64EncodedString()
            case "SHA-512": return Data(HMAC<SHA512>.authenticationCode(for: d, using: key)).base64EncodedString()
            default: return Data(HMAC<SHA256>.authenticationCode(for: d, using: key)).base64EncodedString()
            }
        }
        set("hmac", hmac)

        // AES-GCM as WebCrypto does it: the output is ciphertext followed by the 16-byte tag. nil on failure.
        let aes: @convention(block) (Bool, String, String, String) -> Any = { encrypt, keyB64, ivB64, dataB64 in
            guard let k = Data(base64Encoded: keyB64), let iv = Data(base64Encoded: ivB64), let d = Data(base64Encoded: dataB64),
                  let nonce = try? AES.GCM.Nonce(data: iv) else { return NSNull() } // try?-ok: a bad nonce is a failed operation, reported to the script
            let key = SymmetricKey(data: k)
            if encrypt {
                guard let box = try? AES.GCM.seal(d, using: key, nonce: nonce) else { return NSNull() } // try?-ok: reported to the script
                return (box.ciphertext + box.tag).base64EncodedString()
            }
            guard d.count >= 16, let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: d.prefix(d.count - 16), tag: d.suffix(16)), // try?-ok: reported to the script
                  let plain = try? AES.GCM.open(box, using: key) else { return NSNull() } // try?-ok: reported to the script
            return plain.base64EncodedString()
        }
        set("aesGcm", aes)

        let fetch: @convention(block) (String, JSValue) -> Void = { [weak self] payload, callback in
            guard let self else { return }
            let transport = self.transport
            Task { @MainActor in
                do {
                    guard let p = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                          let url = URL(string: p["url"] as? String ?? "") else { throw URLError(.badURL) }
                    var req = URLRequest(url: url, timeoutInterval: 60)
                    req.httpMethod = p["method"] as? String ?? "GET"
                    for pair in p["headers"] as? [[String]] ?? [] where pair.count == 2 { req.addValue(pair[1], forHTTPHeaderField: pair[0]) }
                    if let b = p["body"] as? String { req.httpBody = Data(base64Encoded: b) }
                    let (data, resp) = try await transport(req)
                    let http = resp as? HTTPURLResponse
                    let headers = (http?.allHeaderFields ?? [:]).map { ["\($0.key)", "\($0.value)"] }
                    let out: [String: Any] = ["status": http?.statusCode ?? 200, "headers": headers, "body": data.base64EncodedString()]
                    callback.call(withArguments: [NSNull(), String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self)])
                } catch {
                    callback.call(withArguments: [error.localizedDescription, NSNull()])
                }
            }
        }
        set("fetch", fetch)

        let sql: @convention(block) (String, String) -> String = { [weak self] sql, params in
            self?.runSQL(sql, params) ?? #"{"error":"closed"}"#
        }
        set("sql", sql)
        let batch: @convention(block) (String) -> String = { [weak self] json in self?.runBatch(json) ?? #"{"error":"closed"}"# }
        set("sqlBatch", batch)
        let exec: @convention(block) (String) -> String = { [weak self] sql in
            guard let self, let db = self.db else { return #"{"error":"closed"}"# }
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? "error"; sqlite3_free(err)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return Self.encode(["error": m])
            }
            return "{}"
        }
        set("sqlExec", exec)

        context.setObject(fb, forKeyedSubscript: "__fb" as NSString)
    }

    // MARK: SQLite (the engine's D1 database)

    private static func encode(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"unencodable"}"# // try?-ok: reported to the script as an error
    }

    private func runSQL(_ sql: String, _ paramsJSON: String) -> String {
        do { return Self.encode(try execute(sql, paramsJSON)) } catch { return Self.encode(["error": "\(error)"]) }
    }

    private func runBatch(_ json: String) -> String {
        guard let db else { return #"{"error":"closed"}"# }
        do {
            guard let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { throw LocalEngineError.database("bad batch") }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            var results: [Any] = []
            do {
                for s in list {
                    let params = String(decoding: try JSONSerialization.data(withJSONObject: s["params"] ?? []), as: UTF8.self)
                    results.append(try execute(s["sql"] as? String ?? "", params))
                }
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
            return Self.encode(["results": results])
        } catch { return Self.encode(["error": "\(error)"]) }
    }

    private func execute(_ sql: String, _ paramsJSON: String) throws -> [String: Any] {
        guard let db else { throw LocalEngineError.database("closed") }
        let params = try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8), options: [.fragmentsAllowed]) as? [Any] ?? []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw LocalEngineError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case is NSNull: sqlite3_bind_null(stmt, idx)
            case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): sqlite3_bind_int64(stmt, idx, n.boolValue ? 1 : 0)
            case let n as NSNumber:
                if CFNumberIsFloatType(n), n.doubleValue != n.doubleValue.rounded() { sqlite3_bind_double(stmt, idx, n.doubleValue) }
                else if abs(n.doubleValue) < 9.0e15 { sqlite3_bind_int64(stmt, idx, n.int64Value) }
                else { sqlite3_bind_double(stmt, idx, n.doubleValue) }
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            default: sqlite3_bind_text(stmt, idx, "\(p)", -1, transient)
            }
        }
        var rows: [[String: Any]] = []
        let cols = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw LocalEngineError.database(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Any] = [:]
            for c in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_NULL: row[name] = NSNull()
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = n == 0 ? "" : Data(bytes: sqlite3_column_blob(stmt, c), count: n).base64EncodedString()
                default: row[name] = String(cString: sqlite3_column_text(stmt, c))
                }
            }
            rows.append(row)
        }
        return ["rows": rows, "changes": Int(sqlite3_changes(db)), "last_row_id": sqlite3_last_insert_rowid(db)]
    }
}
