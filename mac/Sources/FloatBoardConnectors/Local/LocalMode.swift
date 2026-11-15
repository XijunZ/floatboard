import FloatBoardCore
import Foundation

/// Mac only mode (docs/architecture.md, Edition 2, C1/C2): the engine runs inside this app as the connector
/// "This Mac" (id `mac`). The rest of the app talks to it exactly as to an online engine (same proposals, events,
/// settings and keys), so switching modes changes where screening runs, not how the board works.
///
/// Switching to Mac only turns off the online engine's Gmail and Fathom inputs (remembered, so switching back turns
/// them on again) and moves WhatsApp screening here; switching back does the reverse. The board reconciles tasks by
/// their source (Message-ID and time), so an email seen by both never becomes two tasks.
@MainActor
public enum LocalMode {
    public static let connectorID = "mac"
    public static let name = "This Mac"
    public static let address = "http://floatboard.local"
    public static let cron = "*/5 * * * *"
    static let encName = "local-engine:enc", adminName = "local-engine:admin"
    static func pausedKey(_ id: String) -> String { "mode.paused.\(id)" }

    private static var engine: LocalEngine?
    private static var running = false
    /// For checks: replaces the network the engine uses.
    public static var transportOverride: LocalEngine.Transport?

    public static func isOn(store: Store) -> Bool { store.connectors.contains { $0.id == connectorID && !$0.baseURL.isEmpty } }

    /// The engine, started on first use.
    static func start(store: Store) throws -> LocalEngine {
        if let engine { return engine }
        let enc = try secret(encName, store: store) { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
        let admin = try secret(adminName, store: store) { UUID().uuidString + UUID().uuidString }
        let network: LocalEngine.Transport = transportOverride ?? { req in try await URLSession.shared.data(for: req) }
        // Requests for "On this Mac" go to Apple's on-device model instead of the network.
        let transport: LocalEngine.Transport = { req in
            if req.url?.host == "api.anthropic.com", OnDeviceModel.wants(req.httpBody), let body = req.httpBody {
                let data = try await OnDeviceModel.answer(body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!)
            }
            return try await network(req)
        }
        let e = try LocalEngine(script: try LocalEngine.bundledScript(), databaseURL: LocalData.screeningDatabase,
                                secrets: ["ENC_KEY": enc, "ADMIN_KEY": admin, "ON_DEVICE": OnDeviceModel.isAvailable ? "1" : ""], transport: transport)
        e.log = { [weak store] level, msg in
            guard level != "info" else { return }
            store?.activity("connector:\(connectorID)", level == "error" ? .error : .warning, "Engine on this Mac: \(String(msg.prefix(300)))")
        }
        engine = e
        return e
    }

    private static func secret(_ name: String, store: Store, make: () -> String) throws -> String {
        try Credentials.logging("set up the engine on this Mac", store: store) {
            if let v = try Credentials.get(name), !v.isEmpty { return v }
            let v = make()
            try Credentials.set(v, name)
            return v
        }
    }

    /// For checks: forget the running engine (its database stays).
    public static func resetForTesting() { engine = nil; running = false }

    /// A request from the app to the engine on this Mac.
    public static func handle(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let store = storeRef else { throw LocalEngineError.script("not started") }
        return try await start(store: store).handle(req)
    }
    private static weak var storeRef: Store?

    public static func client(store: Store) -> ConnectorClient? {
        storeRef = store
        guard let key = try? Credentials.get(ConnectorAccounts.credentialName(connectorID)), !key.isEmpty, // try?-ok: no key means not set up; the caller shows that
              let url = URL(string: address) else { return nil }
        return ConnectorClient(baseURL: url, key: key) { req in try await LocalMode.handle(req) }
    }

    // MARK: Switching (nothing set up is lost)

    /// True once this Mac's engine has been set up (its user exists); it is then kept in step even while on standby.
    public static func isSetUp() -> Bool {
        ((try? Credentials.get(ConnectorAccounts.credentialName(connectorID))) ?? nil)?.isEmpty == false // try?-ok: unreadable means not set up yet
    }

    static func online(_ store: Store) -> [ConnectorInfo] { store.connectors.filter { $0.id != connectorID && !$0.baseURL.isEmpty } }

    /// Turns Mac only on. The first time, this Mac's engine and its user are made; after that the same one is used.
    /// Then everything set up moves here from the online engine: rules, groups and what was learned (settings),
    /// Gmail and Fathom with their access and reading position, what was already judged, and WhatsApp screening.
    /// The online engine stays connected (phone app, Outlook) and stops reading Gmail and Fathom while this Mac does.
    public static func enable(store: Store) async throws {
        storeRef = store
        let e = try start(store: store)
        let keyName = ConnectorAccounts.credentialName(connectorID)
        if !isSetUp() {
            var req = URLRequest(url: URL(string: address + "/admin/users")!)
            req.httpMethod = "POST"
            req.setValue(try secret(adminName, store: store) { "" }, forHTTPHeaderField: "X-Admin-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(#"{"name":"This Mac"}"#.utf8)
            let (d, r) = try await e.handle(req)
            guard r.statusCode == 200, let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let key = o["key"] as? String else {
                throw LocalEngineError.script("couldn't create this Mac's user (\(r.statusCode))")
            }
            try Credentials.set(key, keyName)
        }
        try store.upsertConnector(id: connectorID, name: name, baseURL: address)
        store.reload()
        guard let local = client(store: store) else { throw LocalEngineError.script("no key for this Mac's engine") }
        var items: Set<Keys.Item> = []
        if Keys.value(Keys.claude, store: store) != nil { items.insert(.claude) }
        if Keys.value(Keys.gmailClientID, store: store) != nil { items.insert(.googleClient) }
        try Keys.setPending(Keys.pending(connector: connectorID, store: store).union(items), connector: connectorID, store: store)

        if let from = online(store).first {
            try copySettings(from: from.id, to: connectorID, store: store)
            if let remote = ConnectorAccounts.client(for: from, store: store) {
                try await local.receiveHandover(try await remote.handoverState(), switching: true)
            }
            for c in online(store) {
                WhatsAppSync.move(from: c.id, to: connectorID, store: store)
                WeChatSync.move(from: c.id, to: connectorID, store: store)
                await pauseInputs(of: c, store: store)
            }
        }
        store.activity("connector:\(connectorID)", .info, "Mac only mode on: screening runs on this Mac, from where your online engine left off")
    }

    /// Back to Always on: everything moves to the online engine the same way (including inboxes connected while on this
    /// Mac and where reading got to), then this Mac's engine goes on standby: hidden from the list, kept in step.
    public static func disable(store: Store) async throws {
        guard let to = online(store).first else { throw LocalEngineError.script("connect an online engine first") }
        guard let remote = ConnectorAccounts.client(for: to, store: store) else { throw LocalEngineError.script("no key for \(to.name)") }
        if let local = client(store: store) {
            let state = try await local.handoverState()
            try await remote.receiveHandover(state, switching: true)
            // On standby this Mac's engine keeps everything but has its inputs switched off.
            if var o = try JSONSerialization.jsonObject(with: state) as? [String: Any] {
                o["sources"] = (o["sources"] as? [[String: Any]] ?? []).map { var x = $0; x["enabled"] = false; return x }
                try await local.receiveHandover(try JSONSerialization.data(withJSONObject: o), switching: true)
            }
        }
        try copySettings(from: connectorID, to: to.id, store: store)
        WhatsAppSync.move(from: connectorID, to: to.id, store: store)
        WeChatSync.move(from: connectorID, to: to.id, store: store)
        try store.removeConnector(id: connectorID)
        store.reload()
        await resumeInputs(of: to, store: store)
        store.activity("connector:\(connectorID)", .info, "Mac only mode off: screening runs on \(to.name) again, from where this Mac left off")
    }

    /// Settings are the Mac's (rules, groups, lists, what was learned): the screening engine's copy is the one in use.
    /// Phone alert settings belong to the online engine (it sends the alerts), so they are never copied onto it.
    static let onlineOwned: Set<String> = ["alerts_on", "critical_hours"]

    static func copySettings(from: String, to: String, store: Store) throws {
        guard let src = store.connectors.first(where: { $0.id == from })?.settings,
              let dst = store.connectors.first(where: { $0.id == to })?.settings else { return }
        let changed = src.filter { k, v in
            !(to != connectorID && onlineOwned.contains(k)) && !NSDictionary(dictionary: [k: v]).isEqual(to: [k: dst[k] as Any])
        }
        guard !changed.isEmpty else { return }
        try store.saveConnectorSettings(connector: to, values: changed, note: "copied from \(from == connectorID ? name : from)")
    }

    /// Every few minutes: the engine that screens hands its state to the one on standby (which never reads), so a switch
    /// starts exactly where it should. Only once this Mac's engine has been set up.
    public static func mirror(store: Store) async {
        guard isSetUp(), let to = online(store).first, let remote = ConnectorAccounts.client(for: to, store: store),
              let local = client(store: store) else { return }
        storeRef = store
        do {
            if isOn(store: store) {
                try await remote.receiveHandover(try await local.handoverState(), switching: false)
                try copySettings(from: connectorID, to: to.id, store: store)
            } else {
                try await local.receiveHandover(try await remote.handoverState(), switching: false)
            }
        } catch {
            store.activity("connector:\(connectorID)", .warning, "Couldn't keep this Mac's engine and \(to.name) in step; will try again",
                           detail: (error as? ConnectorError)?.description ?? "\(error)")
        }
    }

    static func pauseInputs(of c: ConnectorInfo, store: Store) async {
        guard let client = ConnectorAccounts.client(for: c, store: store) else { return }
        do {
            let st = try await client.status()
            let toPause = st.sources.filter { $0.enabled && ($0.kind == "gmail" || $0.kind == "fathom") }
            for s in toPause { try await client.setSourceEnabled(id: s.id, false) }
            let ids = toPause.map(\.id)
            if !ids.isEmpty {
                try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [pausedKey(c.id), ids.joined(separator: ",")])
                store.activity("connector:\(c.id)", .info, "Paused \(ids.count) input\(ids.count == 1 ? "" : "s") on \(c.name) while this Mac screens")
            }
        } catch {
            store.activity("connector:\(c.id)", .warning, "Couldn't pause \(c.name)'s inputs; it may also read the same email (no duplicate tasks are made)",
                           detail: (error as? ConnectorError)?.description ?? "\(error)")
        }
    }

    static func resumeInputs(of c: ConnectorInfo, store: Store) async {
        guard let raw = try? store.db.query("SELECT value FROM meta WHERE key=?", [pausedKey(c.id)]) { DB.text($0, 0) }.first, // try?-ok: nothing paused
              let client = ConnectorAccounts.client(for: c, store: store) else { return }
        do {
            for id in raw.split(separator: ",") { try await client.setSourceEnabled(id: String(id), true) }
            try store.db.run("DELETE FROM meta WHERE key=?", [pausedKey(c.id)])
        } catch {
            store.activity("connector:\(c.id)", .warning, "Couldn't turn \(c.name)'s inputs back on; use their switches in Settings › Connections",
                           detail: (error as? ConnectorError)?.description ?? "\(error)")
        }
    }

    // MARK: Schedule

    /// One schedule tick while the app runs (every 5 minutes, as online). Skipped while one is still running.
    public static func tick(store: Store) async {
        guard isOn(store: store), !running else { return }
        storeRef = store
        running = true; defer { running = false }
        do { try await start(store: store).scheduled(cron: cron, at: Date()) } catch {
            store.activity("connector:\(connectorID)", .warning, "The engine on this Mac hit a problem; it will try again in 5 minutes", detail: "\(error)")
        }
    }
}
