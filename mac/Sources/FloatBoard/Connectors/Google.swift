import FloatBoardCore
import FloatBoardConnectors
import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Connected Google accounts and Google Calendar event creation.
///
/// Sign-in uses Google's standard flow for desktop apps: the browser opens Google's sign-in page,
/// Google redirects back to a temporary local address (127.0.0.1) that FloatBoard listens on, and
/// FloatBoard swaps the one-time code for tokens (with PKCE). The OAuth client ID/secret and each
/// account's refresh token are kept in a private file (see `GoogleCredentials`); nothing is sent anywhere except Google.
@MainActor
final class Google: ObservableObject {
    @Published private(set) var accounts: [String] = []   // emails
    @Published private(set) var clientID = ""
    @Published var status: String?
    @Published var busy = false

    /// Calendar events only (add tasks to calendar), plus who signed in.
    static let scopes = GoogleAuthConfig.scopes.joined(separator: " ")
    private var tokens: [String: (token: String, expires: Date)] = [:]
    private var listener: NWListener?

    private var store: Store?

    init() {
        accounts = UserDefaults.standard.stringArray(forKey: "googleAccounts") ?? []
    }

    /// Called as soon as the store exists, so credential problems can be written to the Activity log.
    func attach(store: Store) {
        self.store = store
        GoogleCredentials.store = store
        clientID = GoogleCredentials.get("client-id") ?? ""
    }

    /// Shows the message next to the buttons and records it in Activity (problems are never only on screen).
    private func fail(_ text: String, detail: String? = nil) {
        status = text
        store?.activity("google", .warning, text, detail: detail)
    }

    var isConfigured: Bool { !clientID.isEmpty && GoogleCredentials.get("client-secret") != nil }

    func saveClient(id: String, secret: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { fail("Paste both the client ID and the client secret."); return }
        guard GoogleCredentials.set(id, "client-id"), GoogleCredentials.set(secret, "client-secret") else {
            fail("Couldn't save the Google client. Check the Activity log."); return
        }
        clientID = id
        status = "Saved. Now connect an account."
    }

    /// Import the JSON file Google Cloud Console downloads for a Desktop OAuth client.
    @discardableResult
    func importClientJSON(at url: URL) -> Bool {
        let json: [String: Any]
        do {
            guard let j = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any] else {
                throw GoogleError("not a JSON object")
            }
            json = j
        } catch {
            fail("That file doesn't look like a Google OAuth client JSON.", detail: "\(url.lastPathComponent): \(error)")
            return false
        }
        guard let inner = (json["installed"] ?? json["web"]) as? [String: Any],
              let id = inner["client_id"] as? String,
              let secret = inner["client_secret"] as? String else {
            fail("That file doesn't look like a Google OAuth client JSON.", detail: "\(url.lastPathComponent): no client_id / client_secret")
            return false
        }
        saveClient(id: id, secret: secret)
        if json["installed"] == nil { fail("Imported, but this is a Web client; create a Desktop app client instead.") }
        return true
    }

    func remove(_ email: String) {
        if !GoogleCredentials.delete("refresh:\(email)") { fail("Couldn't remove \(email)'s saved sign-in. Check the Activity log.") }
        tokens[email] = nil
        accounts.removeAll { $0 == email }
        UserDefaults.standard.set(accounts, forKey: "googleAccounts")
    }

    // MARK: Connect an account

    func connect() {
        guard isConfigured, let secret = GoogleCredentials.get("client-secret") else {
            fail("Add the client ID and secret first."); return
        }
        listener?.cancel()
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)

        let l: NWListener
        do { l = try NWListener(using: .tcp, on: .any) } catch { fail("Couldn't start sign-in.", detail: "\(error)"); return }
        listener = l
        busy = true
        status = "Waiting for you to sign in in the browser…"

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let ok = code != nil && items.first { $0.name == "state" }?.value == state
                let body = ok
                    ? "<h2>FloatBoard is connected.</h2><p>You can close this tab.</p>"
                    : "<h2>Sign-in didn't complete.</h2><p>You can close this tab and try again.</p>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                guard path.hasPrefix("/?") || path.hasPrefix("/oauth") else { return } // ignore favicon etc.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.listener?.cancel(); self.listener = nil
                    guard ok, let code, let port = l.port?.rawValue else {
                        self.busy = false; self.fail("Sign-in was cancelled or didn't match. Try again."); return
                    }
                    Task { await self.finish(code: code, verifier: verifier, secret: secret,
                                             redirect: "http://127.0.0.1:\(port)") }
                }
            }
        }
        l.stateUpdateHandler = { [weak self] st in
            guard case .ready = st, let port = l.port?.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                c.queryItems = [
                    .init(name: "client_id", value: self.clientID),
                    .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: Self.scopes),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "select_account consent"),
                    .init(name: "state", value: state),
                ]
                if let u = c.url { NSWorkspace.shared.open(u) }
            }
        }
        l.start(queue: .main)
    }

    private func finish(code: String, verifier: String, secret: String, redirect: String) async {
        defer { busy = false }
        do {
            let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
                "code": code, "client_id": clientID, "client_secret": secret,
                "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
            ])
            guard let refresh = json["refresh_token"] as? String,
                  let access = json["access_token"] as? String,
                  let idToken = json["id_token"] as? String,
                  let email = Self.email(fromIDToken: idToken) else {
                fail("Google didn't return what we need: \(json["error_description"] ?? json["error"] ?? "unknown")")
                return
            }
            guard GoogleCredentials.set(refresh, "refresh:\(email)") else {
                fail("Signed in, but couldn't save the sign-in on this Mac. Check the Activity log.")
                return
            }
            tokens[email] = (access, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3000) - 60))
            if !accounts.contains(email) { accounts.append(email) }
            UserDefaults.standard.set(accounts, forKey: "googleAccounts")
            status = "Connected \(email)."
        } catch {
            fail("Sign-in failed: \(error.localizedDescription)", detail: "\(error)")
        }
    }

    private func accessToken(for email: String) async throws -> String {
        if let t = tokens[email], t.expires > Date() { return t.token }
        guard let refresh = GoogleCredentials.get("refresh:\(email)"), let secret = GoogleCredentials.get("client-secret") else {
            throw GoogleError("\(email) isn't connected any more. Reconnect it in the Google Calendar section of the Connectors tab.")
        }
        let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
            "client_id": clientID, "client_secret": secret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        guard let access = json["access_token"] as? String else {
            throw GoogleError("Google refused to refresh \(email): \(json["error_description"] ?? json["error"] ?? "unknown"). Reconnect it.")
        }
        tokens[email] = (access, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3000) - 60))
        return access
    }

    // MARK: Calendar

    struct CreatedEvent { let id: String; let htmlLink: String; let meetLink: String? }

    /// Creates an event on the account's main calendar. Timed tasks get 30 minutes; date-only tasks are all-day.
    func createEvent(for card: Card, account: String, addMeet: Bool) async throws -> CreatedEvent {
        guard let due = card.due else { throw GoogleError("Give the task a due date first.") }
        let token = try await accessToken(for: account)
        var body: [String: Any] = ["summary": card.title]
        var description = card.notes
        if let m = card.meetLink { description += (description.isEmpty ? "" : "\n\n") + m.absoluteString }
        if !description.isEmpty { body["description"] = description }
        if card.dueHasTime {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            iso.timeZone = .current
            let tz = TimeZone.current.identifier
            body["start"] = ["dateTime": iso.string(from: due), "timeZone": tz]
            body["end"] = ["dateTime": iso.string(from: due.addingTimeInterval(30 * 60)), "timeZone": tz]
        } else {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let next = Calendar.current.date(byAdding: .day, value: 1, to: due) ?? due
            body["start"] = ["date": f.string(from: due)]
            body["end"] = ["date": f.string(from: next)]
        }
        if addMeet {
            body["conferenceData"] = ["createRequest": [
                "requestId": UUID().uuidString,
                "conferenceSolutionKey": ["type": "hangoutsMeet"],
            ]]
        }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] // try?-ok: untrusted reply; a non-200 or missing id is reported below
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = json["id"] as? String else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw GoogleError("Google Calendar said: \(msg)")
        }
        return CreatedEvent(id: id, htmlLink: json["htmlLink"] as? String ?? "", meetLink: json["hangoutLink"] as? String)
    }

    // MARK: Helpers

    private static func postForm(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleError("Google's answer could not be read.")
        }
        return json
    }

    private static func email(fromIDToken t: String) -> String? {
        let parts = t.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil } // try?-ok: untrusted token; nil is reported as "didn't return what we need"
        return json["email"] as? String
    }

    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

struct GoogleError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Google client and refresh tokens, kept in the shared credentials file (see `Credentials`).
/// Not the macOS Keychain: without an Apple Developer ID it asks for permission again after every app update.
enum GoogleCredentials {
    /// Set once the store exists. Every failure is written to Activity (the error, never the value).
    nonisolated(unsafe) static var store: Store?
    /// The last read problem logged, so a screen that asks again and again doesn't flood the log.
    nonisolated(unsafe) private static var lastReadProblem = ""

    @MainActor
    private static func note(_ action: String, _ error: Error, once: Bool) {
        let key = "\(action): \(error)"
        if once { guard key != lastReadProblem else { return }; lastReadProblem = key }
        if let store { store.activity("credentials", .error, "Could not \(action)", detail: "\(error)") }
        else { FileHandle.standardError.write(Data("FloatBoard: could not \(action): \(error)\n".utf8)) }
    }

    @MainActor
    private static func load() -> [String: String]? {
        do {
            let all = try Credentials.all()
            lastReadProblem = ""
            return all
        } catch {
            note("read the saved Google credentials", error, once: true)
            return nil
        }
    }

    @MainActor static func get(_ key: String) -> String? { load()?[key] }

    /// False (and an Activity row) when the value could not be saved.
    @MainActor @discardableResult
    static func set(_ value: String, _ key: String) -> Bool {
        do { try Credentials.set(value, key); return true } catch {
            note("save a Google credential", error, once: false); return false
        }
    }

    @MainActor @discardableResult
    static func delete(_ key: String) -> Bool {
        do { try Credentials.delete(key); return true } catch {
            note("remove a Google credential", error, once: false); return false
        }
    }
}
