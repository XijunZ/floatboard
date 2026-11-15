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
        let transport: LocalEngine.Transport = transportOverride ?? { req in try await URLSession.shared.data(for: req) }
        let e = try LocalEngine(script: try LocalEngine.bundledScript(), databaseURL: LocalData.screeningDatabase,
                                secrets: ["ENC_KEY": enc, "ADMIN_KEY": admin], transport: transport)
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

    // MARK: Switching

    /// Turns Mac only on: starts the engine, makes its user once, adds "This Mac", queues your keys for it, moves
    /// WhatsApp here and pauses the online engines' Gmail and Fathom inputs.
    public static func enable(store: Store) async throws {
        storeRef = store
        let e = try start(store: store)
        let keyName = ConnectorAccounts.credentialName(connectorID)
        if (try Credentials.get(keyName) ?? "").isEmpty {
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
        // Keys you already entered on this Mac go to its engine too.
        var items: Set<Keys.Item> = []
        if Keys.value(Keys.claude, store: store) != nil { items.insert(.claude) }
        if Keys.value(Keys.gmailClientID, store: store) != nil { items.insert(.googleClient) }
        try Keys.setPending(Keys.pending(connector: connectorID, store: store).union(items), connector: connectorID, store: store)

        for c in store.connectors where c.id != connectorID && !c.baseURL.isEmpty {
            if WhatsAppSync.isOn(connector: c.id, store: store) {
                WhatsAppSync.setOn(false, connector: c.id, store: store)
                WhatsAppSync.setOn(true, connector: connectorID, store: store)
            }
            await pauseInputs(of: c, store: store)
        }
        store.activity("connector:\(connectorID)", .info, "Mac only mode on: screening runs on this Mac")
    }

    /// Back to Always on: "This Mac" is removed from the list (its database and key are kept for next time), and the
    /// online engines' paused inputs and WhatsApp screening are turned back on.
    public static func disable(store: Store) async throws {
        let wasWhatsApp = WhatsAppSync.isOn(connector: connectorID, store: store)
        WhatsAppSync.setOn(false, connector: connectorID, store: store)
        try store.removeConnector(id: connectorID)
        store.reload()
        for c in store.connectors where !c.baseURL.isEmpty {
            if wasWhatsApp { WhatsAppSync.setOn(true, connector: c.id, store: store); break }
        }
        for c in store.connectors where !c.baseURL.isEmpty { await resumeInputs(of: c, store: store) }
        store.activity("connector:\(connectorID)", .info, "Mac only mode off: screening runs on your online engine")
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
            store.activity("connector:\(c.id)", .info, "Turned \(c.name)'s inputs back on")
        } catch {
            store.activity("connector:\(c.id)", .warning, "Couldn't turn \(c.name)'s inputs back on; use their switches in Settings › Inputs",
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
